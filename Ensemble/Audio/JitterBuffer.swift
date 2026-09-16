import Foundation
import os

/// Ring buffer of interleaved Float32 frames addressed by *absolute* frame position
/// on the stream timeline.
///
/// Writers place packets at their timeline position; gaps caused by packet loss are
/// zero-filled (silence). The reader pulls frames at a fractional position with linear
/// interpolation so the playback rate can be nudged by a fraction of a percent for
/// drift correction without audible pitch change.
final class JitterBuffer {
    let channels: Int
    let capacityFrames: Int

    private var storage: [Float]
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    /// One past the highest frame index written so far.
    private(set) var writePos: Int64 = 0
    private(set) var hasData = false
    private(set) var framesWritten: Int64 = 0

    init(channels: Int, capacityFrames: Int) {
        self.channels = channels
        self.capacityFrames = capacityFrames
        self.storage = [Float](repeating: 0, count: channels * capacityFrames)
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit { lock.deallocate() }

    func reset() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for i in storage.indices { storage[i] = 0 }
        writePos = 0
        hasData = false
        framesWritten = 0
    }

    /// Frames of audio available ahead of `position` (may be negative when starved).
    func framesAhead(of position: Double) -> Double {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return Double(writePos) - position
    }

    /// Write `frameCount` interleaved frames at absolute frame index `pos`.
    /// Returns false if the data was too old to be placed in the ring.
    @discardableResult
    func write(_ frames: UnsafePointer<Float>, frameCount: Int, at pos: Int64) -> Bool {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        if !hasData {
            hasData = true
            writePos = pos
        }
        let cap = Int64(capacityFrames)
        // Too old: already behind the ring's window.
        if pos + Int64(frameCount) <= writePos - cap { return false }
        // Gap (packet loss or late start): zero-fill so stale data is not replayed.
        if pos > writePos {
            let gap = min(pos - writePos, cap)
            zero(from: pos - gap, count: Int(gap))
        }
        let ch = channels
        storage.withUnsafeMutableBufferPointer { dst in
            var remaining = frameCount
            var src = frames
            var frame = pos
            while remaining > 0 {
                let start = ringIndex(frame)
                let run = min(remaining, capacityFrames - start)
                (dst.baseAddress! + start * ch).update(from: src, count: run * ch)
                src += run * ch
                frame += Int64(run)
                remaining -= run
            }
        }
        if pos + Int64(frameCount) > writePos { writePos = pos + Int64(frameCount) }
        framesWritten += Int64(frameCount)
        return true
    }

    /// Read `frameCount` output frames starting at fractional `position`, advancing by
    /// `ratio` frames per output frame (1.0 = nominal). Missing frames (not yet received,
    /// or overwritten because the reader fell too far behind) are rendered as silence.
    /// Returns the number of missing frames.
    func read(into out: UnsafeMutablePointer<Float>, frameCount: Int,
              from position: inout Double, ratio: Double) -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        var missing = 0
        let oldest = writePos - Int64(capacityFrames)
        let cap = capacityFrames
        let ch = channels
        let wp = writePos
        var p = position
        storage.withUnsafeBufferPointer { st in
            let base = st.baseAddress!
            if ratio == 1.0 && p == p.rounded(.down) {
                // Fast path: integer position, straight copy.
                var idx = Int64(p)
                var o = 0
                for _ in 0..<frameCount {
                    if idx >= wp || idx < oldest {
                        for c in 0..<ch { out[o + c] = 0 }
                        missing += 1
                    } else {
                        var r = Int(idx % Int64(cap)); if r < 0 { r += cap }
                        let a = base + r * ch
                        for c in 0..<ch { out[o + c] = a[c] }
                    }
                    idx += 1
                    o += ch
                }
                p += Double(frameCount)
                return
            }
            var o = 0
            for _ in 0..<frameCount {
                let fl = p.rounded(.down)
                let idx = Int64(fl)
                let frac = Float(p - fl)
                if idx + 1 >= wp || idx < oldest {
                    for c in 0..<ch { out[o + c] = 0 }
                    missing += 1
                } else {
                    var r0 = Int(idx % Int64(cap)); if r0 < 0 { r0 += cap }
                    var r1 = r0 + 1; if r1 == cap { r1 = 0 }
                    let a = base + r0 * ch
                    let b = base + r1 * ch
                    for c in 0..<ch {
                        let s0 = a[c], s1 = b[c]
                        out[o + c] = s0 + (s1 - s0) * frac
                    }
                }
                p += ratio
                o += ch
            }
        }
        position = p
        return missing
    }

    // MARK: - Private

    @inline(__always)
    private func ringIndex(_ frame: Int64) -> Int {
        let cap = Int64(capacityFrames)
        let m = frame % cap
        return Int(m < 0 ? m + cap : m)
    }

    private func zero(from start: Int64, count: Int) {
        let ch = channels
        storage.withUnsafeMutableBufferPointer { dst in
            var remaining = count
            var frame = start
            while remaining > 0 {
                let s = ringIndex(frame)
                let run = min(remaining, capacityFrames - s)
                (dst.baseAddress! + s * ch).update(repeating: 0, count: run * ch)
                frame += Int64(run)
                remaining -= run
            }
        }
    }
}
