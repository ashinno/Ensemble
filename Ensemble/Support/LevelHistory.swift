import Foundation
import os

/// Thread-safe ring of recent peak levels (0…1), one entry per audio packet.
/// Used to draw the live waveform and level bars in the UI.
final class LevelHistory {
    private var values: [Float]
    private var index = 0
    private var filled = false
    private let lock = NSLock()

    init(capacity: Int = 300) {
        values = [Float](repeating: 0, count: capacity)
    }

    func push(_ value: Float) {
        lock.lock(); defer { lock.unlock() }
        values[index] = value
        index = (index + 1) % values.count
        if index == 0 { filled = true }
    }

    /// Oldest → newest.
    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if !filled { return Array(values[0..<index]) }
        return Array(values[index...]) + Array(values[..<index])
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in values.indices { values[i] = 0 }
        index = 0; filled = false
    }

    /// Peak amplitude of a packet, 0…1.
    static func peak(of packet: AudioPacket) -> Float {
        var m: Int32 = 0
        for s in packet.samples {
            let a = Int32(s).magnitude
            if a > m { m = Int32(a) }
        }
        return Float(m) / 32768
    }
}
