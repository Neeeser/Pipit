import Foundation

/// The committed description of the benchmark data: where the audio comes from,
/// what it must hash to, and which meetings each suite runs.
///
/// One file, read by `scripts/fetch-bench-audio.sh` and by the harness, because
/// two copies of a checksum list drift.
public struct BenchManifest: Codable, Sendable, Equatable {
    /// The AMI mirror template, taking the meeting identifier twice.
    public var mirror: String
    /// Full download URL for a recording the mirror template does not name,
    /// which is every ICSI and NOTSOFAR meeting: the corpora publish under
    /// different paths and under different file names.
    public var audioURL: [String: String]?
    /// The local file name a download is saved under when the URL's own last
    /// component would collide: every NOTSOFAR recording is published as
    /// `ch0.wav` inside its meeting's folder. Absent means the URL's last
    /// component, which is what the ground truth names as its source.
    public var audioFilename: [String: String]?
    /// Corpus name to the annotations archive its truth is generated from.
    public var annotations: [String: Archive]
    /// Meeting identifier to SHA-256 of its Mix-Headset recording.
    public var audio: [String: String]
    /// Suite name to the meetings it runs, in order.
    public var suites: [String: [String]]
    /// Meeting identifier to where it sits relative to model training data:
    /// `ami-train`, `ami-dev` and `ami-eval` follow AMI's published
    /// full-corpus-ASR split, `excluded` is a meeting that split leaves out,
    /// and `clean` is a corpus with no known presence in any candidate's
    /// training data. Parakeet's model card lists AMI among its training
    /// corpora, so a suite that ranks engines may hold only `ami-eval` and
    /// `clean` meetings; the rest regression-test a fixed engine against
    /// itself, where contamination sits on both sides of the comparison.
    public var partition: [String: String]?
    /// The simulated two-track call suite, built from close-talk channels.
    /// Absent in a manifest written before the suite existed.
    public var calls: Calls?

    public struct Archive: Codable, Sendable, Equatable {
        public var url: String
        public var sha256: String
    }

    /// How the `calls` suite is made: which meetings, which channel each person
    /// spoke into, who plays the local person, and which microphone variants
    /// are rendered. The generator in `Benchmarks/calls` reads the same block.
    public struct Calls: Codable, Sendable, Equatable {
        /// The suite's name on the command line.
        public static let suite = "calls"

        public struct Variant: Codable, Sendable, Equatable {
            public var name: String
            /// The `echoCorrelationBefore` the microphone is built to read, or
            /// nil for a microphone with no echo.
            public var echoCorrelation: Double?
        }

        public struct Channel: Codable, Sendable, Equatable {
            public var channel: Int
            public var sha256: String
        }

        public struct Meeting: Codable, Sendable, Equatable {
            /// The annotation agent who plays the local person.
            public var localAgent: String
            /// Annotation agent to the headset channel that person spoke into.
            public var channels: [String: Channel]
        }

        /// Seeds every choice the generator makes, so a rebuild writes the same
        /// audio.
        public var seed: Int
        /// URL template for one channel, taking the meeting and the channel.
        public var mirror: String
        public var variants: [Variant]
        public var meetings: [String: Meeting]

        /// Case names in a stable order: each meeting with every variant.
        public var caseNames: [String] {
            meetings.keys.sorted().flatMap { meeting in
                variants.map { "\(meeting)-\($0.name)" }
            }
        }

        /// The meeting and variant a case name stands for.
        public func parse(case name: String) -> (meeting: String, variant: Variant)? {
            for meeting in meetings.keys.sorted() where name.hasPrefix(meeting + "-") {
                let rest = String(name.dropFirst(meeting.count + 1))
                if let variant = variants.first(where: { $0.name == rest }) {
                    return (meeting, variant)
                }
            }
            return nil
        }
    }

    public static func read(from url: URL) throws -> BenchManifest {
        try JSONDecoder().decode(BenchManifest.self, from: Data(contentsOf: url))
    }
}

/// Where the committed benchmark material lives, relative to a repository root.
public struct BenchLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var manifest: URL { root.appendingPathComponent("manifest.json") }
    public func truth(meeting: String) -> URL {
        root.appendingPathComponent("ground-truth/\(meeting).json")
    }
}
