import Foundation

/// The canceller Pipit ships, built from the models in this module's bundle.
///
/// LocalVQE's adaptive filter first, then DTLN-aec. Both model files travel
/// with the app as resources: 17 KB for the filter's learned step-size
/// controller and 41 MB for the network. Chosen by the bake-off of 11
/// September 2026 in `Benchmarks/aec`, which is also where the weight file
/// is produced from the published model.
public enum EchoModels {
    public static let filterModel = "localvqe-v1.4-aec-2.7K-f32.gguf"
    public static let networkModel = "dtln-aec-512"
    static let directory = "EchoModels"

    public enum ModelError: Error, Equatable {
        case missing(String)
        case refused(String)
    }

    /// Where the model files are.
    ///
    /// In the app, `scripts/bundle-app.sh` copies them into the application
    /// bundle's Resources, which is where every other resource of the app
    /// lives. Under `swift test` and `swift run` they are in this module's own
    /// resource bundle next to the build products, and an Xcode build puts
    /// that module bundle inside the app, where the module accessor finds it.
    public static func modelDirectory() throws -> URL {
        if let url = Bundle.main.url(forResource: directory, withExtension: nil) {
            return url
        }
        guard let url = Bundle.module.url(forResource: directory, withExtension: nil) else {
            throw ModelError.missing(directory)
        }
        return url
    }

    /// The shipped pass: filter into network.
    public static func shippedCanceller(sampleRate: Int) throws -> any EchoCancelling {
        let models = try modelDirectory()
        let filterURL = models.appendingPathComponent(filterModel)
        guard FileManager.default.fileExists(atPath: filterURL.path) else {
            throw ModelError.missing(filterModel)
        }
        guard
            let filter = LocalVQECanceller(
                model: filterURL, sampleRate: sampleRate, filterOnlyLatency: true
            )
        else { throw ModelError.refused(filterModel) }
        let network = try DTLNCanceller(
            weights: DTLNCanceller.Weights(directory: models, name: networkModel)
        )
        guard let cascade = CascadeEchoCanceller(first: filter, second: network) else {
            throw ModelError.refused(networkModel)
        }
        return cascade
    }
}
