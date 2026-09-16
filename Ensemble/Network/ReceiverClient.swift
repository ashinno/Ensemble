import Foundation
import Network

/// Receiver side of the protocol: connects to a host over TCP, opens the UDP audio flow,
/// keeps the clock synchronized and feeds packets into an `AudioPlaybackManager`.
final class ReceiverClient {
    enum State: Equatable {
        case idle
        case connecting
        case waitingForApproval
        case connected
        case streaming
        case failed(String)
        case rejected(String)
        case disconnected(String)

        var label: String {
            switch self {
            case .idle: return "Not connected"
            case .connecting: return "Connecting…"
            case .waitingForApproval: return "Waiting for host approval…"
            case .connected: return "Connected, opening audio channel…"
            case .streaming: return "Receiving audio"
            case .failed(let why): return "Failed: \(why)"
            case .rejected(let why): return "Rejected: \(why)"
            case .disconnected(let why): return "Disconnected: \(why)"
            }
        }

        var isActive: Bool {
            switch self {
            case .idle, .failed, .rejected, .disconnected: return false
            default: return true
            }
        }
    }

    struct Snapshot {
        var state: State = .idle
        var hostName = ""
        var hostAddress = ""
        var rttMs: Double = 0
        var clockOffsetMs: Double = 0
        var jitterMs: Double = 0
        var clockSynced = false
        var pingsSent = 0
        var pongsReceived = 0
        var latencyMs: Double = 150
        var player: AudioPlaybackManager.Stats?
        var levels: [Float] = []
        var connectedAt: Date?
        var transitP95Ms: Double = 0
        var requiredDelayMs: Double = 0
        var clockDriftMs: Double = 0
    }

    var receiverName: String
    var pairingCode: String = ""
    var volume: Float = 1 {
        didSet { queue.async { self.player?.volume = self.volume } }
    }
    /// Manual fine adjustment in ms (positive = play later).
    var trimMs: Double = 0 {
        didSet { queue.async { self.player?.trimNs = self.trimMs * 1e6 } }
    }

    var onStateChange: ((State) -> Void)?
    var onEvent: ((String) -> Void)?

    let clockSync = ClockSyncManager()
    let levels = LevelHistory()
    private(set) var player: AudioPlaybackManager?
    private var peakSinceReport: Float = 0
    private var transits: [Double] = []   // ms, host timeline, last ~3 s
    private var transitStats: (p95: Double, required: Double) = (0, 0)
    private var connectedAt: Date?

    private let queue = DispatchQueue(label: "ensemble.receiver.client", qos: .userInteractive)
    private let activity = ActivityGuard(reason: "Receiving synchronized audio")
    private var tcp: NWConnection?
    private var udp: NWConnection?
    private var parser = ControlFrameParser()
    private var token: UInt64?
    private var state: State = .idle
    private var hostName = ""
    private var hostAddress = ""
    private var latencyMs: Double = 150
    private var udpReady = false
    private var helloTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var helloAttempts = 0

    init(receiverName: String) {
        self.receiverName = receiverName
    }

    // MARK: - Public

    func connect(to endpoint: NWEndpoint) {
        queue.async { [self] in
            teardown(notifyState: false)
            setState(.connecting)
            hostAddress = NetworkUtils.describe(endpoint)
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let conn = NWConnection(to: endpoint, using: params)
            tcp = conn
            conn.stateUpdateHandler = { [weak self, weak conn] st in
                guard let self, let conn, conn === self.tcp else { return }
                switch st {
                case .ready:
                    if let host = NetworkUtils.remoteHost(of: conn) {
                        self.hostAddress = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                    }
                    self.sendControl(.hello(name: self.receiverName,
                                            pairingCode: self.pairingCode.isEmpty ? nil : self.pairingCode,
                                            protocolVersion: Wire.protocolVersion))
                    self.receiveTCP(conn)
                case .waiting(let error):
                    self.onEvent?("Waiting for network: \(error.localizedDescription)")
                case .failed(let error):
                    self.teardown(notifyState: false)
                    self.setState(.failed(error.localizedDescription))
                case .cancelled:
                    break
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    func disconnect() {
        queue.async { [self] in
            if let tcp, state.isActive {
                tcp.send(content: try? ControlFraming.frame(.goodbye), completion: .contentProcessed { _ in })
            }
            teardown(notifyState: false)
            setState(.idle)
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(state: state, hostName: hostName, hostAddress: hostAddress,
                     rttMs: clockSync.rttNs / 1e6, clockOffsetMs: clockSync.offsetNs / 1e6,
                     jitterMs: clockSync.jitterNs / 1e6, clockSynced: clockSync.isSynced,
                     pingsSent: clockSync.pingsSent, pongsReceived: clockSync.pongsReceived,
                     latencyMs: latencyMs, player: player?.snapshot(), levels: levels.snapshot(), connectedAt: connectedAt,
                     transitP95Ms: transitStats.p95, requiredDelayMs: transitStats.required,
                     clockDriftMs: (clockSync.offsetNs - (clockSync.initialOffsetNs ?? clockSync.offsetNs)) / 1e6)
        }
    }

    func currentStats() -> ReceiverStats {
        updateTransitStats()
        let p = player?.snapshot()
        var st = ReceiverStats()
        st.rttMs = clockSync.rttNs / 1e6
        st.clockOffsetMs = clockSync.offsetNs / 1e6
        st.jitterMs = clockSync.jitterNs / 1e6
        st.bufferMs = p?.bufferMs ?? 0
        st.latencyMs = latencyMs
        st.driftMs = p?.driftErrorMs ?? 0
        st.rateCorrectionPPM = p?.rateCorrectionPPM ?? 0
        st.underruns = p?.underruns ?? 0
        st.resyncs = p?.resyncs ?? 0
        st.packetsReceived = p?.packetsReceived ?? 0
        st.packetsLost = p?.packetsLost ?? 0
        st.volume = volume
        st.outputLatencyMs = p?.outputLatencyMs ?? 0
        st.clockSynced = clockSync.isSynced
        st.level = peakSinceReport
        st.transitP95Ms = transitStats.p95
        st.requiredDelayMs = transitStats.required
        return st
    }

    /// p99 of the last ~10 s of transit latency plus the output device latency and a safety margin.
    private func updateTransitStats() {
        guard transits.count >= 100 else { transitStats = (0, 0); return }
        let sorted = transits.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let outputLatency = player?.snapshot().outputLatencyMs ?? 0
        transitStats = (p95, max(0, p95 + outputLatency + 15))
    }

    // MARK: - TCP

    private func receiveTCP(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.tcp else { return }
            if let data, !data.isEmpty {
                self.parser.append(data)
                if let messages = try? self.parser.drainMessages() {
                    messages.forEach { self.handle($0) }
                }
            }
            if isComplete || error != nil {
                let wasActive = self.state.isActive
                self.teardown(notifyState: false)
                if wasActive { self.setState(.disconnected("host closed the connection")) }
                return
            }
            self.receiveTCP(conn)
        }
    }

    private func sendControl(_ message: ControlMessage) {
        guard let tcp, let data = try? ControlFraming.frame(message) else { return }
        tcp.send(content: data, completion: .contentProcessed { _ in })
    }

    private func handle(_ message: ControlMessage) {
        switch message {
        case .welcome(let token, let udpPort, let name, let latency, let sampleRate, _):
            self.token = token
            hostName = name
            latencyMs = latency
            onEvent?("Accepted by \(name) (audio port \(udpPort), \(Int(sampleRate)) Hz, \(Int(latency)) ms)")
            setState(.connected)
            startPlayer(sampleRate: sampleRate)
            openUDP(port: udpPort, token: token)
        case .pending(let text):
            onEvent?(text)
            setState(.waitingForApproval)
        case .rejected(let reason):
            teardown(notifyState: false)
            setState(.rejected(reason))
        case .setLatency(let ms):
            latencyMs = ms
            player?.targetLatencyNs = ms * 1e6
            onEvent?("Host set playback delay to \(Int(ms)) ms")
        case .setVolume(let v):
            volume = v
            onEvent?("Host set volume to \(Int(v * 100))%")
        case .syncTest(let hostTimeNs):
            player?.scheduleClick(atRemoteTimeNs: hostTimeNs)
            onEvent?("Sync test click scheduled")
        case .goodbye:
            teardown(notifyState: false)
            setState(.disconnected("host ended the session"))
        default:
            break
        }
    }

    // MARK: - Player

    private func startPlayer(sampleRate: Double) {
        if let p = player, p.sampleRate != sampleRate { p.stop(); player = nil }
        if player == nil {
            player = AudioPlaybackManager(sampleRate: sampleRate)
        }
        guard let player else { return }
        player.resetTimeline()
        player.volume = volume
        player.trimNs = trimMs * 1e6
        player.targetLatencyNs = latencyMs * 1e6
        player.clockOffsetNs = 0
        do { try player.start() } catch {
            onEvent?("Audio output failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UDP

    private func openUDP(port: UInt16, token: UInt64) {
        guard let tcp, let host = NetworkUtils.remoteHost(of: tcp), let nwPort = NWEndpoint.Port(rawValue: port) else {
            setState(.failed("Could not determine host address for audio"))
            return
        }
        udp?.cancel()
        udpReady = false
        let params = NWParameters.udp
        let conn = NWConnection(host: host, port: nwPort, using: params)
        udp = conn
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            guard let self, let conn, conn === self.udp else { return }
            switch st {
            case .ready:
                self.receiveUDP(conn)
                self.startHelloTimer(token: token)
            case .failed(let error):
                self.onEvent?("Audio channel failed: \(error.localizedDescription)")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func startHelloTimer(token: UInt64) {
        helloTimer?.cancel()
        helloAttempts = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1000))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.helloAttempts += 1
            if !self.udpReady && self.helloAttempts > 15 {
                self.helloTimer?.cancel()
                self.setState(.failed("No answer on the audio channel (UDP blocked by a firewall?)"))
                return
            }
            // Doubles as keepalive once the flow is bound.
            self.udp?.send(content: UDPMessage.hello(token: token).encode(), completion: .contentProcessed { _ in })
        }
        helloTimer = t
        t.resume()
    }

    private func receiveUDP(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn, conn === self.udp else { return }
            if let data, let message = try? UDPMessage.decode(data) {
                self.handleUDP(message)
            }
            if error == nil { self.receiveUDP(conn) }
        }
    }

    private func handleUDP(_ message: UDPMessage) {
        switch message {
        case .audio(let packet):
            if let p = player, p.sampleRate != Double(packet.sampleRate) {
                onEvent?("Stream sample rate changed to \(packet.sampleRate) Hz")
                startPlayer(sampleRate: Double(packet.sampleRate))
            }
            player?.enqueue(packet)
            if clockSync.isSynced {
                let transit = (Double(HostClock.nowNanos) - clockSync.offsetNs - Double(packet.timestampNs)) / 1e6
                transits.append(transit)
                if transits.count > 2000 { transits.removeFirst(transits.count - 2000) }   // ≈ 10 s of 5 ms packets
            }
            let peak = LevelHistory.peak(of: packet)
            levels.push(peak)
            if peak > peakSinceReport { peakSinceReport = peak }
        case .helloAck:
            if !udpReady {
                udpReady = true
                connectedAt = Date()
                activity.begin()
                setState(.streaming)
                onEvent?("Audio channel open")
                clockSync.sendPing = { [weak self] t1 in
                    self?.udp?.send(content: UDPMessage.clockPing(t1: t1).encode(), completion: .contentProcessed { _ in })
                }
                clockSync.start(on: queue)
                startStatsTimer()
            }
        case .clockPong(let t1, let t2, let t3):
            clockSync.handlePong(t1: t1, t2: t2, t3: t3)
            player?.clockOffsetNs = clockSync.offsetNs
        default:
            break
        }
    }

    private func startStatsTimer() {
        statsTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.state == .streaming else { return }
            let stats = self.currentStats()
            self.peakSinceReport = 0
            self.sendControl(.stats(stats))
            Log.debug(String(format: "stats rtt=%.2fms offset=%.3fms jitter=%.2fms buffer=%.0fms drift=%.2fms rate=%.0fppm recv=%d lost=%d underruns=%d resyncs=%d synced=%d transitP95=%.1fms need=%.0fms delay=%.0fms",
                             stats.rttMs, stats.clockOffsetMs, stats.jitterMs, stats.bufferMs, stats.driftMs, stats.rateCorrectionPPM,
                             stats.packetsReceived, stats.packetsLost, stats.underruns, stats.resyncs, stats.clockSynced ? 1 : 0,
                             stats.transitP95Ms, stats.requiredDelayMs, stats.latencyMs))
        }
        statsTimer = t
        t.resume()
    }

    // MARK: - Teardown

    private func teardown(notifyState: Bool) {
        helloTimer?.cancel(); helloTimer = nil
        statsTimer?.cancel(); statsTimer = nil
        clockSync.stop()
        udp?.cancel(); udp = nil
        tcp?.cancel(); tcp = nil
        parser = ControlFrameParser()
        token = nil
        udpReady = false
        player?.stop()
        activity.end()
        levels.reset()
        transits.removeAll()
        transitStats = (0, 0)
        connectedAt = nil
        if notifyState { setState(.idle) }
    }

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }
}
