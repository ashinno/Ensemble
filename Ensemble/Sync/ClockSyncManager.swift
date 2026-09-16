import Foundation

/// NTP-style clock offset estimation between this machine's `HostClock` and the host's.
///
/// The receiver sends `clockPing(t1)`; the host answers `clockPong(t1, t2, t3)` where t2 is
/// its receive time and t3 its send time; the receiver notes t4 on arrival.
///
///     offset (local − remote) = ((t1 − t2) + (t4 − t3)) / 2
///     round trip              = (t4 − t1) − (t3 − t2)
///
/// Samples with the smallest round trip are the most trustworthy, so the estimate is the
/// median offset of the best quarter of the recent window.
final class ClockSyncManager {
    struct Sample {
        let offsetNs: Double
        let rttNs: Double
        let receivedAt: Int64
    }

    private(set) var samples: [Sample] = []
    private let windowSize = 64

    /// Estimated local − remote clock offset in nanoseconds.
    private(set) var offsetNs: Double = 0
    /// Best recent round-trip time in nanoseconds.
    private(set) var rttNs: Double = 0
    /// Standard deviation of recent round trips (network jitter) in nanoseconds.
    private(set) var jitterNs: Double = 0
    private(set) var isSynced = false
    /// Offset at the moment of first lock; `offsetNs - initialOffsetNs` is the clock drift since.
    private(set) var initialOffsetNs: Double?
    private(set) var pingsSent = 0
    private(set) var pongsReceived = 0

    /// Called when a ping should be transmitted with the given t1.
    var sendPing: ((Int64) -> Void)?

    private var timer: DispatchSourceTimer?
    private var outstanding: [Int64: Int64] = [:] // t1 -> t1 (dedupe / validation)
    private let burstCount = 10
    private let burstIntervalMs = 100
    /// 200 ms keeps the receiver's Wi‑Fi radio out of power save and tracks drift closely.
    private let steadyIntervalMs = 100

    func start(on queue: DispatchQueue) {
        stop()
        reset()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(burstIntervalMs))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func reset() {
        samples.removeAll()
        offsetNs = 0; rttNs = 0; jitterNs = 0
        isSynced = false
        initialOffsetNs = nil
        pingsSent = 0; pongsReceived = 0
        outstanding.removeAll()
    }

    private func tick() {
        let t1 = HostClock.nowNanos
        outstanding[t1] = t1
        if outstanding.count > 64 { outstanding.removeAll() }
        pingsSent += 1
        sendPing?(t1)
        if pingsSent == burstCount, let t = timer {
            t.schedule(deadline: .now() + .milliseconds(steadyIntervalMs),
                       repeating: .milliseconds(steadyIntervalMs))
        }
    }

    func handlePong(t1: Int64, t2: Int64, t3: Int64) {
        let t4 = HostClock.nowNanos
        guard outstanding.removeValue(forKey: t1) != nil else { return } // unknown or duplicate
        let rtt = Double((t4 - t1) - (t3 - t2))
        guard rtt >= 0, rtt < 2e9 else { return }
        let offset = (Double(t1 - t2) + Double(t4 - t3)) / 2
        samples.append(Sample(offsetNs: offset, rttNs: rtt, receivedAt: t4))
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        pongsReceived += 1
        recompute()
    }

    private func recompute() {
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted { $0.rttNs < $1.rttNs }
        let bestCount = max(1, min(sorted.count, max(3, sorted.count / 4)))
        let best = Array(sorted.prefix(bestCount))
        let offsets = best.map(\.offsetNs).sorted()
        offsetNs = offsets[offsets.count / 2]
        rttNs = sorted[0].rttNs
        let recent = samples.suffix(16).map(\.rttNs)
        let mean = recent.reduce(0, +) / Double(recent.count)
        let variance = recent.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(recent.count)
        jitterNs = variance.squareRoot()
        isSynced = samples.count >= 3
        if isSynced, initialOffsetNs == nil { initialOffsetNs = offsetNs }
    }
}
