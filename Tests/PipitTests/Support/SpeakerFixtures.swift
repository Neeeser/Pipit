import Foundation
import PipitCore
import PipitSpeakers

/// Voice vectors and an empty speaker store on disk.
public enum SpeakerFixtures {
    /// A deterministic unit vector, so two calls with the same seed are the same
    /// voice and different seeds are far apart.
    public static func vector(seed: Int, dimension: Int = 256, jitter: Float = 0) -> [Float] {
        var state = UInt64(bitPattern: Int64(seed) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407)
        var out = [Float](repeating: 0, count: dimension)
        for index in 0..<dimension {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(Double(state >> 11) / Double(UInt64(1) << 53)) - 0.5
            out[index] = unit + jitter * Float(index % 7)
        }
        return VoiceVector.l2Normalized(out)
    }

    /// A vector `towards` of the way from `base` to `other`, for building a
    /// fixture that lands between two thresholds.
    public static func blended(_ base: [Float], with other: [Float], towards: Float) -> [Float] {
        VoiceVector.l2Normalized(zip(base, other).map { $0 * (1 - towards) + $1 * towards })
    }

    public static func makeStore() throws -> (SpeakerStore, URL) {
        let root = try TestPaths.makeTemporaryDirectory()
        let store = try SpeakerStore(url: root.appendingPathComponent("voices.sqlite"))
        return (store, root)
    }
}
