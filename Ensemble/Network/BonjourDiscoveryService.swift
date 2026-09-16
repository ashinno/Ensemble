import Foundation
import Network

/// Browses the local network for Ensemble hosts (`_ensemble._tcp`).
/// Advertising is done by `HostStreamServer` through its TCP listener's `service`.
final class BonjourDiscoveryService: ObservableObject {
    struct DiscoveredHost: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
        static func == (a: DiscoveredHost, b: DiscoveredHost) -> Bool { a.name == b.name }
        func hash(into hasher: inout Hasher) { hasher.combine(name) }
    }

    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var status = "Not browsing"

    private var browser: NWBrowser?

    func start() {
        stop()
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Wire.bonjourType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready: self?.status = "Browsing for hosts…"
                case .failed(let error): self?.status = "Discovery failed: \(error.localizedDescription)"
                case .waiting(let error): self?.status = "Waiting for network: \(error.localizedDescription)"
                case .cancelled: self?.status = "Not browsing"
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredHost(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Log.info("Discovered hosts: \(hosts.map(\.name).joined(separator: ", "))")
            DispatchQueue.main.async { self?.hosts = hosts }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
        status = "Not browsing"
    }
}
