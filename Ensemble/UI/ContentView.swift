import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("accentHex") private var accentHex = "FF4D1F"

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                switch appState.mode {
                case .host: HostView(controller: appState.host)
                case .receiver: ReceiverView(controller: appState.receiver)
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .environment(\.accent, Color(hex: accentHex))
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Text("Ensemble").font(Theme.sans(12, weight: .semibold)).foregroundStyle(Theme.text)
                .padding(.leading, 70) // room for the window's traffic lights
            Spacer()
            HStack(spacing: 6) {
                ForEach(Theme.accentPresets) { p in
                    Button { accentHex = p.id } label: {
                        Circle().fill(p.color).frame(width: 9, height: 9)
                            .overlay { Circle().strokeBorder(Theme.text.opacity(accentHex == p.id ? 0.9 : 0), lineWidth: 1.5).padding(-2) }
                    }
                    .buttonStyle(.plain).help(p.name)
                }
            }
            .padding(.trailing, 6)
            HStack(spacing: 2) {
                ForEach(AppMode.allCases) { m in
                    Button { appState.mode = m } label: {
                        Text(m.label).font(Theme.sans(11))
                            .foregroundStyle(appState.mode == m ? Theme.text : Theme.dim)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(appState.mode == m ? Theme.cardRaised : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border) }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: - Shared diagnostics widgets

struct StatRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.text).monospacedDigit()
        }
        .font(Theme.sans(12))
    }
}

struct StatsGrid: View {
    let rows: [(String, String)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                StatRow(label: row.0, value: row.1)
            }
        }
    }
}

struct EventLogView: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line).font(Theme.mono(11)).foregroundStyle(Theme.title).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 160)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

/// Sheet with the full statistics and event log.
struct DiagnosticsSheet: View {
    let title: String
    let rows: [(String, String)]
    let log: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(Theme.sans(13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                ModButton(title: "Close", compact: true) { dismiss() }
            }
            StatsGrid(rows: rows)
            Text("Events").font(Theme.sans(10)).foregroundStyle(Theme.label)
            EventLogView(lines: log)
        }
        .padding(18)
        .frame(width: 560)
        .background(Theme.card)
        .preferredColorScheme(.dark)
    }
}

func openPrivacySettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
    }
}
