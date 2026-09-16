import Foundation

/// User-selectable playback delay. Larger delays tolerate more network jitter and give
/// receivers more time to align; smaller delays reduce the lag behind the source.
enum LatencyMode: String, CaseIterable, Identifiable, Codable {
    case auto, low, balanced, maxSync, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .low: return "Low latency"
        case .balanced: return "Balanced"
        case .maxSync: return "Maximum synchronization"
        case .custom: return "Custom"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Smallest delay every connected Mac can sustain, measured continuously."
        case .low: return "≈60 ms. Best for video; may drop out on busy Wi‑Fi."
        case .balanced: return "≈150 ms. Good default for music on Wi‑Fi."
        case .maxSync: return "≈400 ms. Largest jitter buffer, most robust alignment."
        case .custom: return "Choose your own playback delay."
        }
    }

    /// Target playback delay in milliseconds (nil for custom).
    var presetMs: Double? {
        switch self {
        case .low: return 60
        case .balanced: return 150
        case .maxSync: return 400
        case .auto, .custom: return nil
        }
    }
}

/// Maps stream timeline positions (frame indices) to host-clock timestamps.
///
/// Each packet carries the host capture time of its first frame. The mapping is smoothed
/// so that timestamp jitter does not translate into playback jitter, but it hard-resets
/// when the host re-anchors (device restart, capture restart).
struct TimelineMapping {
    let sampleRate: Double
    private(set) var isSet = false
    /// Host timestamp (ns) corresponding to frame position 0, smoothed.
    private(set) var anchorNs: Double = 0
    var resetThresholdNs: Double = 20e6
    var smoothing: Double = 0.02

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// Feed a (timestamp, position) observation. Returns true if the mapping was hard reset.
    @discardableResult
    mutating func update(timestampNs: Int64, position: Int64) -> Bool {
        let t0 = Double(timestampNs) - Double(position) * 1e9 / sampleRate
        if !isSet {
            anchorNs = t0
            isSet = true
            return true
        }
        let diff = t0 - anchorNs
        if abs(diff) > resetThresholdNs {
            anchorNs = t0
            return true
        }
        anchorNs += diff * smoothing
        return false
    }

    mutating func reset() { isSet = false; anchorNs = 0 }

    func position(forTimestampNs ts: Double) -> Double {
        (ts - anchorNs) * sampleRate / 1e9
    }

    func timestampNs(forPosition p: Double) -> Double {
        anchorNs + p * 1e9 / sampleRate
    }
}

/// Converts the error between where playback *is* and where it *should be* into a
/// gentle playback-rate correction, with a hard resync when the error is large.
struct DriftController {
    /// Maximum playback-rate deviation (0.004 = ±0.4 %, inaudible).
    var maxRateDeviation = 0.004
    /// Time constant: an error is eliminated over roughly this many seconds.
    var correctionSeconds = 3.0
    /// Errors larger than this jump instead of slewing.
    var resyncThresholdMs = 50.0

    /// - Parameter errorFrames: ideal position minus actual position (positive = behind).
    func step(errorFrames: Double, sampleRate: Double) -> (ratio: Double, resync: Bool) {
        let errorMs = errorFrames * 1000 / sampleRate
        if abs(errorMs) > resyncThresholdMs { return (1, true) }
        let deviation = errorFrames / (correctionSeconds * sampleRate)
        let clamped = max(-maxRateDeviation, min(maxRateDeviation, deviation))
        return (1 + clamped, false)
    }
}
