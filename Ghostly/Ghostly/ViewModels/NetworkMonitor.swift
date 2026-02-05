import Foundation
import Network

@Observable
final class NetworkMonitor {
    var isConnected: Bool = true
    var connectionType: String = "Unknown"
    var interfaceName: String = ""

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.ghostly.networkmonitor")
    private var onChange: (() -> Void)?
    private var debounceTask: Task<Void, Never>?

    var statusText: String {
        if !isConnected {
            return "No Network"
        }
        return "\(connectionType) (Connected)"
    }

    init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
        debounceTask?.cancel()
    }

    func onNetworkChange(_ handler: @escaping () -> Void) {
        onChange = handler
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let wasConnected = self.isConnected

            DispatchQueue.main.async {
                self.isConnected = (path.status == .satisfied)

                if path.usesInterfaceType(.wifi) {
                    self.connectionType = "WiFi"
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self.connectionType = "Ethernet"
                } else if path.usesInterfaceType(.cellular) {
                    self.connectionType = "Cellular"
                } else {
                    self.connectionType = "Other"
                }

                // Notify on changes with debounce
                if wasConnected != self.isConnected || self.isConnected {
                    self.debounceNotify()
                }
            }
        }
        monitor.start(queue: queue)
    }

    private func debounceNotify() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            onChange?()
        }
    }
}
