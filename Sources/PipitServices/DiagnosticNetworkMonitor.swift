import Foundation
import Network
import PipitCore

/// What automatic sharing knows about the network: whether there is a path,
/// and whether it is in Low Data Mode or expensive.
///
/// Reads as offline until the monitor's first update, which arrives right
/// after `start`, so nothing automatic goes before the network is known.
final class DiagnosticNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.pipit.diagnostics.network", qos: .utility)
    private let lock = NSLock()
    private var latest = DiagnosticNetworkCondition.unknown

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let condition = DiagnosticNetworkCondition(
                isSatisfied: path.status == .satisfied, isConstrained: path.isConstrained,
                isExpensive: path.isExpensive
            )
            self?.update(condition)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    var condition: DiagnosticNetworkCondition {
        lock.withLock { latest }
    }

    private func update(_ condition: DiagnosticNetworkCondition) {
        lock.withLock { latest = condition }
    }
}
