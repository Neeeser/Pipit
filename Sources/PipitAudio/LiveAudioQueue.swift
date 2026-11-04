import Foundation
import PipitCore
import Synchronization

/// One buffer for the live transcript, and the track it came from.
public struct LiveAudioItem: Sendable {
    public let packet: AudioBufferPacket
    public let track: CaptureTrack

    public init(packet: AudioBufferPacket, track: CaptureTrack) {
        self.packet = packet
        self.track = track
    }
}

/// Carries buffers from the audio threads to the live transcript.
///
/// The audio threads call `push`, which takes one lock and appends to storage
/// reserved up front, so it never allocates, never wakes anything, and never
/// touches a generic type the runtime would have to look up. When the reader
/// has fallen a whole queue behind, the new buffer is counted and dropped:
/// the live text loses a moment, and the recording, already written by the
/// segment writer, loses nothing.
///
/// An `AsyncStream` that dropped its oldest element did this work on the
/// microphone's tap thread instead, and overflowed that thread's stack once
/// the stream was full.
public final class LiveAudioQueue: Sendable {
    private struct State {
        var items: [LiveAudioItem]
        var dropped = 0
    }

    public let capacity: Int
    private let state: Mutex<State>

    public init(capacity: Int) {
        self.capacity = capacity
        var items: [LiveAudioItem] = []
        items.reserveCapacity(capacity)
        state = Mutex(State(items: items))
    }

    /// Buffers waiting to be read.
    public var count: Int { state.withLock { $0.items.count } }

    /// Called on the audio threads.
    public func push(_ packet: AudioBufferPacket, track: CaptureTrack) {
        state.withLock { state in
            if state.items.count >= capacity {
                state.dropped += 1
            } else {
                state.items.append(LiveAudioItem(packet: packet, track: track))
            }
        }
    }

    /// Everything queued so far in arrival order, and how many buffers were
    /// dropped since the last call. The storage handed back is replaced with
    /// a fresh reserved one here, on the reader's side, so the audio threads
    /// keep appending without allocating.
    public func drain() -> (items: [LiveAudioItem], dropped: Int) {
        var fresh: [LiveAudioItem] = []
        fresh.reserveCapacity(capacity)
        return state.withLock { state in
            let out = (state.items, state.dropped)
            swap(&state.items, &fresh)
            state.dropped = 0
            return out
        }
    }
}
