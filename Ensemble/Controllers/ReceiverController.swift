import Foundation
import Combine
import Network

@MainActor
final class ReceiverController: ObservableObject {
    @Published private(set) var state: ReceiverClient.State = .idle
    @Published private(set) var snapshot = ReceiverClient.Snapshot()
    @Published private(set) var eventLog: [String] = []
    @Published var manualHost = ""
    @Published var manualPort = ""
    @Published var pairingCode = "" { didSet { client.pairingCode = pairingCode } }
    @Published var volume: Float = 1 { didSet { client.volume = volume } }
    @Published var trimMs: Double = 0 { didSet { client.trimMs = trimMs } }
    @Published var autoReconnect = true
    @Published var showDiagnostics = false
    @Published var showManualConnect = false

    let discovery = BonjourDiscoveryService()
    let receiverName: String

    private let client: ReceiverClient
    private var statsTimer: Timer?
    private var reconnectTimer: Timer?
    private var lastEndpoint: NWEndpoint?
    private var lastHostName = ""
    private var userDisconnected = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        let defaults = UserDefaults.standard
        receiverName = defaults.string(forKey: "name") ?? Host.current().localizedName ?? "Mac"
        client = ReceiverClient(receiverName: receiverName)
        if let code = defaults.string(forKey: "pairing") { pairingCode = code; client.pairingCode = code }
        client.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.handleState(state) }
        }
        client.onEvent = { [weak self] text in
            DispatchQueue.main.async { self?.log(text) }
        }
        discovery.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        discovery.start()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var hosts: [BonjourDiscoveryService.DiscoveredHost] { discovery.hosts }
    var streamSampleRate: Double { client.player?.sampleRate ?? 0 }
    var discoveryStatus: String { discovery.status }

    func connect(to host: BonjourDiscoveryService.DiscoveredHost) {
        lastHostName = host.name
        connect(endpoint: host.endpoint, label: host.name)
    }

    func connectManual() {
        let hostText = manualHost.trimmingCharacters(in: .whitespaces)
        guard !hostText.isEmpty, let port = UInt16(manualPort.trimmingCharacters(in: .whitespaces)),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            log("Enter a host address and port (the host shows its control port).")
            return
        }
        lastHostName = hostText
        connect(endpoint: .hostPort(host: NWEndpoint.Host(hostText), port: nwPort), label: "\(hostText):\(port)")
    }

    func disconnect() {
        userDisconnected = true
        reconnectTimer?.invalidate(); reconnectTimer = nil
        client.disconnect()
    }

    func refreshDiscovery() { discovery.start() }

    func shutdown() {
        statsTimer?.invalidate()
        reconnectTimer?.invalidate()
        client.disconnect()
        discovery.stop()
    }

    // MARK: - Private

    private func connect(endpoint: NWEndpoint, label: String) {
        userDisconnected = false
        reconnectTimer?.invalidate(); reconnectTimer = nil
        lastEndpoint = endpoint
        log("Connecting to \(label)…")
        client.connect(to: endpoint)
    }

    private func handleState(_ new: ReceiverClient.State) {
        state = new
        log(new.label)
        switch new {
        case .failed, .disconnected:
            scheduleReconnectIfNeeded()
        default:
            break
        }
    }

    private func scheduleReconnectIfNeeded() {
        guard autoReconnect, !userDisconnected, let endpoint = lastEndpoint else { return }
        reconnectTimer?.invalidate()
        log("Reconnecting in 3 s…")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.userDisconnected, !self.state.isActive else { return }
                // Prefer the freshly discovered endpoint for the same host name if available.
                let target = self.discovery.hosts.first(where: { $0.name == self.lastHostName })?.endpoint ?? endpoint
                self.client.connect(to: target)
            }
        }
    }

    private func refresh() {
        snapshot = client.snapshot()
    }

    private func log(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        eventLog.append("\(f.string(from: Date()))  \(text)")
        if eventLog.count > 200 { eventLog.removeFirst(eventLog.count - 200) }
        Log.info(text)
    }
}
