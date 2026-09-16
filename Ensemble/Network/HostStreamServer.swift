import Foundation
import Network

/// Host side of the protocol.
///
/// * A TCP listener (advertised over Bonjour as `_ensemble._tcp`) carries JSON control
///   messages: hello / pairing, latency and volume changes, sync-test commands and
///   receiver statistics.
/// * A UDP listener carries audio packets (host → receiver) and clock-sync pings
///   (receiver → host → receiver). The receiver opens the UDP flow, so the host never
///   needs to know the receiver's address in advance.
final class HostStreamServer {
    enum ReceiverState: String { case pending = "Waiting for approval", connected = "Connected", streaming = "Streaming" }

    struct ReceiverInfo: Identifiable, Equatable {
        let id: UUID
        var name: String
        var address: String
        var state: ReceiverState
        var stats: ReceiverStats?
        var volume: Float
        var connectedAt: Date
        var lastStatsAt: Date?
    }

    private final class Session {
        let id = UUID()
        let token: UInt64
        let tcp: NWConnection
        var udp: NWConnection?
        var name = "Unknown Mac"
        var address: String
        var state: ReceiverState = .pending
        var stats: ReceiverStats?
        var volume: Float = 1
        var parser = ControlFrameParser()
        let connectedAt = Date()
        var lastStatsAt: Date?
        var lastActivity = Date()
        var helloReceived = false

        init(token: UInt64, tcp: NWConnection, address: String) {
            self.token = token; self.tcp = tcp; self.address = address
        }
    }

    // Configuration (set before start / adjustable at runtime)
    var hostName: String
    var pairingCode: String?
    var latencyMs: Double = 150
    var sampleRate: Double = 48000
    var channels = 2

    // Callbacks (delivered on the server queue; hop to main for UI)
    var onReceiversChanged: (([ReceiverInfo]) -> Void)?
    var onEvent: ((String) -> Void)?

    private(set) var tcpPort: UInt16 = 0
    private(set) var udpPort: UInt16 = 0
    private(set) var isRunning = false

    private let queue = DispatchQueue(label: "ensemble.host.server", qos: .userInteractive)
    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var sessions: [UInt64: Session] = [:]
    private var unboundUDP: [ObjectIdentifier: NWConnection] = [:]
    private var housekeeping: DispatchSourceTimer?
    private var packetsSent = 0
    private var sendErrors = 0

    init(hostName: String) {
        self.hostName = hostName
    }

    // MARK: - Lifecycle

    func start(tcpPort requestedTCP: UInt16 = 0, udpPort requestedUDP: UInt16 = 0, advertise: Bool = true) throws {
        try queue.sync {
            stopLocked()
            let tcpParams = NWParameters.tcp
            tcpParams.allowLocalEndpointReuse = true
            tcpParams.includePeerToPeer = false
            let tcp = try NWListener(using: tcpParams, on: requestedTCP == 0 ? .any : NWEndpoint.Port(rawValue: requestedTCP)!)
            if advertise {
                tcp.service = NWListener.Service(name: hostName, type: Wire.bonjourType)
            }
            tcp.stateUpdateHandler = { [weak self] state in self?.tcpListenerState(state) }
            tcp.newConnectionHandler = { [weak self] conn in self?.acceptTCP(conn) }

            let udpParams = NWParameters.udp
            udpParams.allowLocalEndpointReuse = true
            let udp = try NWListener(using: udpParams, on: requestedUDP == 0 ? .any : NWEndpoint.Port(rawValue: requestedUDP)!)
            udp.stateUpdateHandler = { [weak self] state in self?.udpListenerState(state) }
            udp.newConnectionHandler = { [weak self] conn in self?.acceptUDP(conn) }

            tcpListener = tcp
            udpListener = udp
            tcp.start(queue: queue)
            udp.start(queue: queue)
            isRunning = true

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.housekeep() }
            housekeeping = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        housekeeping?.cancel(); housekeeping = nil
        for s in sessions.values {
            s.tcp.send(content: try? ControlFraming.frame(.goodbye), completion: .contentProcessed { _ in })
            s.udp?.cancel()
            s.tcp.cancel()
        }
        sessions.removeAll()
        unboundUDP.values.forEach { $0.cancel() }
        unboundUDP.removeAll()
        tcpListener?.cancel(); tcpListener = nil
        udpListener?.cancel(); udpListener = nil
        isRunning = false
        tcpPort = 0; udpPort = 0
        publish()
    }

    // MARK: - Public actions

    /// Send an audio packet to every streaming receiver.
    func broadcast(_ packet: AudioPacket) {
        let data = UDPMessage.audio(packet).encode()
        queue.async { [self] in
            for s in sessions.values where s.state == .streaming {
                guard let udp = s.udp else { continue }
                udp.send(content: data, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.sendErrors += 1 }
                })
            }
            packetsSent += 1
        }
    }

    func approve(_ id: UUID) {
        queue.async { [self] in
            guard let s = sessions.values.first(where: { $0.id == id }), s.state == .pending else { return }
            accept(s)
        }
    }

    func deny(_ id: UUID) {
        queue.async { [self] in
            guard let s = sessions.values.first(where: { $0.id == id }) else { return }
            send(.rejected(reason: "The host declined the connection."), to: s)
            queue.asyncAfter(deadline: .now() + 0.3) { self.remove(s, reason: "denied") }
        }
    }

    func disconnect(_ id: UUID) {
        queue.async { [self] in
            guard let s = sessions.values.first(where: { $0.id == id }) else { return }
            send(.goodbye, to: s)
            queue.asyncAfter(deadline: .now() + 0.3) { self.remove(s, reason: "disconnected by host") }
        }
    }

    func setVolume(_ volume: Float, for id: UUID) {
        queue.async { [self] in
            guard let s = sessions.values.first(where: { $0.id == id }) else { return }
            s.volume = volume
            send(.setVolume(volume: volume), to: s)
            publish()
        }
    }

    func setLatency(ms: Double) {
        queue.async { [self] in
            latencyMs = ms
            for s in sessions.values where s.state != .pending { send(.setLatency(ms: ms), to: s) }
        }
    }

    /// Ask every receiver to play a click at the given host time.
    func sendSyncTest(hostTimeNs: Int64) {
        queue.async { [self] in
            for s in sessions.values where s.state == .streaming { send(.syncTest(hostTimeNs: hostTimeNs), to: s) }
        }
    }

    func snapshot() -> [ReceiverInfo] {
        queue.sync { infos() }
    }

    // MARK: - Listener state

    private func tcpListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            tcpPort = tcpListener?.port?.rawValue ?? 0
            Log.info("TCP control listener ready on port \(tcpPort)")
            onEvent?("Control channel listening on port \(tcpPort)")
        case .failed(let error):
            Log.error("TCP listener failed: \(error)")
            onEvent?("Control listener failed: \(error.localizedDescription)")
        default: break
        }
    }

    private func udpListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            udpPort = udpListener?.port?.rawValue ?? 0
            Log.info("UDP audio listener ready on port \(udpPort)")
        case .failed(let error):
            Log.error("UDP listener failed: \(error)")
            onEvent?("Audio listener failed: \(error.localizedDescription)")
        default: break
        }
    }

    // MARK: - TCP sessions

    private func acceptTCP(_ conn: NWConnection) {
        let remote = conn.endpoint
        guard NetworkUtils.isLocalNetwork(remote) else {
            Log.info("Rejected non-local connection from \(NetworkUtils.describe(remote))")
            conn.cancel()
            return
        }
        let token = UInt64.random(in: 1...UInt64.max)
        let session = Session(token: token, tcp: conn, address: NetworkUtils.describe(remote))
        sessions[token] = session
        conn.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session else { return }
            switch state {
            case .ready:
                self.receiveTCP(session)
            case .failed(let error):
                self.remove(session, reason: "connection failed (\(error.localizedDescription))")
            case .cancelled:
                self.remove(session, reason: "connection closed")
            default: break
            }
        }
        conn.start(queue: queue)
        Log.info("Incoming control connection from \(session.address)")
    }

    private func receiveTCP(_ session: Session) {
        session.tcp.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak session] data, _, isComplete, error in
            guard let self, let session else { return }
            if let data, !data.isEmpty {
                session.parser.append(data)
                do {
                    for message in try session.parser.drainMessages() { self.handle(message, from: session) }
                } catch {
                    self.remove(session, reason: "protocol error")
                    return
                }
            }
            if isComplete || error != nil {
                self.remove(session, reason: error.map { "error: \($0.localizedDescription)" } ?? "closed by receiver")
                return
            }
            self.receiveTCP(session)
        }
    }

    private func handle(_ message: ControlMessage, from session: Session) {
        session.lastActivity = Date()
        switch message {
        case .hello(let name, let code, let version):
            guard version == Wire.protocolVersion else {
                send(.rejected(reason: "Protocol version mismatch (host \(Wire.protocolVersion), receiver \(version))."), to: session)
                return
            }
            session.name = name
            session.helloReceived = true
            if let required = pairingCode, !required.isEmpty {
                if code == required {
                    accept(session)
                } else {
                    session.state = .pending
                    send(.pending(message: "Waiting for \(hostName) to allow this Mac."), to: session)
                    onEvent?("\(name) (\(session.address)) wants to connect – needs approval")
                    publish()
                }
            } else {
                session.state = .pending
                send(.pending(message: "Waiting for \(hostName) to allow this Mac."), to: session)
                onEvent?("\(name) (\(session.address)) wants to connect – needs approval")
                publish()
            }
        case .stats(let stats):
            session.stats = stats
            session.lastStatsAt = Date()
            publish()
        case .goodbye:
            remove(session, reason: "receiver left")
        default:
            break
        }
    }

    private func accept(_ session: Session) {
        session.state = .connected
        send(.welcome(sessionToken: session.token, udpPort: udpPort, hostName: hostName,
                      latencyMs: latencyMs, sampleRate: sampleRate, channels: channels), to: session)
        onEvent?("\(session.name) connected")
        publish()
    }

    private func send(_ message: ControlMessage, to session: Session) {
        guard let data = try? ControlFraming.frame(message) else { return }
        session.tcp.send(content: data, completion: .contentProcessed { _ in })
    }

    private func remove(_ session: Session, reason: String) {
        guard sessions[session.token] != nil else { return }
        sessions[session.token] = nil
        session.udp?.cancel()
        session.tcp.cancel()
        Log.info("Receiver \(session.name) removed: \(reason)")
        if session.helloReceived { onEvent?("\(session.name) disconnected (\(reason))") }
        publish()
    }

    // MARK: - UDP flows

    private func acceptUDP(_ conn: NWConnection) {
        guard NetworkUtils.isLocalNetwork(conn.endpoint) else { conn.cancel(); return }
        let key = ObjectIdentifier(conn)
        unboundUDP[key] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                self.receiveUDP(conn)
            case .failed, .cancelled:
                self.unboundUDP[ObjectIdentifier(conn)] = nil
                if let s = self.sessions.values.first(where: { $0.udp === conn }) {
                    s.udp = nil
                    if s.state == .streaming { s.state = .connected }
                    self.publish()
                }
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receiveUDP(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn else { return }
            if let data, let message = try? UDPMessage.decode(data) {
                self.handleUDP(message, from: conn)
            }
            if error == nil { self.receiveUDP(conn) }
        }
    }

    private func handleUDP(_ message: UDPMessage, from conn: NWConnection) {
        switch message {
        case .hello(let token):
            guard let session = sessions[token], session.state != .pending else {
                conn.cancel()
                return
            }
            if session.udp !== conn {
                session.udp?.cancel()
                session.udp = conn
                unboundUDP[ObjectIdentifier(conn)] = nil
                Log.info("UDP audio flow bound for \(session.name) (\(NetworkUtils.describe(conn.endpoint)))")
            }
            session.lastActivity = Date()
            if session.state != .streaming {
                session.state = .streaming
                onEvent?("\(session.name) is now receiving audio")
                publish()
            }
            conn.send(content: UDPMessage.helloAck(token: token).encode(), completion: .contentProcessed { _ in })
        case .clockPing(let t1):
            let t2 = HostClock.nowNanos
            if let s = sessions.values.first(where: { $0.udp === conn }) { s.lastActivity = Date() }
            let reply = UDPMessage.clockPong(t1: t1, t2: t2, t3: HostClock.nowNanos).encode()
            conn.send(content: reply, completion: .contentProcessed { _ in })
        case .keepalive:
            if let s = sessions.values.first(where: { $0.udp === conn }) { s.lastActivity = Date() }
        default:
            break
        }
    }

    // MARK: - Housekeeping

    private func housekeep() {
        let now = Date()
        for s in Array(sessions.values) {
            if s.state == .streaming, now.timeIntervalSince(s.lastActivity) > 10 {
                remove(s, reason: "timed out")
            } else if !s.helloReceived, now.timeIntervalSince(s.connectedAt) > 10 {
                remove(s, reason: "no hello")
            }
        }
    }

    private func infos() -> [ReceiverInfo] {
        sessions.values
            .filter { $0.helloReceived }
            .sorted { $0.connectedAt < $1.connectedAt }
            .map { ReceiverInfo(id: $0.id, name: $0.name, address: $0.address, state: $0.state, stats: $0.stats,
                                volume: $0.volume, connectedAt: $0.connectedAt, lastStatsAt: $0.lastStatsAt) }
    }

    private func publish() {
        onReceiversChanged?(infos())
    }
}
