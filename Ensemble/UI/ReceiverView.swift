import SwiftUI

struct ReceiverView: View {
    @ObservedObject var controller: ReceiverController
    @Environment(\.accent) private var accent
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var s: ReceiverClient.Snapshot { controller.snapshot }
    private var isActive: Bool { controller.state.isActive }
    private var streaming: Bool { controller.state == .streaming }

    var body: some View {
        ModuleGrid(master: AnyView(masterCard), masterSide: AnyView(volumeCard), modules: modules)
            .onReceive(clock) { now = $0 }
            .sheet(isPresented: $controller.showDiagnostics) {
                DiagnosticsSheet(title: "Receiver diagnostics", rows: diagnosticRows, log: controller.eventLog)
            }
            .sheet(isPresented: $controller.showManualConnect) { manualConnectSheet }
    }

    // MARK: - Master strip

    private var masterCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(controller.receiverName).font(Theme.sans(13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                Text(fmtClock(s.connectedAt)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
            }
            WaveformView(samples: s.levels, playhead: streaming ? 1 - CGFloat(s.latencyMs / 3000) : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 8)
            HStack(spacing: 10) {
                Text("Host").foregroundStyle(Theme.dim)
                Text(s.hostName.isEmpty ? "—" : "\(s.hostName) · \(s.hostAddress)").foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(statusWord).font(Theme.mono(11, weight: .medium)).foregroundStyle(statusColor).lineLimit(1)
                if isActive {
                    ModButton(title: "Disconnect", danger: true) { controller.disconnect() }
                }
            }
            .font(Theme.sans(12))
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
        .frame(height: Theme.cardHeight)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border) }
    }

    private var statusWord: String {
        switch controller.state {
        case .idle: return "IDLE"
        case .connecting: return "CONNECTING"
        case .waitingForApproval: return "WAITING FOR HOST"
        case .connected: return "OPENING AUDIO"
        case .streaming: return "LOCKED"
        case .failed(let why): return "FAILED · \(why)"
        case .rejected(let why): return "REJECTED · \(why)"
        case .disconnected(let why): return "DISCONNECTED · \(why)"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .streaming: return accent
        case .failed, .rejected: return Color(red: 1, green: 0.42, blue: 0.36)
        case .idle: return Theme.dim
        default: return Theme.pending
        }
    }

    private var volumeCard: some View {
        ModuleCard(title: "Volume", led: streaming ? accent : Theme.ledIdle) {
            ArcGaugeView(fraction: Double(controller.volume)).frame(width: 84, height: 84)
        } params: {
            VStack(spacing: 8) {
                ModSlider(value: Binding(get: { Double(controller.volume) }, set: { controller.volume = Float($0) }))
                ParamRow {
                    Param(label: "Level", value: fmtPct(controller.volume), accent: true)
                    Param(label: "Output", value: s.player?.outputDeviceName.isEmpty == false ? shortDevice(s.player!.outputDeviceName) : "—")
                }
            }
        }
    }

    // MARK: - Modules

    private var modules: [AnyView] {
        [AnyView(syncCard), AnyView(fineTuneCard), AnyView(delayCard), AnyView(hostsCard),
         AnyView(pairingCard), AnyView(streamCard), AnyView(clockCard), AnyView(diagnosticsCard)]
    }

    private var syncCard: some View {
        let p = s.player
        let off = max(-1, min(1, (p?.driftErrorMs ?? 0) / 5))
        return ModuleCard(title: "Sync", led: s.clockSynced ? accent : Theme.ledIdle) {
            RingsView(dotOffset: CGSize(width: off, height: 0)).frame(width: 84, height: 84)
        } params: {
            ParamRow(spacing: 14) {
                Param(label: "Headroom", value: streaming && s.transitP95Ms > 0 ? String(format: "%+.0f ms", s.latencyMs - s.requiredDelayMs + 15) : "—",
                      accent: streaming && s.transitP95Ms > 0 && s.latencyMs - s.requiredDelayMs + 15 < 8)
                Param(label: "Round trip", value: streaming ? fmtMs(s.rttMs) : "—")
                Param(label: "Buffer", value: p.map { fmtMs($0.bufferMs, 0) } ?? "—")
            }
        }
    }

    private var fineTuneCard: some View {
        ModuleCard(title: "Fine-tune", led: controller.trimMs == 0 ? Theme.ledIdle : accent) {
            VStack(spacing: 8) {
                SineView(marker: (controller.trimMs + 100) / 200).frame(height: 44)
                ModSlider(value: $controller.trimMs, range: -100...100, step: 1)
            }
            .padding(.vertical, 4)
        } params: {
            HStack(spacing: 14) {
                Param(label: "Trim", value: String(format: "%+.0f ms", controller.trimMs), accent: true)
                Param(label: "Range", value: "±100 ms")
                ModButton(title: "Reset", compact: true) { controller.trimMs = 0 }
            }
        }
    }

    private var delayCard: some View {
        ModuleCard(title: "Delay", led: streaming ? accent : Theme.ledIdle) {
            DelayBarsView(highlight: min(1, s.latencyMs / 1000)).frame(height: 48).padding(.vertical, 4)
        } params: {
            ParamRow {
                Param(label: "Set by host", value: streaming ? "\(Int(s.latencyMs)) ms" : "—")
                Param(label: "Needed here", value: streaming && s.requiredDelayMs > 0 ? "\(Int(s.requiredDelayMs)) ms" : "—", accent: streaming && s.requiredDelayMs > s.latencyMs)
            }
        }
    }

    private var hostsCard: some View {
        ModuleCard(title: "Hosts nearby", led: controller.hosts.isEmpty ? Theme.ledIdle : accent) {
            VStack(spacing: 8) {
                if controller.hosts.isEmpty {
                    Text("Looking for hosts…").font(Theme.sans(11)).foregroundStyle(Theme.dim)
                } else {
                    ForEach(controller.hosts.prefix(3)) { h in
                        let connected = isActive && s.hostName == h.name
                        HStack(spacing: 8) {
                            Circle().fill(connected ? accent : Theme.ledIdle).frame(width: 6, height: 6)
                            Text(h.name).font(Theme.sans(12)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            if connected {
                                Text("connected").font(Theme.sans(11)).foregroundStyle(Theme.dim)
                            } else {
                                ModButton(title: isActive ? "Switch" : "Connect", primary: !isActive, compact: true) {
                                    if isActive { controller.disconnect() }
                                    controller.connect(to: h)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        } params: {
            HStack(spacing: 8) {
                ModButton(title: "Connect by IP", compact: true) { controller.showManualConnect = true }
                ModButton(title: "Rescan", compact: true) { controller.refreshDiscovery() }
            }
        }
    }

    private var pairingCard: some View {
        ModuleCard(title: "Pairing", led: controller.pairingCode.isEmpty ? Theme.ledIdle : accent) {
            ModField(placeholder: "code", text: $controller.pairingCode).frame(width: 110)
                .multilineTextAlignment(.center)
        } params: {
            HStack(spacing: 10) {
                ModButton(title: controller.autoReconnect ? "Auto-reconnect on" : "Auto-reconnect off",
                          primary: controller.autoReconnect, compact: true) { controller.autoReconnect.toggle() }
            }
        }
    }

    private var streamCard: some View {
        let p = s.player
        return ModuleCard(title: "Stream", led: streaming ? accent : Theme.ledIdle) {
            LevelBarsView(values: s.levels, count: 24).frame(height: 44).padding(.vertical, 8)
        } params: {
            ParamRow(spacing: 14) {
                Param(label: "Rate", value: p != nil ? String(format: "%.1f kHz", sampleRateK) : "—")
                Param(label: "Packets", value: p.map { "\($0.packetsReceived)" } ?? "—")
                Param(label: "Lost", value: p.map { "\($0.packetsLost)" } ?? "—")
            }
        }
    }

    private var sampleRateK: Double { (controller.streamSampleRate) / 1000 }

    private var clockCard: some View {
        ModuleCard(title: "Host clock", led: s.clockSynced ? accent : Theme.ledIdle) {
            VStack(spacing: 4) {
                Text(String(format: "%+.3f ms", s.clockDriftMs)).font(Theme.mono(22)).foregroundStyle(Theme.text)
                Text("drift since lock").font(Theme.sans(10)).foregroundStyle(Theme.label)
            }
        } params: {
            ParamRow {
                Param(label: "Pings", value: "\(s.pongsReceived)/\(s.pingsSent)")
                Param(label: "Jitter", value: streaming ? fmtMs(s.jitterMs, 2) : "—")
                Param(label: "Lock", value: s.clockSynced ? "stable" : "—", accent: s.clockSynced)
            }
        }
    }

    private var diagnosticsCard: some View {
        let p = s.player
        return ModuleCard(title: "Diagnostics", led: (p?.underruns ?? 0) > 0 ? Theme.pending : Theme.ledIdle) {
            VStack(alignment: .leading, spacing: 4) {
                if streaming, s.requiredDelayMs > s.latencyMs {
                    Text("Audio arrives late for the current delay. Set the host to Auto or a longer delay.").font(Theme.sans(11)).foregroundStyle(Theme.pending).lineLimit(3)
                } else {
                    Text(controller.eventLog.last ?? "No events yet").font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } params: {
            HStack(spacing: 14) {
                Param(label: "Underruns", value: p.map { "\($0.underruns)" } ?? "—")
                Param(label: "Resyncs", value: p.map { "\($0.resyncs)" } ?? "—")
                ModButton(title: "Open", compact: true) { controller.showDiagnostics = true }
            }
        }
    }

    private var manualConnectSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect by IP address").font(Theme.sans(13, weight: .semibold)).foregroundStyle(Theme.text)
            Text("The host shows its control port under Network.").font(Theme.sans(11)).foregroundStyle(Theme.dim)
            HStack(spacing: 8) {
                ModField(placeholder: "192.168.1.10", text: $controller.manualHost)
                ModField(placeholder: "port", text: $controller.manualPort).frame(width: 80)
            }
            HStack {
                Spacer()
                ModButton(title: "Cancel") { controller.showManualConnect = false }
                ModButton(title: "Connect", primary: true) {
                    controller.showManualConnect = false
                    controller.connectManual()
                }
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(Theme.card)
        .preferredColorScheme(.dark)
    }

    private var diagnosticRows: [(String, String)] {
        let p = s.player ?? AudioPlaybackManager.Stats()
        return [
            ("Round-trip latency", fmtMs(s.rttMs, 2)), ("Network jitter", fmtMs(s.jitterMs, 2)),
            ("Clock offset", String(format: "%+.3f ms", s.clockOffsetMs)), ("Clock pings / pongs", "\(s.pingsSent) / \(s.pongsReceived)"),
            ("Buffer level", fmtMs(p.bufferMs, 0)), ("Target delay", fmtMs(p.targetLatencyMs, 0)),
            ("Playback drift", fmtMs(p.driftErrorMs, 2)), ("Rate correction", String(format: "%.0f ppm", p.rateCorrectionPPM)),
            ("Output device", p.outputDeviceName), ("Output latency", fmtMs(p.outputLatencyMs, 2)),
            ("Packets received", "\(p.packetsReceived)"), ("Packets lost", "\(p.packetsLost)"),
            ("Underruns", "\(p.underruns)"), ("Resyncs", "\(p.resyncs)"),
            ("Engine", p.isRunning ? "running" : "stopped"), ("Fine-tune", String(format: "%+.0f ms", controller.trimMs))
        ]
    }

    private func shortDevice(_ name: String) -> String {
        name.count > 12 ? String(name.prefix(11)) + "…" : name
    }
}
