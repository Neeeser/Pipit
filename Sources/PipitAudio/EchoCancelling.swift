import Foundation

/// Subtracts what was played from what the microphone heard, one block at a
/// time.
///
/// The far end goes out of the speakers and comes back into the microphone.
/// A canceller is given the recording of what was played and the microphone
/// block for the same moment, and hands back the microphone with the far end
/// taken out. Every block is the same length, the reference is given first,
/// and the state carried between blocks is the canceller's own.
public protocol EchoCancelling: AnyObject {
    /// Frames per call, for both streams.
    var blockFrames: Int { get }

    /// Frames the cleaned output sits behind the input, so a caller can put
    /// the cleaned track back on the recording's clock.
    var latencyFrames: Int { get }

    /// What the canceller itself says it removed over the most recent blocks,
    /// in decibels, when it reports such a thing. Informational: a measured
    /// figure comes from comparing levels, not from asking.
    var reportedRemovalDB: Double? { get }

    /// Cleans one block of microphone audio in place. Both arrays hold
    /// `blockFrames` samples. False when the canceller refused the block.
    func process(microphone: inout [Float], reference: [Float]) -> Bool
}
