import CLocalVQE
import Foundation

/// LocalVQE's echo canceller: a delay estimator, a partitioned Kalman filter
/// spanning one second of echo path, and for the full model a learned mask
/// over what the filter leaves.
///
/// The filter-only model is the first stage of the pass Pipit ships. It lines
/// the far end up on its own (a lead of up to a second), takes the bulk of the
/// echo out linearly, and hands the rest to the neural stage. Measured on the
/// bake-off of 11 September 2026 (`Benchmarks/aec`): ahead of the neural stage
/// it kept 87% of the user's words through loud double talk where the
/// previous canceller kept 52%.
///
/// The library reads the model from a path and checks its digest against a
/// list compiled into it, so a model file that is not one it knows is refused
/// at construction.
public final class LocalVQECanceller: EchoCancelling {
    /// Samples per call: the library's hop.
    public let blockFrames: Int
    /// One hop of output delay for the full model; the filter alone emits the
    /// filter's error signal with no delay. The library reports which through
    /// the model it loaded, so this is measured rather than assumed.
    public let latencyFrames: Int
    public var reportedRemovalDB: Double? { nil }

    private let context: localvqe_ctx_t
    private var output: [Float]

    /// Nil when the model could not be loaded: a missing file, a digest the
    /// library does not know, or a rate other than 16 kHz.
    ///
    /// - Parameter threads: the library defaults to four, which is too many
    ///   for a pass that runs beside a live capture. Two is the whole of what
    ///   a 203K-parameter mask needs.
    public init?(model: URL, sampleRate: Int, threads: Int = 2, filterOnlyLatency: Bool) {
        guard sampleRate == 16_000 else { return nil }
        let options = localvqe_options_new()
        guard options != 0 else { return nil }
        defer { localvqe_options_free(options) }
        guard localvqe_options_set_model_path(options, model.path) == 0,
            localvqe_options_set_threads(options, Int32(threads)) == 0
        else { return nil }
        let context = localvqe_new_with_options(options)
        guard context != 0 else { return nil }
        guard localvqe_sample_rate(context) == Int32(sampleRate) else {
            localvqe_free(context)
            return nil
        }
        self.context = context
        blockFrames = Int(localvqe_hop_length(context))
        latencyFrames = filterOnlyLatency ? 0 : blockFrames
        output = [Float](repeating: 0, count: blockFrames)
    }

    deinit { localvqe_free(context) }

    public func process(microphone: inout [Float], reference: [Float]) -> Bool {
        guard microphone.count == blockFrames, reference.count == blockFrames else {
            return false
        }
        let status = microphone.withUnsafeBufferPointer { mic in
            reference.withUnsafeBufferPointer { ref in
                output.withUnsafeMutableBufferPointer { out in
                    localvqe_process_frame_f32(
                        context, mic.baseAddress, ref.baseAddress, Int32(blockFrames),
                        out.baseAddress
                    )
                }
            }
        }
        guard status == 0 else { return false }
        microphone = output
        return true
    }
}
