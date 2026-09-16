import SwiftUI

struct HostView: View {
    @ObservedObject var controller: HostController
    @Environment(\.accent) private var accent
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ModuleGrid(master: AnyView(masterCard), masterSide: AnyView(thisMacCard), modules: modules)
            .onReceive(clock) { now = $0 }
            .sheet(isPresented: $controller.showDiagnostics) {
                DiagnosticsSheet(title: "Host diagnostics", rows: diagnosticRows, log: controller.eventLog)
            }
    }

    // MARK: - Master strip

    private var masterCard: some View {
        let delayFrac = 1 - CGFloat(controller.effectiveLatencyMs / 3000)
        return VStack(spacing: 0) {
            HStack {
                Text(controller.hostName).font(Theme.sans(13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                Text(fmtClock(controller.broadcastStart)).font(Theme.mono(11)).foregroundStyle(Theme.dim)
            }
            WaveformView(samples: controller.levelSamples, playhead: controller.isBroadcasting ? delayFrac : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 8)
            HStack(spacing: 12) {
                Text("Source").foregroundStyle(Theme.dim)
                ModSegments(options: [(SourceKind.systemAudio, "System audio"), (SourceKind.testTone, "Test tone")],
                            selection: $controller.sourceKind)
                    .disabled(controller.isBroadcasting)
                if controller.sourceStatus.isRunning {
                    Text("\(Int(controller.sourceStatus.sampleRate / 1000)) kHz").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                }
                Spacer()
                if let err = controller.lastError {
                    Text(err).font(Theme.sans(11)).foregroundStyle(Theme.pending).lineLimit(1)
                    ModButton(title: "Privacy settings", compact: true) { openPrivacySettings("Privacy_AudioCapture") }
                }
                Text(controller.isBroadcasting ? "ON AIR" : "IDLE").font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(controller.isBroadcasting ? accent : Theme.dim)
                ModButton(title: controller.isBroadcasting ? "Stop" : "Start", primary: !controller.isBroadcasting, danger: controller.isBroadcasting) {
                    controller.isBroadcasting ? controller.stopBroadcasting() : controller.startBroadcasting()
                }
            }
            .font(Theme.sans(12))
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
        .frame(height: Theme.cardHeight)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border) }
    }

    private var thisMacCard: some View {
        ModuleCard(title: "This Mac", led: controller.localPlayback == .off ? Theme.ledIdle : accent) {
            VStack(spacing: 10) {
                LevelBarsView(values: controller.levelSamples.suffix(12).map { $0 }).frame(height: 44)
                ModSlider(value: Binding(get: { Double(controller.localVolume) }, set: { controller.localVolume = Float($0) }))
                    .disabled(controller.localPlayback != .synchronized)
                    .opacity(controller.localPlayback == .synchronized ? 1 : 0.35)
            }
            .padding(.vertical, 6)
        } params: {
            VStack(spacing: 8) {
                ModSegments(options: [(LocalPlaybackMode.synchronized, "Sync"), (.direct, "Direct"), (.off, "Off")],
                            selection: $controller.localPlayback)
                ParamRow {
                    Param(label: "Volume", value: fmtPct(controller.localVolume))
                    Param(label: "Delay", value: "\(Int(controller.effectiveLatencyMs)) ms")
                }
            }
        }
    }

    // MARK: - Modules

    private var modules: [AnyView] {
        var list: [AnyView] = [AnyView(syncCard)]
        for r in controller.receivers where r.state != .pending { list.append(AnyView(receiverCard(r))) }
        for r in controller.receivers where r.state == .pending { list.append(AnyView(pendingCard(r))) }
        if controller.receivers.isEmpty { list.append(AnyView(emptyReceiversCard)) }
        list.append(AnyView(pairingCard))
        list.append(AnyView(delayCard))
        list.append(AnyView(clickTestCard))
        list.append(AnyView(networkCard))
        return list
    }

    private var syncCard: some View {
        let s = controller.localPlayerStats
        let off = max(-1, min(1, s.driftErrorMs / 5))
        return ModuleCard(title: "Sync", led: controller.isBroadcasting ? accent : Theme.ledIdle) {
            RingsView(dotOffset: CGSize(width: off, height: 0)).frame(width: 84, height: 84)
        } params: {
            ParamRow {
                Param(label: "Drift", value: fmtMs(s.driftErrorMs, 2))
                Param(label: "Rate", value: String(format: "%+.0f ppm", s.rateCorrectionPPM))
                Param(label: "Buffer", value: fmtMs(s.bufferMs, 0))
            }
        }
    }

    private func receiverCard(_ r: HostStreamServer.ReceiverInfo) -> some View {
        let st = r.stats
        let vol = Binding<Double>(get: { Double(r.volume) }, set: { controller.setVolume(Float($0), for: r.id) })
        return ModuleCard(title: r.name, led: r.state == .streaming ? accent : Theme.ledIdle) {
            VStack(spacing: 10) {
                LevelBarsView(values: controller.receiverLevels[r.id] ?? [], count: 24).frame(height: 44)
                ModSlider(value: vol)
            }
            .padding(.vertical, 6)
        } params: {
            HStack(spacing: 12) {
                Param(label: "RTT", value: st.map { fmtMs($0.rttMs) } ?? "—")
                Param(label: "Needs", value: st.map { "\(Int($0.requiredDelayMs)) ms" } ?? "—", accent: (st?.requiredDelayMs ?? 0) > controller.effectiveLatencyMs)
                Param(label: "Loss", value: st.map { String(format: "%.1f%%", $0.lossPercent) } ?? "—")
                ModButton(title: "Drop", compact: true) { controller.disconnect(r.id) }
            }
        }
    }

    private func pendingCard(_ r: HostStreamServer.ReceiverInfo) -> some View {
        ModuleCard(title: r.name, led: Theme.pending, dashed: true) {
            VStack(spacing: 6) {
                Text("Wants to connect").font(Theme.sans(12)).foregroundStyle(Theme.text)
                Text("\(r.address) · no code entered, needs your OK").font(Theme.sans(11)).foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
            }
        } params: {
            HStack(spacing: 8) {
                ModButton(title: "Allow", primary: true) { controller.approve(r.id) }
                ModButton(title: "Deny") { controller.deny(r.id) }
            }
        }
    }

    private var emptyReceiversCard: some View {
        ModuleCard(title: "Speakers", led: Theme.ledIdle, dashed: true) {
            Text(controller.isBroadcasting ? "Waiting for receivers on this network" : "Start broadcasting to accept receivers")
                .font(Theme.sans(11)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
        } params: {
            ParamRow { Param(label: "Connected", value: "0") }
        }
    }

    private var pairingCard: some View {
        ModuleCard(title: "Pairing", led: controller.requirePairingCode ? accent : Theme.ledIdle) {
            Text(controller.pairingCode).font(Theme.mono(30)).tracking(9).foregroundStyle(Theme.text).textSelection(.enabled)
        } params: {
            HStack(spacing: 10) {
                ModButton(title: controller.requirePairingCode ? "Required" : "Optional", primary: controller.requirePairingCode, compact: true) {
                    controller.requirePairingCode.toggle()
                }
                ModButton(title: "New code", compact: true) { controller.regeneratePairingCode() }
                if controller.isBroadcasting { Param(label: "Port", value: "\(controller.tcpPort)") }
            }
        }
    }

    private var delayCard: some View {
        let frac: Double = {
            switch controller.latencyMode {
            case .low: return 0.12
            case .balanced: return 0.33
            case .maxSync: return 0.7
            case .auto: return min(1, controller.effectiveLatencyMs / 1000)
            case .custom: return min(1, controller.customLatencyMs / 1000)
            }
        }()
        return ModuleCard(title: "Delay", led: accent) {
            VStack(spacing: 8) {
                DelayBarsView(highlight: frac).frame(height: 48)
                if controller.latencyMode == .custom {
                    ModSlider(value: $controller.customLatencyMs, range: 30...1000, step: 10)
                }
            }
            .padding(.vertical, 4)
        } params: {
            VStack(spacing: 8) {
                ModSegments(options: [(LatencyMode.auto, "Auto"), (.low, "Low"), (.balanced, "Mid"), (.maxSync, "Max"), (.custom, "…")],
                            selection: $controller.latencyMode)
                Text(controller.latencyMode == .auto
                     ? "\(Int(controller.effectiveLatencyMs)) ms · slowest Mac needs \(controller.requiredDelayMs.map { "\(Int($0)) ms" } ?? "—")"
                     : "\(Int(controller.effectiveLatencyMs)) ms behind the source on every Mac")
                    .font(Theme.sans(10)).foregroundStyle(Theme.label)
            }
        }
    }

    private var clickTestCard: some View {
        ModuleCard(title: "Click test", led: Theme.ledIdle) {
            PulseView().frame(height: 48)
        } params: {
            HStack(spacing: 8) {
                ModButton(title: "Clock click") { controller.playClockClick() }
                ModButton(title: "Stream click") { controller.playStreamClick() }
            }
            .disabled(!controller.isBroadcasting)
            .opacity(controller.isBroadcasting ? 1 : 0.5)
        }
    }

    private var networkCard: some View {
        let synced = controller.receivers.filter { $0.stats?.clockSynced == true }.count
        let streaming = controller.receivers.filter { $0.state == .streaming }.count
        return ModuleCard(title: "Network", led: controller.isBroadcasting ? accent : Theme.ledIdle) {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.isBroadcasting ? "Broadcasting on TCP \(String(controller.tcpPort)) · UDP \(String(controller.udpPort))" : "Listeners stopped")
                    .font(Theme.sans(11)).foregroundStyle(Theme.dim)
                Text("Local network only").font(Theme.sans(11)).foregroundStyle(Theme.label)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } params: {
            HStack(spacing: 14) {
                Param(label: "Packets", value: controller.isBroadcasting ? "100/s" : "—")
                Param(label: "Clocks", value: streaming == 0 ? "—" : "\(synced)/\(streaming)", accent: streaming > 0 && synced == streaming)
                ModButton(title: "Diagnostics", compact: true) { controller.showDiagnostics = true }
            }
        }
    }

    private var diagnosticRows: [(String, String)] {
        let s = controller.localPlayerStats
        var rows: [(String, String)] = [
            ("Output device", s.outputDeviceName), ("Output latency", fmtMs(s.outputLatencyMs)),
            ("Buffer level", fmtMs(s.bufferMs, 0)), ("Drift error", fmtMs(s.driftErrorMs, 2)),
            ("Rate correction", String(format: "%.0f ppm", s.rateCorrectionPPM)), ("Underruns", "\(s.underruns)"),
            ("Resyncs", "\(s.resyncs)"), ("Packets", "\(s.packetsReceived)"),
            ("Control port", "\(controller.tcpPort)"), ("Audio port", "\(controller.udpPort)")
        ]
        for r in controller.receivers {
            guard let st = r.stats else { continue }
            rows.append(("\(r.name) round trip", fmtMs(st.rttMs, 2)))
            rows.append(("\(r.name) jitter", fmtMs(st.jitterMs, 2)))
            rows.append(("\(r.name) buffer", fmtMs(st.bufferMs, 0)))
            rows.append(("\(r.name) drift", fmtMs(st.driftMs, 2)))
            rows.append(("\(r.name) loss", "\(st.packetsLost) / \(st.packetsReceived + st.packetsLost)"))
            rows.append(("\(r.name) underruns", "\(st.underruns)"))
        }
        return rows
    }
}

extension Comparable {
    func clamped(_ r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
