import Foundation

/// Two cancellers in series: the first takes the bulk of the echo out, the
/// second works on what it leaves.
///
/// The pass Pipit ships is LocalVQE's adaptive filter followed by DTLN-aec.
/// The filter lines the far end up and removes the linear part of the echo
/// path; the network removes what a linear filter cannot, the distortion a
/// laptop speaker adds when it is loud. Measured on the bake-off of 11
/// September 2026: the pair leaked one far-end word in twenty minutes of
/// loud double talk against thirteen for the previous canceller, and kept 87%
/// of the user's words against 52%.
///
/// The block is the two cancellers' blocks combined, so a caller feeds one
/// size and each stage sees whole blocks of its own.
public final class CascadeEchoCanceller: EchoCancelling {
    public let blockFrames: Int
    public let latencyFrames: Int
    public var reportedRemovalDB: Double? { first.reportedRemovalDB ?? second.reportedRemovalDB }

    private let first: any EchoCancelling
    private let second: any EchoCancelling
    private var reference: [Float]

    /// Nil when one stage's block does not divide the other's.
    public init?(first: any EchoCancelling, second: any EchoCancelling) {
        let a = first.blockFrames
        let b = second.blockFrames
        guard a > 0, b > 0, a % b == 0 || b % a == 0 else { return nil }
        self.first = first
        self.second = second
        blockFrames = max(a, b)
        latencyFrames = first.latencyFrames + second.latencyFrames
        reference = []
    }

    public func process(microphone: inout [Float], reference: [Float]) -> Bool {
        guard microphone.count == blockFrames, reference.count == blockFrames else { return false }
        return run(first, microphone: &microphone, reference: reference)
            && run(second, microphone: &microphone, reference: reference)
    }

    /// One stage over the whole block, in that stage's own block size.
    private func run(_ stage: any EchoCancelling, microphone: inout [Float], reference: [Float]) -> Bool {
        let size = stage.blockFrames
        var offset = 0
        while offset < blockFrames {
            var piece = Array(microphone[offset..<(offset + size)])
            let played = Array(reference[offset..<(offset + size)])
            guard stage.process(microphone: &piece, reference: played) else { return false }
            microphone.replaceSubrange(offset..<(offset + size), with: piece)
            offset += size
        }
        return true
    }
}
