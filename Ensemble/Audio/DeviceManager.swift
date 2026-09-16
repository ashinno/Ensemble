import Foundation
import CoreAudio

/// Thin helpers over the Core Audio HAL: default output device, process objects for
/// tap exclusion, and change notifications.
enum DeviceManager {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func readValue<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             initial: T) -> T? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(objectID, &addr) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        return err == noErr ? value : nil
    }

    static func readString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        guard AudioObjectHasProperty(objectID, &addr) else { return nil }
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let s = value else { return nil }
        return s as String
    }

    static func readArray<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector, of: T.Type) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        var result = [T](unsafeUninitializedCapacity: count) { buf, initialized in
            initialized = 0
            let err = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buf.baseAddress!)
            initialized = err == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
        if result.count > count { result.removeLast(result.count - count) }
        return result
    }

    // MARK: Devices

    static func defaultOutputDeviceID() -> AudioObjectID? {
        let id: AudioObjectID? = readValue(AudioObjectID(kAudioObjectSystemObject),
                                           kAudioHardwarePropertyDefaultOutputDevice,
                                           initial: AudioObjectID(kAudioObjectUnknown))
        return (id == nil || id == kAudioObjectUnknown) ? nil : id
    }

    static func deviceUID(_ id: AudioObjectID) -> String? { readString(id, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ id: AudioObjectID) -> String? { readString(id, kAudioObjectPropertyName) }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        readValue(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
    }

    /// Ask a device for a smaller IO buffer (fewer frames per callback = lower latency).
    @discardableResult
    static func setBufferFrameSize(_ id: AudioObjectID, frames: UInt32) -> Bool {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        let err = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return err == noErr
    }

    // MARK: Processes (for tap exclusion)

    static func processObjectIDs(forBundleID bundleID: String) -> [AudioObjectID] {
        let all = readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        return all.filter { readString($0, kAudioProcessPropertyBundleID) == bundleID }
    }

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var inPID = pid
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &inPID, &size, &out)
        return (err == noErr && out != kAudioObjectUnknown) ? out : nil
    }

    // MARK: Listeners

    /// Observe changes of the default output device. Returns a token for `removeListener`.
    static func addDefaultOutputListener(queue: DispatchQueue, _ block: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in block() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        return listener
    }

    static func addSampleRateListener(device: AudioObjectID, queue: DispatchQueue, _ block: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in block() }
        AudioObjectAddPropertyListenerBlock(device, &addr, queue, listener)
        return listener
    }

    static func removeSampleRateListener(_ listener: @escaping AudioObjectPropertyListenerBlock, device: AudioObjectID, queue: DispatchQueue) {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(device, &addr, queue, listener)
    }

    static func removeDefaultOutputListener(_ listener: @escaping AudioObjectPropertyListenerBlock, queue: DispatchQueue) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
    }
}
