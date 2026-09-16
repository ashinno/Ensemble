import SwiftUI

/// Symmetric waveform drawn from peak levels (oldest → newest), optional playhead.
struct WaveformView: View {
    let samples: [Float]
    var playhead: CGFloat? = nil
    var stroke: Color = Theme.stroke
    @Environment(\.accent) private var accent

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            var path = Path()
            let n = max(2, samples.count)
            if samples.isEmpty {
                path.move(to: CGPoint(x: 0, y: mid)); path.addLine(to: CGPoint(x: size.width, y: mid))
            } else {
                for (i, s) in samples.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(n - 1)
                    let a = CGFloat(min(1, s)) * mid * 0.92
                    let y = i % 2 == 0 ? mid - a : mid + a
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            ctx.stroke(path, with: .color(stroke), lineWidth: 1)
            if let playhead {
                let x = playhead * size.width
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(accent), lineWidth: 1.5)
            }
        }
    }
}

/// Vertical level bars.
struct LevelBarsView: View {
    let values: [Float]
    var count = 12
    var body: some View {
        Canvas { ctx, size in
            let vals = values.suffix(count)
            let n = max(1, count)
            let gap = size.width / CGFloat(n)
            for (i, v) in vals.enumerated() {
                let x = gap * CGFloat(i) + gap / 2
                let h = max(1, CGFloat(min(1, v)) * size.height)
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height)); $0.addLine(to: CGPoint(x: x, y: size.height - h)) },
                           with: .color(Theme.stroke), lineWidth: 1.5)
            }
        }
    }
}

/// Concentric rings with a dot showing clock lock quality (offset error moves the dot).
struct RingsView: View {
    var dotOffset: CGSize = .zero   // -1…1 in each axis
    @Environment(\.accent) private var accent
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 1...5 {
                let r = s / 2 * CGFloat(i) / 5 * 0.92
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(Theme.strokeDim), lineWidth: 1)
            }
            let d = CGPoint(x: c.x + dotOffset.width * s * 0.4, y: c.y + dotOffset.height * s * 0.4)
            ctx.fill(Path(ellipseIn: CGRect(x: d.x - 3, y: d.y - 3, width: 6, height: 6)), with: .color(accent))
        }
    }
}

/// Spectrum-like bars with one highlighted bar (delay presets).
struct DelayBarsView: View {
    var highlight: Double = 0.33   // 0…1 position
    @Environment(\.accent) private var accent
    var body: some View {
        Canvas { ctx, size in
            let n = 30
            let gap = size.width / CGFloat(n)
            let hi = Int((highlight * Double(n - 1)).rounded())
            for i in 0..<n {
                let x = Double(i) / Double(n - 1)
                let env = 0.15 + 0.85 * exp(-pow(x - 0.4, 2) / 0.09)
                let wob = 0.7 + 0.3 * (0.5 + 0.5 * sin(Double(i) * 1.7))
                let h = CGFloat(env * wob) * size.height
                let px = gap * CGFloat(i) + gap / 2
                ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: size.height)); $0.addLine(to: CGPoint(x: px, y: size.height - h)) },
                           with: .color(i == hi ? accent : Theme.stroke), lineWidth: 1.5)
            }
        }
    }
}

/// 270° arc gauge.
struct ArcGaugeView: View {
    var fraction: Double
    @Environment(\.accent) private var accent
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = s * 0.42
            let start = Angle.degrees(135), full = Angle.degrees(135 + 270)
            var track = Path(); track.addArc(center: c, radius: r, startAngle: start, endAngle: full, clockwise: false)
            ctx.stroke(track, with: .color(Theme.strokeDim), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            let end = Angle.degrees(135 + 270 * max(0, min(1, fraction)))
            var fill = Path(); fill.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
            ctx.stroke(fill, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            let p = CGPoint(x: c.x + r * CGFloat(Foundation.cos(end.radians)), y: c.y + r * CGFloat(Foundation.sin(end.radians)))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(accent))
        }
    }
}

/// Sine curve with a marker (fine-tune trim).
struct SineView: View {
    var marker: Double = 0.5
    @Environment(\.accent) private var accent
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for i in 0...Int(size.width / 4) {
                let x = CGFloat(i) * 4
                let y = size.height / 2 + sin(Double(x) / Double(size.width) * 2 * .pi) * size.height * 0.38
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(p, with: .color(Theme.stroke), lineWidth: 1)
            let mx = CGFloat(marker) * size.width
            ctx.stroke(Path { $0.move(to: CGPoint(x: mx, y: 0)); $0.addLine(to: CGPoint(x: mx, y: size.height)) },
                       with: .color(accent), lineWidth: 1.5)
        }
    }
}

/// Click-test pulse glyph.
struct PulseView: View {
    @Environment(\.accent) private var accent
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, mid = h / 2
            var p = Path()
            p.move(to: CGPoint(x: 0, y: mid)); p.addLine(to: CGPoint(x: w * 0.42, y: mid))
            p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.1)); p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.9))
            p.addLine(to: CGPoint(x: w * 0.54, y: h * 0.25)); p.addLine(to: CGPoint(x: w * 0.58, y: mid)); p.addLine(to: CGPoint(x: w, y: mid))
            ctx.stroke(p, with: .color(Theme.stroke), lineWidth: 1)
            ctx.stroke(Path { $0.move(to: CGPoint(x: w / 2, y: 0)); $0.addLine(to: CGPoint(x: w / 2, y: h)) },
                       with: .color(accent), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }
}
