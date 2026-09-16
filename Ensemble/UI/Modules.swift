import SwiftUI

/// One tile of the module grid: title, an optional LED, a flexible visual area
/// and a row of label/value pairs.
struct ModuleCard<Viz: View, Params: View>: View {
    let title: String
    var led: Color? = nil
    var dashed = false
    @ViewBuilder var viz: () -> Viz
    @ViewBuilder var params: () -> Params

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Theme.sans(12, weight: .medium)).foregroundStyle(Theme.title)
                Spacer()
                if let led {
                    Circle().fill(led).frame(width: 6, height: 6)
                        .shadow(color: led.opacity(0.6), radius: 3)
                }
            }
            viz()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            params()
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity)
        .frame(height: Theme.cardHeight)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(dashed ? Theme.borderStrong : Theme.border,
                              style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
        }
    }
}

/// Label over value, the design's parameter readout.
struct Param: View {
    let label: String
    let value: String
    var accent = false
    @Environment(\.accent) private var accentColor

    var body: some View {
        VStack(spacing: 3) {
            Text(label).font(Theme.sans(10)).foregroundStyle(Theme.label).lineLimit(1).fixedSize()
            Text(value).font(Theme.mono(13)).foregroundStyle(accent ? accentColor : Theme.text)
                .lineLimit(1).fixedSize().monospacedDigit()
        }
    }
}

/// Row of parameters, centred.
struct ParamRow<Content: View>: View {
    var spacing: CGFloat = 22
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: spacing) { content() }
            .frame(maxWidth: .infinity)
    }
}

/// Small pill button in the module vocabulary.
struct ModButton: View {
    let title: String
    var primary = false
    var danger = false
    var compact = false
    let action: () -> Void
    @Environment(\.accent) private var accent
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.sans(11, weight: primary ? .semibold : .regular))
                .lineLimit(1).fixedSize()
                .foregroundStyle(primary ? Theme.bg : (danger ? Color(red: 1, green: 0.42, blue: 0.36) : Theme.text))
                .padding(.horizontal, compact ? 8 : 12)
                .padding(.vertical, compact ? 3 : 6)
                .background(primary ? accent : (hover ? Theme.cardRaised : Theme.bg.opacity(0.6)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(primary ? Color.clear : Theme.borderStrong, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Segmented row of ModButtons.
struct ModSegments<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { opt in
                ModButton(title: opt.1, primary: selection == opt.0, compact: true) { selection = opt.0 }
            }
        }
    }
}

/// Thin accent slider used inside cards.
struct ModSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    @Environment(\.accent) private var accent

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.borderStrong).frame(height: 3)
                Capsule().fill(accent).frame(width: max(0, frac * w), height: 3)
                Circle().fill(Theme.text).frame(width: 10, height: 10)
                    .offset(x: max(0, min(w - 10, frac * w - 5)))
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var v = Double(max(0, min(1, g.location.x / w)))
                v = range.lowerBound + v * (range.upperBound - range.lowerBound)
                if let step { v = (v / step).rounded() * step }
                value = v
            })
        }
        .frame(height: 14)
    }
}

/// Text in the dark inset field style.
struct ModField: View {
    let placeholder: String
    @Binding var text: String
    var mono = true
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(12) : Theme.sans(12))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.borderStrong) }
    }
}

/// Lays out modules four per row, the first row holding a wide master strip.
struct ModuleGrid: View {
    let master: AnyView
    let masterSide: AnyView
    let modules: [AnyView]

    var body: some View {
        GeometryReader { geo in
            let col = (geo.size.width - 3 * Theme.gap) / 4
            ScrollView(.vertical) {
                VStack(spacing: Theme.gap) {
                    HStack(spacing: Theme.gap) {
                        master.frame(width: col * 3 + Theme.gap * 2)
                        masterSide.frame(width: col)
                    }
                    ForEach(Array(modules.chunked(4).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: Theme.gap) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, m in
                                m.frame(width: col)
                            }
                            if row.count < 4 { Spacer(minLength: 0) }
                        }
                    }
                }
            }
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

func fmtMs(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f ms", v) }
func fmtPct(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
func fmtClock(_ since: Date?) -> String {
    guard let since else { return "00:00:00" }
    let s = Int(Date().timeIntervalSince(since))
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
