import Foundation
import CoreAudio
import AudioToolbox

enum CaptureError: LocalizedError {
    case noOutputDevice
    case tapCreation(OSStatus)
    case formatUnavailable(OSStatus)
    case aggregateCreation(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .noOutputDevice: return "No default output device."
        case .tapCreation(let s): return "Could not create the system audio tap (OSStatus \(s)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
        case .formatUnavailable(let s): return "Could not read the tap format (OSStatus \(s))."
        case .aggregateCreation(let s): return "Could not create the capture aggregate device (OSStatus \(s))."
        case .ioProc(let s): return "Could not install the audio IO proc (OSStatus \(s))."
        case .start(let s): return "Could not start audio capture (OSStatus \(s))."
        case .unsupportedFormat(let d): return "Unsupported tap format: \(d)"
        }
    }
}

/// Captures everything the Mac is playing using a Core Audio *process tap*
/// (`AudioHardwareCreateProcessTap`, macOS 14.2+).
///
/// A global tap that excludes this app's own process(es) is attached to a private
/// aggregate device built on the default output device. Core Audio then delivers the
/// mixed system audio as *input* to our IO proc.
///
/// With `muteSystemOutput == true` the tap uses `.mutedWhenTapped`: the tapped apps are
/// silenced at the speaker and Ensemble replays the captured audio itself through the
/// synchronized playback path, so the host's speakers line up with the receivers.
///
/// Requires the "System Audio Recording Only" privacy permission (Info.plist key
/// `NSAudioCaptureUsageDescription`). The microphone is never touched.
final class AudioCaptureManager: AudioSource {
    var onPacket: ((AudioPacket) -> Void)?
    var onStatus: ((AudioSourceStatus) -> Void)?
    private(set) var sampleRate: Double = 48000
    var muteSystemOutput: Bool

    private let queue = DispatchQueue(label: "ensemble.capture", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat = AudioStreamBasicDescription()
    private var chunker: PacketChunker?
    private var scratch: [Float] = []
    private var status = AudioSourceStatus()
    private var packets = 0
    private var lastStatusPushNs: Int64 = 0
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var listenedOutputDevice: AudioObjectID?
    private var isRunning = false
    private var buffersSeen = 0
    private var lastInputTimestampNs: Int64 = 0
    private var lastInputFrames = 0

    init(muteSystemOutput: Bool) {
        self.muteSystemOutput = muteSystemOutput
    }

    deinit { stop() }

    // MARK: - AudioSource

    func start() throws {
        try queue.sync { try self.startLocked() }
    }

    func stop() {
        queue.sync { self.stopLocked(notify: true) }
    }

    func injectClick() { queue.async { self.chunker?.injectClick() } }

    // MARK: - Implementation

    private func startLocked() throws {
        stopLocked(notify: false)

        guard let outputID = DeviceManager.defaultOutputDeviceID(),
              let outputUID = DeviceManager.deviceUID(outputID) else {
            throw CaptureError.noOutputDevice
        }
        let outputName = DeviceManager.deviceName(outputID) ?? "Default output"

        // Exclude every running instance of this app so our own playback is never captured.
        var excluded = Set<AudioObjectID>()
        if let bundleID = Bundle.main.bundleIdentifier {
            DeviceManager.processObjectIDs(forBundleID: bundleID).forEach { excluded.insert($0) }
        }
        if let own = DeviceManager.processObject(forPID: getpid()) { excluded.insert(own) }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Array(excluded))
        description.uuid = UUID()
        description.name = "Ensemble System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = muteSystemOutput ? .mutedWhenTapped : .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(description, &tap)
        guard tapErr == noErr, tap != kAudioObjectUnknown else { throw CaptureError.tapCreation(tapErr) }
        tapID = tap

        guard let format = DeviceManager.readValue(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) else {
            AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown
            throw CaptureError.formatUnavailable(-1)
        }
        tapFormat = format
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown
            throw CaptureError.unsupportedFormat("id=\(format.mFormatID) flags=\(format.mFormatFlags) bits=\(format.mBitsPerChannel)")
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ensemble Capture",
            kAudioAggregateDeviceUIDKey: "com.ashinno.ensemble.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggErr == noErr, aggregate != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown
            throw CaptureError.aggregateCreation(aggErr)
        }
        aggregateID = aggregate

        // The aggregate device drift-compensates the tap into the *output device's* clock,
        // so the IO proc delivers audio at the aggregate's nominal rate (the tap's own format
        // may report a different rate, e.g. 48 kHz while the speakers run at 44.1 kHz).
        sampleRate = DeviceManager.nominalSampleRate(aggregateID) ?? DeviceManager.nominalSampleRate(outputID) ?? format.mSampleRate
        if sampleRate < 8000 { sampleRate = format.mSampleRate }

        // 128 frames ≈ 2.7 ms at 48 kHz instead of the default 512 (≈ 11 ms).
        if !DeviceManager.setBufferFrameSize(aggregateID, frames: 128) { Log.info("Could not shrink capture IO buffer; using device default") }

        let chunker = PacketChunker(sampleRate: sampleRate, startSequence: self.chunker?.nextSequence ?? 0)
        chunker.onPacket = { [weak self] packet in
            guard let self else { return }
            self.packets += 1
            self.onPacket?(packet)
        }
        self.chunker = chunker
        scratch = [Float](repeating: 0, count: 8192 * 2)

        var proc: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inputData, inputTime, _, _ in
            self?.handleInput(inputData, inputTime)
        }
        guard procErr == noErr, let procID = proc else {
            teardownDevices()
            throw CaptureError.ioProc(procErr)
        }
        self.procID = procID

        let startErr = AudioDeviceStart(aggregateID, procID)
        guard startErr == noErr else {
            teardownDevices()
            throw CaptureError.start(startErr)
        }
        isRunning = true
        packets = 0
        status = AudioSourceStatus(isRunning: true,
                                   description: "System audio via \(outputName)\(muteSystemOutput ? " (muted at source, replayed in sync)" : "")",
                                   sampleRate: sampleRate, channels: Int(format.mChannelsPerFrame),
                                   peakLevel: 0, packetsSent: 0, error: nil)
        onStatus?(status)
        Log.info("Capture started: \(outputName) @ \(Int(sampleRate)) Hz (tap format \(Int(format.mSampleRate)) Hz), \(format.mChannelsPerFrame) ch, interleaved=\(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0), mute=\(muteSystemOutput)")

        installDeviceListener(outputDevice: outputID)
    }

    private func stopLocked(notify: Bool) {
        removeDeviceListener()
        teardownDevices()
        if isRunning {
            isRunning = false
            status = AudioSourceStatus()
            if notify { onStatus?(status) }
            Log.info("Capture stopped")
        }
    }

    private func teardownDevices() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>) {
        guard let chunker else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard buffers.count > 0 else { return }
        let nonInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let frames: Int
        if nonInterleaved {
            frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        } else {
            frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(buffers[0].mNumberChannels)))
        }
        guard frames > 0 else { return }
        if scratch.count < frames * 2 { scratch = [Float](repeating: 0, count: frames * 2) }

        var peak: Float = 0
        scratch.withUnsafeMutableBufferPointer { dst in
            if nonInterleaved {
                guard let l = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let r = buffers.count > 1 ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
                for i in 0..<frames {
                    let a = l[i], b = r[i]
                    dst[i * 2] = a; dst[i * 2 + 1] = b
                    peak = max(peak, abs(a), abs(b))
                }
            } else {
                let ch = Int(buffers[0].mNumberChannels)
                guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                if ch == 2 {
                    dst.baseAddress!.update(from: data, count: frames * 2)
                    for i in 0..<(frames * 2) { peak = max(peak, abs(data[i])) }
                } else {
                    for i in 0..<frames {
                        let a = data[i * ch]
                        let b = ch > 1 ? data[i * ch + 1] : a
                        dst[i * 2] = a; dst[i * 2 + 1] = b
                        peak = max(peak, abs(a), abs(b))
                    }
                }
            }
        }

        let ts = inputTime.pointee
        let timestampNs: Int64
        if ts.mFlags.contains(.hostTimeValid), ts.mHostTime != 0 {
            timestampNs = HostClock.machToNanos(ts.mHostTime)
        } else {
            timestampNs = HostClock.nowNanos
        }
        buffersSeen += 1
        if Log.verbose, buffersSeen <= 5 || buffersSeen % 500 == 0 {
            let now = HostClock.nowNanos
            let expected = lastInputTimestampNs + Int64(Double(lastInputFrames) * 1e9 / sampleRate)
            Log.debug(String(format: "capture buf #%d frames=%d hostTimeValid=%d ts-now=%.2fms ts-expected=%.3fms peak=%.4f",
                             buffersSeen, frames, ts.mFlags.contains(.hostTimeValid) ? 1 : 0,
                             Double(timestampNs - now) / 1e6, lastInputFrames == 0 ? 0 : Double(timestampNs - expected) / 1e6, peak))
        }
        lastInputTimestampNs = timestampNs
        lastInputFrames = frames
        scratch.withUnsafeBufferPointer { chunker.push(frames: $0.baseAddress!, frameCount: frames, timestampNs: timestampNs) }

        let now = HostClock.nowNanos
        status.peakLevel = max(status.peakLevel * 0.8, peak)
        if now - lastStatusPushNs > 100_000_000 {
            lastStatusPushNs = now
            status.packetsSent = packets
            onStatus?(status)
        }
    }

    // MARK: - Default device changes

    private func installDeviceListener(outputDevice: AudioObjectID) {
        removeDeviceListener()
        let rebuild: (String) -> Void = { [weak self] reason in
            guard let self, self.isRunning else { return }
            Log.info("\(reason); rebuilding system audio tap")
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                guard self.isRunning else { return }
                do { try self.startLocked() } catch {
                    Log.error("Failed to rebuild capture: \(error.localizedDescription)")
                    self.status = AudioSourceStatus(isRunning: false, description: "Capture failed", error: error.localizedDescription)
                    self.onStatus?(self.status)
                }
            }
        }
        deviceListener = DeviceManager.addDefaultOutputListener(queue: queue) { rebuild("Default output device changed") }
        listenedOutputDevice = outputDevice
        rateListener = DeviceManager.addSampleRateListener(device: outputDevice, queue: queue) { [weak self] in
            guard let self else { return }
            let newRate = DeviceManager.nominalSampleRate(outputDevice) ?? 0
            if abs(newRate - self.sampleRate) > 1 { rebuild("Output sample rate changed to \(Int(newRate)) Hz") }
        }
    }

    private func removeDeviceListener() {
        if let l = deviceListener {
            DeviceManager.removeDefaultOutputListener(l, queue: queue)
            deviceListener = nil
        }
        if let l = rateListener, let dev = listenedOutputDevice {
            DeviceManager.removeSampleRateListener(l, device: dev, queue: queue)
            rateListener = nil
            listenedOutputDevice = nil
        }
    }
}
