import Foundation
import Combine
import AppKit

enum SourceKind: String, CaseIterable, Identifiable {
    case systemAudio, testTone
    var id: String { rawValue }
    var label: String { self == .systemAudio ? "System audio" : "Test tone" }
}

/// How the host's own speakers behave while broadcasting.
enum LocalPlaybackMode: String, CaseIterable, Identifiable {
    case synchronized, direct, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .synchronized: return "Synchronized"
        case .direct: return "Direct (no delay)"
        case .off: return "Off"
        }
    }
    var help: String {
        switch self {
        case .synchronized: return "System audio is muted at the source and replayed through this Mac's speakers with the same delay as the receivers, so every Mac plays in sync."
        case .direct: return "This Mac plays audio immediately; receivers lag behind by the playback delay. Use for video when you don't mind the other Macs trailing."
        case .off: return "This Mac stays silent; only the receivers play."
        }
    }
    var mutesSystemOutput: Bool { self != .direct }
}

@MainActor
final class HostController: ObservableObject {
    @Published private(set) var isBroadcasting = false
    @Published private(set) var sourceStatus = AudioSourceStatus()
    @Published private(set) var receivers: [HostStreamServer.ReceiverInfo] = []
    @Published private(set) var localPlayerStats = AudioPlaybackManager.Stats()
    @Published private(set) var eventLog: [String] = []
    @Published var lastError: String?
    @Published private(set) var tcpPort: UInt16 = 0
    @Published private(set) var udpPort: UInt16 = 0
    @Published private(set) var levelSamples: [Float] = []
    @Published private(set) var receiverLevels: [UUID: [Float]] = [:]
    @Published private(set) var broadcastStart: Date?
    @Published var showDiagnostics = false

    let levels = LevelHistory()
    private let activity = ActivityGuard(reason: "Broadcasting synchronized audio")
    private var lastReceiverPackets: [UUID: Int] = [:]

    @Published var sourceKind: SourceKind = .systemAudio
    @Published var localPlayback: LocalPlaybackMode = .synchronized {
        didSet { applyLocalPlaybackMode(previous: oldValue) }
    }
    @Published var localVolume: Float = 1 {
        didSet { localPlayer?.volume = localVolume }
    }
    @Published var latencyMode: LatencyMode = .auto { didSet { applyLatency() } }
    @Published private(set) var autoDelayMs: Double = 100
    private var autoLastChange = Date.distantPast
    private var autoLowerSince: Date?
    private var autoFreezeUntil = Date.distantPast
    private var localTransits: [Double] = []
    private let transitLock = NSLock()
    @Published var customLatencyMs: Double = 150 { didSet { if latencyMode == .custom { applyLatency() } } }
    @Published var requirePairingCode = true { didSet { server.pairingCode = requirePairingCode ? pairingCode : nil } }
    @Published private(set) var pairingCode: String = HostController.makeCode()

    let hostName: String
    private let server: HostStreamServer
    private var source: AudioSource?
    private var localPlayer: AudioPlaybackManager?
    private var statsTimer: Timer?
    private let requestedTCPPort: UInt16
    private let requestedUDPPort: UInt16

    var effectiveLatencyMs: Double {
        switch latencyMode {
        case .auto: return autoDelayMs
        case .custom: return customLatencyMs
        default: return latencyMode.presetMs ?? 150
        }
    }

    /// Delay the slowest connected Mac currently needs (nil until receivers report).
    var requiredDelayMs: Double? {
        let needs = receivers.compactMap { $0.state == .streaming ? $0.stats?.requiredDelayMs : nil }.filter { $0 > 0 }
        return needs.max()
    }

    init() {
        let defaults = UserDefaults.standard
        hostName = defaults.string(forKey: "name") ?? Host.current().localizedName ?? "Mac"
        requestedTCPPort = UInt16(defaults.integer(forKey: "tcpPort"))
        requestedUDPPort = UInt16(defaults.integer(forKey: "udpPort"))
        if let code = defaults.string(forKey: "pairing"), !code.isEmpty { pairingCode = code }
        if defaults.string(forKey: "source") == "tone" { sourceKind = .testTone }
        if let lp = defaults.string(forKey: "localPlayback"), let mode = LocalPlaybackMode(rawValue: lp) { localPlayback = mode }
        server = HostStreamServer(hostName: hostName)
        server.pairingCode = pairingCode
        server.latencyMs = effectiveLatencyMs
        server.onReceiversChanged = { [weak self] list in
            DispatchQueue.main.async { self?.receivers = list }
        }
        server.onEvent = { [weak self] text in
            DispatchQueue.main.async { self?.log(text) }
        }
    }

    // MARK: - Broadcasting

    func startBroadcasting() {
        guard !isBroadcasting else { return }
        lastError = nil
        let source: AudioSource
        switch sourceKind {
        case .systemAudio: source = AudioCaptureManager(muteSystemOutput: localPlayback.mutesSystemOutput)
        case .testTone: source = TestToneSource()
        }
        source.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.sourceStatus = status }
        }
        do {
            try source.start()
        } catch {
            lastError = error.localizedDescription
            log("Capture failed: \(error.localizedDescription)")
            return
        }
        self.source = source

        let player = AudioPlaybackManager(sampleRate: source.sampleRate)
        player.clockOffsetNs = 0
        player.targetLatencyNs = effectiveLatencyMs * 1e6
        player.volume = localVolume
        player.streamEnabled = localPlayback == .synchronized
        do { try player.start() } catch { log("Local playback failed: \(error.localizedDescription)") }
        localPlayer = player

        source.onPacket = { [weak self] packet in
            guard let self else { return }
            self.server.broadcast(packet)
            self.levels.push(LevelHistory.peak(of: packet))
            let transit = Double(HostClock.nowNanos - packet.timestampNs) / 1e6
            self.transitLock.lock()
            self.localTransits.append(transit)
            if self.localTransits.count > 2000 { self.localTransits.removeFirst(self.localTransits.count - 2000) }
            self.transitLock.unlock()
            if let p = self.localPlayer, p.sampleRate != Double(packet.sampleRate) {
                DispatchQueue.main.async { self.rebuildLocalPlayer(sampleRate: Double(packet.sampleRate)) }
                return
            }
            self.localPlayer?.enqueue(packet)
        }

        server.sampleRate = source.sampleRate
        server.channels = 2
        server.latencyMs = effectiveLatencyMs
        do {
            try server.start(tcpPort: requestedTCPPort, udpPort: requestedUDPPort)
        } catch {
            lastError = "Could not start network listeners: \(error.localizedDescription)"
            source.stop(); self.source = nil
            player.stop(); localPlayer = nil
            return
        }
        isBroadcasting = true
        transitLock.lock(); localTransits.removeAll(); transitLock.unlock()
        autoFreezeUntil = Date() + 3
        activity.begin()
        broadcastStart = Date()
        levels.reset()
        log("Broadcasting started as “\(hostName)”")
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        refreshStats()
    }

    func stopBroadcasting() {
        guard isBroadcasting else { return }
        statsTimer?.invalidate(); statsTimer = nil
        server.stop()
        source?.stop(); source = nil
        localPlayer?.stop(); localPlayer = nil
        isBroadcasting = false
        activity.end()
        broadcastStart = nil
        levelSamples = []
        receiverLevels = [:]
        lastReceiverPackets = [:]
        sourceStatus = AudioSourceStatus()
        localPlayerStats = AudioPlaybackManager.Stats()
        tcpPort = 0; udpPort = 0
        log("Broadcasting stopped")
    }

    func shutdown() {
        stopBroadcasting()
    }

    // MARK: - Receiver actions

    func approve(_ id: UUID) { server.approve(id) }
    func deny(_ id: UUID) { server.deny(id) }
    func disconnect(_ id: UUID) { server.disconnect(id) }
    func setVolume(_ volume: Float, for id: UUID) {
        server.setVolume(volume, for: id)
        if let i = receivers.firstIndex(where: { $0.id == id }) { receivers[i].volume = volume }
    }

    func regeneratePairingCode() {
        pairingCode = Self.makeCode()
        server.pairingCode = requirePairingCode ? pairingCode : nil
    }

    // MARK: - Sync test

    /// Every Mac (including this one) plays a click at the same host-clock instant.
    /// Tests clock synchronization and output-latency compensation.
    func playClockClick() {
        let at = HostClock.nowNanos + 1_000_000_000
        server.sendSyncTest(hostTimeNs: at)
        localPlayer?.scheduleClick(atRemoteTimeNs: at)
        log("Clock click scheduled in 1 s on all Macs")
    }

    /// A click is mixed into the audio stream itself and travels the full capture →
    /// network → jitter-buffer path. Tests end-to-end stream alignment.
    func playStreamClick() {
        source?.injectClick()
        log("Stream click injected into the broadcast")
    }

    // MARK: - Private

    private func rebuildLocalPlayer(sampleRate: Double) {
        guard isBroadcasting, localPlayer?.sampleRate != sampleRate else { return }
        localPlayer?.stop()
        let player = AudioPlaybackManager(sampleRate: sampleRate)
        player.targetLatencyNs = effectiveLatencyMs * 1e6
        player.volume = localVolume
        player.streamEnabled = localPlayback == .synchronized
        do { try player.start() } catch { log("Local playback failed: \(error.localizedDescription)") }
        localPlayer = player
        server.sampleRate = sampleRate
        log("Capture sample rate is now \(Int(sampleRate)) Hz")
    }

    /// Auto mode: follow the slowest receiver's measured need. Raises quickly (underruns are
    /// audible), lowers slowly (only after 20 s of clear headroom), in 10 ms steps.
    private func autoDelayTick() {
        let floorMs = 40.0
        let now = Date()
        guard now >= autoFreezeUntil else { return }
        transitLock.lock()
        let sorted = localTransits.sorted()
        transitLock.unlock()
        var localNeed = floorMs
        if sorted.count >= 100, localPlayback == .synchronized {
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            localNeed = p95 + localPlayerStats.outputLatencyMs + 15
        }
        let need = max(localNeed, requiredDelayMs ?? floorMs)
        let target = (max(floorMs, min(1000, need)) / 10).rounded(.up) * 10
        if target != autoDelayMs, Log.verbose {
            Log.debug(String(format: "auto: target %.0f (local need %.1f, receivers need %.1f, current %.0f)", target, localNeed, requiredDelayMs ?? 0, autoDelayMs))
        }
        if target > autoDelayMs + 5 {
            if now.timeIntervalSince(autoLastChange) > 2 {
                autoDelayMs = target
                autoLastChange = now
                autoLowerSince = nil
                autoFreezeUntil = now + 3   // players jump immediately; wait for stats to settle
                applyLatency()
            }
        } else if target < autoDelayMs - 20 {
            if autoLowerSince == nil { autoLowerSince = now }
            if now.timeIntervalSince(autoLowerSince!) > 10 {
                autoDelayMs = max(target, autoDelayMs - 20)
                autoLastChange = now
                autoLowerSince = now
                autoFreezeUntil = now + 3
                applyLatency()
            }
        } else {
            autoLowerSince = nil
        }
    }

    private func applyLatency() {
        let ms = effectiveLatencyMs
        server.setLatency(ms: ms)
        localPlayer?.targetLatencyNs = ms * 1e6
        if isBroadcasting { log("Playback delay set to \(Int(ms)) ms") }
    }

    private func applyLocalPlaybackMode(previous: LocalPlaybackMode) {
        localPlayer?.streamEnabled = localPlayback == .synchronized
        guard isBroadcasting, let capture = source as? AudioCaptureManager,
              previous.mutesSystemOutput != localPlayback.mutesSystemOutput else { return }
        capture.muteSystemOutput = localPlayback.mutesSystemOutput
        do {
            try capture.start()
            log("Local playback mode: \(localPlayback.label)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var statsTicks = 0
    private func refreshStats() {
        if let p = localPlayer { localPlayerStats = p.snapshot() }
        levelSamples = levels.snapshot()
        if latencyMode == .auto { autoDelayTick() }
        for r in receivers {
            guard let s = r.stats else { continue }
            if lastReceiverPackets[r.id] != s.packetsReceived {
                lastReceiverPackets[r.id] = s.packetsReceived
                var h = receiverLevels[r.id] ?? []
                h.append(s.level)
                if h.count > 40 { h.removeFirst(h.count - 40) }
                receiverLevels[r.id] = h
            }
        }
        statsTicks += 1
        if statsTicks % 10 == 0, Log.verbose {
            let s = localPlayerStats
            Log.debug(String(format: "local player buffer=%.0fms drift=%.2fms rate=%.0fppm underruns=%d resyncs=%d packets=%d level=%.3f",
                             s.bufferMs, s.driftErrorMs, s.rateCorrectionPPM, s.underruns, s.resyncs, s.packetsReceived, sourceStatus.peakLevel))
        }
        tcpPort = server.tcpPort
        udpPort = server.udpPort
        receivers = server.snapshot()
    }

    private func log(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        eventLog.append("\(f.string(from: Date()))  \(text)")
        if eventLog.count > 200 { eventLog.removeFirst(eventLog.count - 200) }
        Log.info(text)
    }

    private static func makeCode() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }
}
