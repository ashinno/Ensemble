import Foundation

/// Anything that produces timestamped audio packets for the host to broadcast.
protocol AudioSource: AnyObject {
    var onPacket: ((AudioPacket) -> Void)? { get set }
    var onStatus: ((AudioSourceStatus) -> Void)? { get set }
    var sampleRate: Double { get }
    func start() throws
    func stop()
    /// Mix a short 1 kHz click into the outgoing stream (synchronization test).
    func injectClick()
}

struct AudioSourceStatus: Equatable {
    var isRunning = false
    var description = "Idle"
    var sampleRate: Double = 0
    var channels = 0
    /// Peak level 0…1 of the most recent audio, for the UI meter.
    var peakLevel: Float = 0
    var packetsSent = 0
    var error: String?
}

/// Splits arbitrary float input buffers into fixed-size packets, keeping timestamps
/// continuous across buffer boundaries and re-anchoring on discontinuities.
final class PacketChunker {
    let sampleRate: Double
    let channels = 2
    let framesPerPacket: Int
    private var accumulator: [Float] = []
    private var accumulatorTimestampNs: Int64 = 0
    private var sequence: UInt32 = 0
    private var clickFramesRemaining = 0
    private var clickPhase = 0
    var onPacket: ((AudioPacket) -> Void)?

    init(sampleRate: Double, startSequence: UInt32 = 0) {
        self.sampleRate = sampleRate
        self.framesPerPacket = max(48, Int(sampleRate / 200)) // 5 ms
        self.sequence = startSequence
        accumulator.reserveCapacity(framesPerPacket * 8)
    }

    /// Next sequence number that will be used (so a rebuilt chunker can continue the series).
    var nextSequence: UInt32 { sequence }

    func injectClick() { clickFramesRemaining = Int(sampleRate * 0.01); clickPhase = 0 }

    /// - Parameters:
    ///   - frames: interleaved stereo floats
    ///   - timestampNs: host time of the first frame
    func push(frames: UnsafePointer<Float>, frameCount: Int, timestampNs: Int64) {
        let accFrames = accumulator.count / channels
        if accFrames == 0 {
            accumulatorTimestampNs = timestampNs
        } else {
            let expected = accumulatorTimestampNs + Int64(Double(accFrames) * 1e9 / sampleRate)
            if abs(timestampNs - expected) > 5_000_000 {
                // Discontinuity (device glitch / restart): flush what we have and re-anchor.
                emit(frames: accFrames)
                accumulator.removeAll(keepingCapacity: true)
                accumulatorTimestampNs = timestampNs
            }
        }
        accumulator.append(contentsOf: UnsafeBufferPointer(start: frames, count: frameCount * channels))
        while accumulator.count / channels >= framesPerPacket {
            emit(frames: framesPerPacket)
            accumulator.removeFirst(framesPerPacket * channels)
            accumulatorTimestampNs += Int64(Double(framesPerPacket) * 1e9 / sampleRate)
        }
    }

    func reset() {
        accumulator.removeAll(keepingCapacity: true)
    }

    private func emit(frames: Int) {
        guard frames > 0 else { return }
        var samples = [Int16](repeating: 0, count: frames * channels)
        let ch = channels
        let click = clickFramesRemaining > 0
        let clickStart = clickPhase
        let rate = Float(sampleRate)
        samples.withUnsafeMutableBufferPointer { dst in
            accumulator.withUnsafeBufferPointer { src in
                for i in 0..<(frames * ch) {
                    var v = src[i]
                    if click {
                        let frame = i / ch
                        let n = Float(clickStart + frame)
                        v += sinf(2 * .pi * 1000 * n / rate) * 0.6 * max(0, 1 - n / (rate * 0.01))
                    }
                    let clamped = max(-1, min(1, v))
                    dst[i] = Int16(clamped * 32767)
                }
            }
        }
        if clickFramesRemaining > 0 {
            clickFramesRemaining -= frames
            clickPhase += frames
            if clickFramesRemaining <= 0 { clickFramesRemaining = 0 }
        }
        let packet = AudioPacket(sequence: sequence, timestampNs: accumulatorTimestampNs,
                                 sampleRate: UInt32(sampleRate), channels: UInt8(channels), samples: samples)
        sequence &+= 1
        onPacket?(packet)
    }
}

/// Synthetic source for testing without the system-audio permission: a soft 440 Hz tone
/// with a click once per second.
final class TestToneSource: AudioSource {
    var onPacket: ((AudioPacket) -> Void)?
    var onStatus: ((AudioSourceStatus) -> Void)?
    let sampleRate: Double = 48000
    private let queue = DispatchQueue(label: "ensemble.testtone", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var chunker: PacketChunker
    private var phase: Double = 0
    private var framesGenerated: Int64 = 0
    private var startNs: Int64 = 0
    private var packets = 0
    private var scratch: [Float]

    init() {
        chunker = PacketChunker(sampleRate: sampleRate)
        scratch = [Float](repeating: 0, count: 480 * 2)
        chunker.onPacket = { [weak self] p in
            guard let self else { return }
            self.packets += 1
            self.onPacket?(p)
        }
    }

    func start() throws {
        stop()
        startNs = HostClock.nowNanos
        framesGenerated = 0
        chunker.reset()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        onStatus?(AudioSourceStatus(isRunning: true, description: "Test tone (440 Hz + click/s)",
                                    sampleRate: sampleRate, channels: 2, peakLevel: 0.3, packetsSent: 0, error: nil))
    }

    func stop() {
        timer?.cancel(); timer = nil
        onStatus?(AudioSourceStatus())
    }

    func injectClick() { queue.async { self.chunker.injectClick() } }

    private func tick() {
        // Generate whatever the nominal timeline says should exist by now (catches up after stalls).
        let elapsedNs = HostClock.nowNanos - startNs
        let targetFrames = Int64(Double(elapsedNs) * sampleRate / 1e9)
        let behindPackets = (targetFrames - framesGenerated) / 240
        if behindPackets > 10 { Log.debug("test tone catching up \(behindPackets) packets (\(behindPackets * 5) ms stall)") }
        while framesGenerated + 240 <= targetFrames {
            let ts = startNs + Int64(Double(framesGenerated) * 1e9 / sampleRate)
            for i in 0..<240 {
                let frameIndex = framesGenerated + Int64(i)
                let posInSecond = Int(frameIndex % Int64(sampleRate))
                let t = Double(frameIndex) / sampleRate
                let env = Float((0.55 + 0.45 * sin(2 * .pi * 0.37 * t)) * (0.6 + 0.4 * sin(2 * .pi * 1.9 * t + 1.0)) * (0.7 + 0.3 * sin(2 * .pi * 5.3 * t)))
                var v = Float(sin(phase)) * 0.22 * env
                if posInSecond < 480 { // 10 ms click at the top of every second
                    v += sinf(2 * .pi * 1000 * Float(posInSecond) / Float(sampleRate)) * 0.5 * (1 - Float(posInSecond) / 480)
                }
                scratch[i * 2] = v; scratch[i * 2 + 1] = v
                phase += 2 * .pi * 440 / sampleRate
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
            scratch.withUnsafeBufferPointer { chunker.push(frames: $0.baseAddress!, frameCount: 240, timestampNs: ts) }
            framesGenerated += 240
        }
        if packets % 200 == 0 {
            onStatus?(AudioSourceStatus(isRunning: true, description: "Test tone (440 Hz + click/s)",
                                        sampleRate: sampleRate, channels: 2, peakLevel: 0.3, packetsSent: packets, error: nil))
        }
    }
}
