import Accelerate
import Foundation

/// DTLN-aec, the neural stage of the pass Pipit ships, run on the CPU with
/// Accelerate.
///
/// Two small networks per 8 ms hop. The first looks at the magnitude spectra
/// of the microphone and of what was played and masks the microphone's
/// spectrum. The second looks at the masked block and the played block in
/// the time domain and masks a learned encoding of the block before decoding
/// it back to samples. Each network is two LSTM layers of `units` cells over
/// one 32 ms block, so the arithmetic per hop is four cells' worth of
/// matrix-vector products, a few million multiply-adds.
///
/// The weights are the ones published with the model (MIT, breizhn/DTLN-aec),
/// exported to one flat file by `Benchmarks/aec/export_dtln.py`. Every
/// operation here mirrors that exporter's reference and the ONNX graph it
/// was read from, and `pipit-eval aec` checks the two agree on real audio.
public final class DTLNCanceller: EchoCancelling {
    public static let block = 512
    public static let hop = 128
    public static let bins = block / 2 + 1
    static let epsilon: Float = 1e-7

    public var blockFrames: Int { Self.hop }
    /// The block's first hop comes out when the block is complete, three
    /// hops after it went in.
    public var latencyFrames: Int { Self.block - Self.hop }
    public var reportedRemovalDB: Double? { nil }

    /// A weight file and its index, as the exporter writes them.
    public struct Weights {
        struct Tensor: Decodable {
            let name: String
            let shape: [Int]
            let offset: Int
            let count: Int
        }
        struct Index: Decodable {
            let units: Int
            let bins: Int
            let block: Int
            let hop: Int
            let bytes: Int
            let tensors: [Tensor]
        }

        let units: Int
        let table: [String: [Float]]

        /// Reads `name.weights` and `name.json` from one directory.
        public init(directory: URL, name: String) throws {
            let index = try JSONDecoder().decode(
                Index.self, from: Data(contentsOf: directory.appendingPathComponent("\(name).json"))
            )
            let data = try Data(contentsOf: directory.appendingPathComponent("\(name).weights"))
            guard data.count == index.bytes, index.bins == DTLNCanceller.bins,
                index.block == DTLNCanceller.block, index.hop == DTLNCanceller.hop
            else { throw WeightsError.mismatch }
            var table: [String: [Float]] = [:]
            for tensor in index.tensors {
                let end = tensor.offset + tensor.count * MemoryLayout<Float>.size
                guard end <= data.count else { throw WeightsError.mismatch }
                table[tensor.name] = data[tensor.offset..<end].withUnsafeBytes {
                    Array($0.bindMemory(to: Float.self))
                }
            }
            units = index.units
            self.table = table
        }

        func tensor(_ name: String, count: Int) throws -> [Float] {
            guard let values = table[name], values.count == count else {
                throw WeightsError.missing(name)
            }
            return values
        }

        public enum WeightsError: Error {
            case mismatch
            case missing(String)
        }
    }

    /// One LSTM layer: kernels laid out as the model stores them, gates in
    /// the order input, forget, cell, output.
    private struct Layer {
        let inputs: Int
        let units: Int
        let kernel: [Float]  // inputs x 4 units
        let recurrent: [Float]  // units x 4 units
        let bias: [Float]  // 4 units
        var hidden: [Float]
        var cell: [Float]
        var gates: [Float]
        var scratch: [Float]

        init(inputs: Int, units: Int, kernel: [Float], recurrent: [Float], bias: [Float]) {
            self.inputs = inputs
            self.units = units
            self.kernel = kernel
            self.recurrent = recurrent
            self.bias = bias
            hidden = [Float](repeating: 0, count: units)
            cell = [Float](repeating: 0, count: units)
            gates = [Float](repeating: 0, count: 4 * units)
            scratch = [Float](repeating: 0, count: 4 * units)
        }

        mutating func step(_ input: [Float]) {
            let n = vDSP_Length(4 * units)
            // gates = x . kernel + h . recurrent + bias, each product a row
            // vector times a matrix.
            vDSP_mmul(input, 1, kernel, 1, &gates, 1, 1, n, vDSP_Length(inputs))
            vDSP_mmul(hidden, 1, recurrent, 1, &scratch, 1, 1, n, vDSP_Length(units))
            gates.withUnsafeMutableBufferPointer { z in
                vDSP_vadd(z.baseAddress!, 1, scratch, 1, z.baseAddress!, 1, n)
                vDSP_vadd(z.baseAddress!, 1, bias, 1, z.baseAddress!, 1, n)
            }
            // Sigmoid on the input, forget and output gates, tanh on the
            // cell candidate.
            var count = Int32(units)
            gates.withUnsafeMutableBufferPointer { z in
                let base = z.baseAddress!
                for gate in [0, 1, 3] {
                    DTLNCanceller.sigmoid(base + gate * units, count: units)
                }
                vvtanhf(base + 2 * units, base + 2 * units, &count)
            }
            // cell = forget * cell + input * candidate; hidden = output * tanh(cell)
            gates.withUnsafeBufferPointer { z in
                let i = z.baseAddress!
                let f = i + units
                let g = i + 2 * units
                let o = i + 3 * units
                cell.withUnsafeMutableBufferPointer { c in
                    vDSP_vmul(f, 1, c.baseAddress!, 1, c.baseAddress!, 1, vDSP_Length(units))
                    vDSP_vma(i, 1, g, 1, c.baseAddress!, 1, c.baseAddress!, 1, vDSP_Length(units))
                }
                hidden.withUnsafeMutableBufferPointer { h in
                    cell.withUnsafeBufferPointer { c in
                        vvtanhf(h.baseAddress!, c.baseAddress!, &count)
                    }
                    vDSP_vmul(o, 1, h.baseAddress!, 1, h.baseAddress!, 1, vDSP_Length(units))
                }
            }
        }
    }

    /// Layer normalisation over one vector, with the model's gain and shift.
    private struct Norm {
        let gamma: [Float]
        let beta: [Float]

        func apply(_ x: inout [Float]) {
            let n = vDSP_Length(x.count)
            x.withUnsafeMutableBufferPointer { buffer in
                let p = buffer.baseAddress!
                var mean: Float = 0
                vDSP_meanv(p, 1, &mean, n)
                var negative = -mean
                vDSP_vsadd(p, 1, &negative, p, 1, n)
                var variance: Float = 0
                vDSP_measqv(p, 1, &variance, n)
                var scale = 1 / (variance + DTLNCanceller.epsilon).squareRoot()
                vDSP_vsmul(p, 1, &scale, p, 1, n)
                vDSP_vmul(p, 1, gamma, 1, p, 1, n)
                vDSP_vadd(p, 1, beta, 1, p, 1, n)
            }
        }
    }

    /// sigmoid(x) = (1 + tanh(x / 2)) / 2, in place.
    private static func sigmoid(_ p: UnsafeMutablePointer<Float>, count: Int) {
        var half: Float = 0.5
        var n = Int32(count)
        vDSP_vsmul(p, 1, &half, p, 1, vDSP_Length(count))
        vvtanhf(p, p, &n)
        vDSP_vsmul(p, 1, &half, p, 1, vDSP_Length(count))
        vDSP_vsadd(p, 1, &half, p, 1, vDSP_Length(count))
    }

    private let units: Int
    private let micNorm: Norm
    private let farNorm: Norm
    private var spectralOne: Layer
    private var spectralTwo: Layer
    private let maskKernel: [Float]  // units x bins
    private let maskBias: [Float]
    private let encoder: [Float]  // block x block, out x in
    private let estimateNorm: Norm
    private let playedNorm: Norm
    private var temporalOne: Layer
    private var temporalTwo: Layer
    private let gateKernel: [Float]  // units x block
    private let gateBias: [Float]
    private let decoder: [Float]  // block x block

    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private var micWindow = [Float](repeating: 0, count: block)
    private var farWindow = [Float](repeating: 0, count: block)
    private var overlap = [Float](repeating: 0, count: block)
    // Scratch for one hop.
    private var realIn = [Float](repeating: 0, count: block / 2)
    private var imagIn = [Float](repeating: 0, count: block / 2)
    private var realMic = [Float](repeating: 0, count: block / 2)
    private var imagMic = [Float](repeating: 0, count: block / 2)
    private var realFar = [Float](repeating: 0, count: block / 2)
    private var imagFar = [Float](repeating: 0, count: block / 2)
    private var micFeatures = [Float](repeating: 0, count: bins)
    private var farFeatures = [Float](repeating: 0, count: bins)
    private var spectralInput = [Float](repeating: 0, count: 2 * bins)
    private var mask = [Float](repeating: 0, count: bins)
    private var estimate = [Float](repeating: 0, count: block)
    private var encodedEstimate = [Float](repeating: 0, count: block)
    private var encodedPlayed = [Float](repeating: 0, count: block)
    private var temporalInput = [Float](repeating: 0, count: 2 * block)
    private var gate = [Float](repeating: 0, count: block)
    private var decoded = [Float](repeating: 0, count: block)

    public init(weights: Weights) throws {
        let u = weights.units
        let b = Self.bins
        let blk = Self.block
        units = u
        micNorm = Norm(
            gamma: try weights.tensor("p1.mic.gamma", count: b), beta: try weights.tensor("p1.mic.beta", count: b))
        farNorm = Norm(
            gamma: try weights.tensor("p1.lpb.gamma", count: b), beta: try weights.tensor("p1.lpb.beta", count: b))
        spectralOne = Layer(
            inputs: 2 * b, units: u, kernel: try weights.tensor("p1.lstm1.kernel", count: 2 * b * 4 * u),
            recurrent: try weights.tensor("p1.lstm1.recurrent", count: u * 4 * u),
            bias: try weights.tensor("p1.lstm1.bias", count: 4 * u)
        )
        spectralTwo = Layer(
            inputs: u, units: u, kernel: try weights.tensor("p1.lstm2.kernel", count: u * 4 * u),
            recurrent: try weights.tensor("p1.lstm2.recurrent", count: u * 4 * u),
            bias: try weights.tensor("p1.lstm2.bias", count: 4 * u)
        )
        maskKernel = try weights.tensor("p1.dense.kernel", count: u * b)
        maskBias = try weights.tensor("p1.dense.bias", count: b)
        encoder = try weights.tensor("p2.encoder", count: blk * blk)
        estimateNorm = Norm(
            gamma: try weights.tensor("p2.est.gamma", count: blk), beta: try weights.tensor("p2.est.beta", count: blk))
        playedNorm = Norm(
            gamma: try weights.tensor("p2.lpb.gamma", count: blk), beta: try weights.tensor("p2.lpb.beta", count: blk))
        temporalOne = Layer(
            inputs: 2 * blk, units: u, kernel: try weights.tensor("p2.lstm1.kernel", count: 2 * blk * 4 * u),
            recurrent: try weights.tensor("p2.lstm1.recurrent", count: u * 4 * u),
            bias: try weights.tensor("p2.lstm1.bias", count: 4 * u)
        )
        temporalTwo = Layer(
            inputs: u, units: u, kernel: try weights.tensor("p2.lstm2.kernel", count: u * 4 * u),
            recurrent: try weights.tensor("p2.lstm2.recurrent", count: u * 4 * u),
            bias: try weights.tensor("p2.lstm2.bias", count: 4 * u)
        )
        gateKernel = try weights.tensor("p2.dense.kernel", count: u * blk)
        gateBias = try weights.tensor("p2.dense.bias", count: blk)
        decoder = try weights.tensor("p2.decoder", count: blk * blk)
        guard let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(blk), .FORWARD),
            let inverse = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(blk), .INVERSE)
        else { throw Weights.WeightsError.mismatch }
        self.forward = forward
        self.inverse = inverse
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    public func process(microphone: inout [Float], reference: [Float]) -> Bool {
        guard microphone.count == Self.hop, reference.count == Self.hop else { return false }
        slide(&micWindow, in: microphone)
        slide(&farWindow, in: reference)

        // Stage one: the mask over the microphone's spectrum.
        transform(micWindow, real: &realMic, imag: &imagMic)
        transform(farWindow, real: &realFar, imag: &imagFar)
        logPower(real: realMic, imag: imagMic, into: &micFeatures)
        logPower(real: realFar, imag: imagFar, into: &farFeatures)
        micNorm.apply(&micFeatures)
        farNorm.apply(&farFeatures)
        spectralInput.replaceSubrange(0..<Self.bins, with: micFeatures)
        spectralInput.replaceSubrange(Self.bins..<(2 * Self.bins), with: farFeatures)
        spectralOne.step(spectralInput)
        spectralTwo.step(spectralOne.hidden)
        dense(maskKernel, bias: maskBias, rows: units, columns: Self.bins, input: spectralTwo.hidden, into: &mask)
        sigmoid(&mask)
        applyMask()

        // Stage two: the mask over an encoding of the masked block.
        matrixVector(encoder, rows: Self.block, columns: Self.block, input: estimate, into: &encodedEstimate)
        matrixVector(encoder, rows: Self.block, columns: Self.block, input: farWindow, into: &encodedPlayed)
        var normalisedEstimate = encodedEstimate
        var normalisedPlayed = encodedPlayed
        estimateNorm.apply(&normalisedEstimate)
        playedNorm.apply(&normalisedPlayed)
        temporalInput.replaceSubrange(0..<Self.block, with: normalisedEstimate)
        temporalInput.replaceSubrange(Self.block..<(2 * Self.block), with: normalisedPlayed)
        temporalOne.step(temporalInput)
        temporalTwo.step(temporalOne.hidden)
        dense(gateKernel, bias: gateBias, rows: units, columns: Self.block, input: temporalTwo.hidden, into: &gate)
        sigmoid(&gate)
        gate.withUnsafeMutableBufferPointer { g in
            vDSP_vmul(encodedEstimate, 1, g.baseAddress!, 1, g.baseAddress!, 1, vDSP_Length(Self.block))
        }
        matrixVector(decoder, rows: Self.block, columns: Self.block, input: gate, into: &decoded)

        // Overlap-add: the oldest hop of the accumulator is done.
        let hop = Self.hop
        overlap.replaceSubrange(0..<(Self.block - hop), with: overlap[hop...])
        overlap.replaceSubrange((Self.block - hop)..<Self.block, with: repeatElement(0, count: hop))
        overlap.withUnsafeMutableBufferPointer { o in
            vDSP_vadd(o.baseAddress!, 1, decoded, 1, o.baseAddress!, 1, vDSP_Length(Self.block))
        }
        microphone.replaceSubrange(0..<hop, with: overlap[0..<hop])
        return true
    }

    // MARK: - pieces

    private func slide(_ window: inout [Float], in hop: [Float]) {
        window.replaceSubrange(0..<(Self.block - Self.hop), with: window[Self.hop...])
        window.replaceSubrange((Self.block - Self.hop)..<Self.block, with: hop)
    }

    /// Real DFT of one block into packed split form: DC in `real[0]`,
    /// Nyquist in `imag[0]`, bins 1 to 255 after that, all at twice the
    /// mathematical scale, which is how the library returns them.
    private func transform(_ block: [Float], real: inout [Float], imag: inout [Float]) {
        block.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.block / 2) { c in
                realIn.withUnsafeMutableBufferPointer { r in
                    imagIn.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(Self.block / 2))
                    }
                }
            }
        }
        vDSP_DFT_Execute(forward, realIn, imagIn, &real, &imag)
    }

    /// log(|X|^2 + eps) per bin, with the library's factor of two undone.
    private func logPower(real: [Float], imag: [Float], into out: inout [Float]) {
        let half = Self.block / 2
        var quarter: Float = 0.25
        // Bins 1 to 255 from the packed pairs; DC and Nyquist from slot 0.
        real.withUnsafeBufferPointer { r in
            imag.withUnsafeBufferPointer { i in
                out.withUnsafeMutableBufferPointer { o in
                    var split = DSPSplitComplex(
                        realp: UnsafeMutablePointer(mutating: r.baseAddress! + 1),
                        imagp: UnsafeMutablePointer(mutating: i.baseAddress! + 1)
                    )
                    vDSP_zvmags(&split, 1, o.baseAddress! + 1, 1, vDSP_Length(half - 1))
                    o[0] = r[0] * r[0]
                    o[half] = i[0] * i[0]
                }
            }
        }
        var epsilon = Self.epsilon
        var count = Int32(Self.bins)
        out.withUnsafeMutableBufferPointer { buffer in
            let p = buffer.baseAddress!
            vDSP_vsmul(p, 1, &quarter, p, 1, vDSP_Length(Self.bins))
            vDSP_vsadd(p, 1, &epsilon, p, 1, vDSP_Length(Self.bins))
            vvlogf(p, p, &count)
        }
    }

    /// The masked microphone spectrum back to a block of samples.
    private func applyMask() {
        let half = Self.block / 2
        var realMasked = realMic
        var imagMasked = imagMic
        vDSP_vmul(realMic, 1, mask, 1, &realMasked, 1, vDSP_Length(half))
        realMasked[0] = realMic[0] * mask[0]
        imagMasked[0] = imagMic[0] * mask[half]
        if half > 1 {
            mask.withUnsafeBufferPointer { m in
                imagMic.withUnsafeBufferPointer { i in
                    imagMasked.withUnsafeMutableBufferPointer { o in
                        vDSP_vmul(
                            i.baseAddress! + 1, 1, m.baseAddress! + 1, 1, o.baseAddress! + 1, 1, vDSP_Length(half - 1))
                    }
                }
            }
        }
        var realOut = [Float](repeating: 0, count: half)
        var imagOut = [Float](repeating: 0, count: half)
        vDSP_DFT_Execute(inverse, realMasked, imagMasked, &realOut, &imagOut)
        estimate.withUnsafeMutableBufferPointer { e in
            e.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { c in
                realOut.withUnsafeMutableBufferPointer { r in
                    imagOut.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        vDSP_ztoc(&split, 1, c, 2, vDSP_Length(half))
                    }
                }
            }
        }
        // Forward and inverse together scale by 2N.
        var scale = 1 / Float(2 * Self.block)
        estimate.withUnsafeMutableBufferPointer { e in
            vDSP_vsmul(e.baseAddress!, 1, &scale, e.baseAddress!, 1, vDSP_Length(Self.block))
        }
    }

    /// out = input . kernel + bias, with kernel stored as rows x columns.
    private func dense(
        _ kernel: [Float], bias: [Float], rows: Int, columns: Int, input: [Float], into out: inout [Float]
    ) {
        vDSP_mmul(input, 1, kernel, 1, &out, 1, 1, vDSP_Length(columns), vDSP_Length(rows))
        out.withUnsafeMutableBufferPointer { o in
            vDSP_vadd(o.baseAddress!, 1, bias, 1, o.baseAddress!, 1, vDSP_Length(columns))
        }
    }

    /// out = matrix . input, with matrix stored as rows (out) x columns (in).
    private func matrixVector(_ matrix: [Float], rows: Int, columns: Int, input: [Float], into out: inout [Float]) {
        vDSP_mmul(matrix, 1, input, 1, &out, 1, vDSP_Length(rows), 1, vDSP_Length(columns))
    }

    private func sigmoid(_ x: inout [Float]) {
        let count = x.count
        x.withUnsafeMutableBufferPointer { Self.sigmoid($0.baseAddress!, count: count) }
    }
}
