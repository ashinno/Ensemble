import Foundation
import AVFoundation

/// Plays a timestamped PCM stream through the default output device at a fixed delay
/// behind the host's capture clock.
///
/// Every render callback computes, from the output timestamp and the clock offset, which
/// stream position *should* be leaving the speaker right now, and steers a fractional
/// read pointer toward it (`DriftController`). Because the target is derived from time
/// rather than from sample counts, receivers on different machines converge on the same
/// audio at the same instant, and sample-clock drift between machines is corrected
/// continuously.
///
/// The same class is used by the host for its own "synchronized local speakers" (with a
/// clock offset of zero).
final class AudioPlaybackManager {
    struct Stats {
        var isRunning = false
        var bufferMs: Double = 0
        var driftErrorMs: Double = 0
        var rateCorrectionPPM: Double = 0
        var underruns = 0
        var resyncs = 0
        var packetsReceived = 0
        var packetsLost = 0
        var outputLatencyMs: Double = 0
        var outputDeviceName = ""
        var targetLatencyMs: Double = 0
    }

    let sampleRate: Double
    let channels = 2
    let buffer: JitterBuffer

    // Parameters read by the render thread (plain stores; 64-bit aligned on arm64).
    /// local − remote clock offset in ns (0 when the player runs on the host itself).
    var clockOffsetNs: Double = 0
    var targetLatencyNs: Double = 150e6 {
        didSet { if targetLatencyNs != oldValue { forceResync = true } }
    }
    private var forceResync = false
    /// Manual fine-tuning applied on top of the target latency (positive = play later).
    var trimNs: Double = 0
    /// When false only scheduled clicks are rendered (used by the host in "direct" mode).
    var streamEnabled = true
    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let format: AVAudioFormat
    private var mapping: TimelineMapping
    private let drift = DriftController()
    private let stateLock = NSLock()

    private var readPos: Double = 0
    private var started = false
    private var prefillCallbacks = 0
    private var lastUnderrunLogNs: Double = 0
    private var nextPos: Int64 = 0
    private var lastSequence: UInt32?
    private var scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 8192
    private var outputLatencyNs: Double = 0
    private var scheduledClicks: [Int64] = []
    private var stats = Stats()
    private var configObserver: NSObjectProtocol?
    private var restartWorkItem: DispatchWorkItem?

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.buffer = JitterBuffer(channels: 2, capacityFrames: Int(sampleRate * 8))
        self.mapping = TimelineMapping(sampleRate: sampleRate)
        self.format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * 2)
        self.scratch.initialize(repeating: 0, count: scratchFrames * 2)
        stats.targetLatencyMs = targetLatencyNs / 1e6
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    // MARK: - Lifecycle

    func start() throws {
        if engine.isRunning { return }
        if sourceNode == nil {
            let node = AVAudioSourceNode(format: format) { [weak self] silence, timestamp, frameCount, audioBufferList -> OSStatus in
                guard let self else { return noErr }
                return self.render(silence: silence, timestamp: timestamp, frameCount: Int(frameCount), abl: audioBufferList)
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = volume
            sourceNode = node
        }
        engine.prepare()
        if let unit = engine.outputNode.audioUnit {
            var frames: UInt32 = 128   // ≈ 2.7 ms at 48 kHz; the default is usually 512
            AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        try engine.start()
        refreshOutputInfo()
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in self?.handleConfigurationChange() }
        }
        stateLock.lock(); stats.isRunning = true; stateLock.unlock()
        Log.info("Playback started (\(Int(sampleRate)) Hz, output latency \(String(format: "%.1f", outputLatencyNs / 1e6)) ms)")
    }

    func stop() {
        restartWorkItem?.cancel()
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        if engine.isRunning { engine.stop() }
        stateLock.lock(); stats.isRunning = false; stateLock.unlock()
    }

    /// Forget the stream timeline (call when (re)connecting to a host).
    func resetTimeline() {
        stateLock.lock()
        mapping.reset()
        buffer.reset()
        started = false
        prefillCallbacks = 0
        nextPos = 0
        lastSequence = nil
        readPos = 0
        stats.packetsLost = 0
        stats.packetsReceived = 0
        stats.underruns = 0
        stats.resyncs = 0
        stateLock.unlock()
    }

    func snapshot() -> Stats {
        stateLock.lock(); defer { stateLock.unlock() }
        var s = stats
        s.targetLatencyMs = targetLatencyNs / 1e6
        s.outputLatencyMs = outputLatencyNs / 1e6
        return s
    }

    /// Play a 1 kHz click when the host clock reaches `remoteTimeNs`.
    func scheduleClick(atRemoteTimeNs remoteTimeNs: Int64) {
        stateLock.lock()
        scheduledClicks.append(remoteTimeNs)
        stateLock.unlock()
    }

    // MARK: - Input

    /// Called from the network (or capture) thread for every packet.
    func enqueue(_ packet: AudioPacket) {
        guard Double(packet.sampleRate) == sampleRate, packet.channels == 2 || packet.channels == 1 else { return }
        let frames = packet.frameCount
        guard frames > 0, frames <= scratchFrames else { return }

        // Convert to interleaved stereo float.
        var floats = [Float](repeating: 0, count: frames * 2)
        let scale: Float = 1.0 / 32768.0
        let stereo = packet.channels == 2
        floats.withUnsafeMutableBufferPointer { dst in
            packet.samples.withUnsafeBufferPointer { src in
                if stereo {
                    for i in 0..<(frames * 2) { dst[i] = Float(src[i]) * scale }
                } else {
                    for i in 0..<frames {
                        let v = Float(src[i]) * scale
                        dst[2 * i] = v; dst[2 * i + 1] = v
                    }
                }
            }
        }

        stateLock.lock()
        var pos: Int64
        var lost = 0
        let byTimestamp: () -> Int64 = { [self] in
            mapping.isSet ? Int64(mapping.position(forTimestampNs: Double(packet.timestampNs)).rounded()) : 0
        }
        if let last = lastSequence {
            let diff = Int64(packet.sequence) &- Int64(last)
            if diff == 1 {
                pos = nextPos
            } else if diff > 1 && diff < 5000 {
                lost = Int(diff - 1)
                pos = byTimestamp()
            } else if diff <= 0 && diff > -1000 {
                // Late or duplicate packet: place it by timestamp, do not touch continuity.
                let p = byTimestamp()
                stateLock.unlock()
                _ = floats.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frameCount: frames, at: p) }
                return
            } else {
                // Sequence restarted (host re-created its capture) or a huge jump: re-anchor.
                pos = byTimestamp()
            }
        } else {
            pos = byTimestamp()
        }
        let reset = mapping.update(timestampNs: packet.timestampNs, position: pos)
        if reset && started {
            // Host re-anchored its timeline; force a resync on the next render.
            started = false
        }
        stats.packetsLost += lost
        stats.packetsReceived += 1
        lastSequence = packet.sequence
        nextPos = pos + Int64(frames)
        stateLock.unlock()

        _ = floats.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frameCount: frames, at: pos) }
    }

    // MARK: - Render

    private func render(silence: UnsafeMutablePointer<ObjCBool>, timestamp: UnsafePointer<AudioTimeStamp>,
                        frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let frames = min(frameCount, scratchFrames)
        let ts = timestamp.pointee
        var localNs: Double
        if ts.mFlags.contains(.hostTimeValid), ts.mHostTime != 0 {
            localNs = Double(HostClock.machToNanos(ts.mHostTime))
        } else {
            localNs = Double(HostClock.nowNanos)
        }
        // Time at which the first frame of this buffer leaves the speaker, in the host's clock.
        let remoteNs = localNs + outputLatencyNs - clockOffsetNs
        let captureNs = remoteNs - targetLatencyNs - trimNs

        stateLock.lock()
        let streamOn = streamEnabled && mapping.isSet && buffer.hasData
        var rendered = false
        if streamOn {
            let ideal = mapping.position(forTimestampNs: captureNs)
            if !started {
                // Prefill: wait until audio for the ideal position has actually arrived, so the
                // first second is silent rather than choppy. Give up waiting after ~1 s so a
                // delay shorter than the network latency still produces (imperfect) sound.
                prefillCallbacks += 1
                if ideal > Double(buffer.writePos) && prefillCallbacks < 100 {
                    for i in 0..<(frames * 2) { scratch[i] = 0 }
                    stats.bufferMs = (Double(buffer.writePos) - ideal) * 1000 / sampleRate
                    stateLock.unlock()
                    let buffers = UnsafeMutableAudioBufferListPointer(abl)
                    for ch in 0..<min(2, buffers.count) {
                        if let data = buffers[ch].mData?.assumingMemoryBound(to: Float.self) {
                            for i in 0..<frameCount { data[i] = 0 }
                        }
                    }
                    silence.pointee = true
                    return noErr
                }
                readPos = ideal
                started = true
                prefillCallbacks = 0
            }
            let error = ideal - readPos
            var (ratio, resync) = drift.step(errorFrames: error, sampleRate: sampleRate)
            if forceResync { forceResync = false; resync = true; ratio = 1 }   // delay changed: jump on every Mac at once
            if resync {
                Log.debug(String(format: "player resync: error %.1f ms, buffer %.0f ms", error * 1000 / sampleRate, (Double(buffer.writePos) - readPos) * 1000 / sampleRate))
                readPos = ideal
                stats.resyncs += 1
            }
            let missing = buffer.read(into: scratch, frameCount: frames, from: &readPos, ratio: ratio)
            if missing > 0 {
                stats.underruns += 1
                if Log.verbose, Double(HostClock.nowNanos) - lastUnderrunLogNs > 1e9 {
                    lastUnderrunLogNs = Double(HostClock.nowNanos)
                    Log.debug(String(format: "player underrun: missing %d/%d frames, buffer %.0f ms, error %.1f ms", missing, frames, (Double(buffer.writePos) - readPos) * 1000 / sampleRate, error * 1000 / sampleRate))
                }
            }
            stats.bufferMs = (Double(buffer.writePos) - readPos) * 1000 / sampleRate
            stats.driftErrorMs = error * 1000 / sampleRate
            stats.rateCorrectionPPM = (ratio - 1) * 1e6
            rendered = missing < frames
        } else {
            for i in 0..<(frames * 2) { scratch[i] = 0 }
            stats.bufferMs = 0
        }
        // Scheduled clicks (synchronization test): 10 ms 1 kHz burst at exact host time.
        if !scheduledClicks.isEmpty {
            let nsPerFrame = 1e9 / sampleRate
            let clickNs: Double = 10e6
            let endOfBuffer = remoteNs + Double(frames) * nsPerFrame
            for click in scheduledClicks {
                let c = Double(click)
                guard c < endOfBuffer, c + clickNs > remoteNs else { continue }
                for i in 0..<frames {
                    let t = remoteNs + Double(i) * nsPerFrame - c
                    guard t >= 0, t < clickNs else { continue }
                    let env = Float(1 - t / clickNs)
                    let v = sinf(Float(2 * Double.pi * 1000 * t / 1e9)) * 0.6 * env
                    scratch[i * 2] += v
                    scratch[i * 2 + 1] += v
                }
                rendered = true
            }
            scheduledClicks.removeAll { Double($0) + clickNs < remoteNs }
        }
        stateLock.unlock()

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        for ch in 0..<min(2, buffers.count) {
            guard let data = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frames { data[i] = scratch[i * 2 + ch] }
            if frames < frameCount { for i in frames..<frameCount { data[i] = 0 } }
        }
        silence.pointee = ObjCBool(!rendered)
        return noErr
    }

    // MARK: - Device changes

    private func refreshOutputInfo() {
        outputLatencyNs = engine.outputNode.presentationLatency * 1e9
        var name = "Default output"
        if let id = DeviceManager.defaultOutputDeviceID(), let n = DeviceManager.deviceName(id) { name = n }
        stateLock.lock(); stats.outputDeviceName = name; stateLock.unlock()
    }

    private func handleConfigurationChange() {
        Log.info("Output device configuration changed; restarting playback engine")
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                self.engine.prepare()
                try self.engine.start()
                self.refreshOutputInfo()
                self.stateLock.lock(); self.started = false; self.stateLock.unlock()
            } catch {
                Log.error("Failed to restart playback engine: \(error)")
            }
        }
        restartWorkItem = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
