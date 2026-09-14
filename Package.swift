// swift-tools-version: 6.0
import PackageDescription

// The C and C++ halves of CLocalVQE take the same defines and search paths.
// SwiftPM types the two setting lists differently, so the list is written
// once here and mapped into each.
enum LocalVQESetting {
    case define(String, String?)
    case headerSearchPath(String)
}

let localVQESettings: [LocalVQESetting] = [
    .headerSearchPath("ggml/include"),
    .headerSearchPath("ggml/src"),
    .headerSearchPath("ggml/src/ggml-cpu"),
    .headerSearchPath("localvqe"),
    .define("GGML_USE_CPU", nil),
    .define("GGML_USE_ACCELERATE", nil),
    .define("GGML_USE_CPU_REPACK", nil),
    .define("GGML_SCHED_MAX_COPIES", "4"),
    .define("ACCELERATE_NEW_LAPACK", nil),
    .define("ACCELERATE_LAPACK_ILP64", nil),
    .define("_DARWIN_C_SOURCE", nil),
    .define("_XOPEN_SOURCE", "600"),
    .define("GGML_VERSION", "\"0.9.8\""),
    .define("GGML_COMMIT", "\"c044a8ee\""),
    .define("NDEBUG", nil),
]

// Pipit is built with SwiftPM rather than xcodebuild. scripts/bundle-app.sh
// assembles the SwiftPM products into Pipit.app.
let package = Package(
    name: "Pipit",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Pipit", targets: ["PipitApp"]),
        .executable(name: "pipit-nativehost", targets: ["PipitNativeHost"]),
        .executable(name: "pipit-eval", targets: ["PipitEval"]),
        // The three libraries the application links. The Xcode target in
        // project.yml compiles Sources/PipitApp and links these, so it builds
        // the same modules `swift build` does.
        .library(name: "PipitCore", targets: ["PipitCore"]),
        .library(name: "PipitServices", targets: ["PipitServices"]),
        .library(name: "PipitUI", targets: ["PipitUI"]),
    ],
    // Pinned to the exact versions the local-processing and speaker-scale probes
    // measured. A newer revision changes transcription and embedding behaviour,
    // so it is a re-evaluation, not a bump.
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6"),
        // Sparkle ships the updater as a framework with nested XPC services and
        // an Autoupdate helper. A version change moves that signing layout and
        // changes how the updater behaves, so the version is exact and a bump
        // is a re-test of the update flow.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        // Pure logic. Foundation only: state machines, manifest, timeline arithmetic,
        // chunk planning, transcript merging, storage layout. Everything here is
        // deterministic and directly testable.
        .target(name: "PipitCore"),

        // LocalVQE's echo canceller and the ggml it runs on, vendored as
        // source (Apache-2.0 and MIT, see Sources/CLocalVQE/UPDATING.md). CPU
        // only, with Accelerate for the matrix work: the model is a few
        // thousand parameters and a GPU round trip per 16 ms hop would cost
        // more than the arithmetic. No GTCRN line, no BLAS backend, no Metal.
        .target(
            name: "CLocalVQE",
            path: "Sources/CLocalVQE",
            exclude: ["UPDATING.md", "LICENSE-LocalVQE", "LICENSE-ggml"],
            publicHeadersPath: "include",
            cSettings: localVQESettings.map { setting -> CSetting in
                switch setting {
                case .define(let name, let value): return .define(name, to: value)
                case .headerSearchPath(let path): return .headerSearchPath(path)
                }
            },
            cxxSettings: localVQESettings.map { setting -> CXXSetting in
                switch setting {
                case .define(let name, let value): return .define(name, to: value)
                case .headerSearchPath(let path): return .headerSearchPath(path)
                }
            },
            linkerSettings: [.linkedFramework("Accelerate")]
        ),

        // The echo canceller's model files ride along as resources, so the
        // pass can run offline on any Mac the app is installed on.
        .target(
            name: "PipitAudio", dependencies: ["PipitCore", "CLocalVQE"],
            resources: [.copy("Resources/EchoModels")]
        ),

        // Accessibility, window titles, CoreAudio process observation, browser sensor
        // transport. Turns OS signals into provider evidence.
        .target(name: "PipitDetection", dependencies: ["PipitCore", "PipitAudio"]),

        // OpenAI, Keychain, EventKit, UserNotifications.
        .target(name: "PipitIntegrations", dependencies: ["PipitCore"]),

        // The local voice-identity store: SQLite with Float32 embedding BLOBs,
        // plus the recognition service that scores a speaker occurrence against
        // it. Independent of which transcription or diarization backend ran, so
        // choosing OpenAI in Settings still keeps voice memory local.
        .target(name: "PipitSpeakers", dependencies: ["PipitCore"]),

        // On-device speech: WhisperKit transcription and the FluidAudio offline
        // diarizer, behind the same protocols the OpenAI client implements.
        .target(
            name: "PipitLocalAI",
            dependencies: [
                "PipitCore",
                "PipitAudio",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),

        // Wiring: session controller runtime, capture engine, processing pipeline,
        // meeting repository, app coordinator.
        .target(
            name: "PipitServices",
            dependencies: [
                "PipitCore", "PipitAudio", "PipitDetection", "PipitIntegrations",
                "PipitSpeakers", "PipitLocalAI",
            ]
        ),

        // SwiftUI/AppKit surfaces.
        .target(
            name: "PipitUI",
            dependencies: ["PipitServices", .product(name: "Sparkle", package: "Sparkle")]
        ),

        // The rpath is what lets the executable find Sparkle.framework after
        // scripts/bundle-app.sh copies it into Contents/Frameworks. SwiftPM
        // links the framework as @rpath/Sparkle.framework/Versions/B/Sparkle
        // but emits no rpath of its own that reaches a bundle layout.
        .executableTarget(
            name: "PipitApp",
            dependencies: ["PipitUI"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),

        // Firefox native messaging host. A compiled binary, because Firefox spawns
        // hosts with a minimal PATH and an interpreter shebang silently fails.
        .executableTarget(name: "PipitNativeHost", dependencies: ["PipitCore"]),

        // The benchmark meter: ground-truth model, scorer and suite manifest.
        // Foundation only, so the same arithmetic runs in the test suite and in
        // the evaluation tool, and so nothing eval-only lands in PipitCore.
        .target(name: "PipitBench"),

        // Developer evaluation tool. Not bundled into the application: it is how
        // the local stack's measured numbers get checked again on real audio.
        .executableTarget(
            name: "PipitEval",
            dependencies: [
                "PipitCore", "PipitAudio", "PipitLocalAI", "PipitSpeakers",
                "PipitBench", "PipitIntegrations", "PipitServices",
            ]
        ),

        // The suite, under Swift Testing. `Support/` holds the fixtures and
        // fakes the test files share. It builds recordings, stores and stub
        // backends, and every assertion lives in the test that runs it.
        .testTarget(
            name: "PipitTests",
            dependencies: [
                "PipitCore", "PipitAudio", "PipitDetection",
                "PipitIntegrations", "PipitSpeakers", "PipitLocalAI",
                "PipitServices", "PipitUI", "PipitBench",
            ],
            path: "Tests/PipitTests"
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
