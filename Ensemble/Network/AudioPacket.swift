import Foundation

/// Wire magic for every UDP datagram: "ENSM".
enum Wire {
    static let magic: UInt32 = 0x454E_534D
    static let protocolVersion = 1
    static let bonjourType = "_ensemble._tcp"
}

/// UDP datagram types.
enum UDPMessageType: UInt8 {
    case audio = 1
    case clockPing = 2
    case clockPong = 3
    case hello = 4
    case helloAck = 5
    case keepalive = 6
}

/// One chunk of PCM audio (16-bit interleaved) with the host capture timestamp of its first frame.
struct AudioPacket {
    var sequence: UInt32
    /// Host-clock time (nanoseconds, see `HostClock`) at which the first frame was captured.
    var timestampNs: Int64
    var sampleRate: UInt32
    var channels: UInt8
    /// Interleaved 16-bit samples, `frameCount * channels` entries.
    var samples: [Int16]

    var frameCount: Int { channels == 0 ? 0 : samples.count / Int(channels) }

    /// Duration of the packet in nanoseconds.
    var durationNs: Int64 { Int64(Double(frameCount) * 1e9 / Double(sampleRate)) }
}

/// Everything that travels over the UDP audio channel.
enum UDPMessage {
    case audio(AudioPacket)
    case clockPing(t1: Int64)
    case clockPong(t1: Int64, t2: Int64, t3: Int64)
    case hello(token: UInt64)
    case helloAck(token: UInt64)
    case keepalive

    func encode() -> Data {
        var w = ByteWriter(capacity: 32)
        w.u32(Wire.magic)
        switch self {
        case .audio(let p):
            w.u8(UDPMessageType.audio.rawValue)
            w.u8(p.channels)
            w.u8(0) // reserved (format: 0 = int16)
            w.u16(UInt16(p.frameCount))
            w.u32(p.sampleRate)
            w.u32(p.sequence)
            w.i64(p.timestampNs)
            p.samples.withUnsafeBufferPointer { buf in
                w.bytes(Data(buffer: buf))
            }
        case .clockPing(let t1):
            w.u8(UDPMessageType.clockPing.rawValue)
            w.i64(t1)
        case .clockPong(let t1, let t2, let t3):
            w.u8(UDPMessageType.clockPong.rawValue)
            w.i64(t1); w.i64(t2); w.i64(t3)
        case .hello(let token):
            w.u8(UDPMessageType.hello.rawValue)
            w.u64(token)
        case .helloAck(let token):
            w.u8(UDPMessageType.helloAck.rawValue)
            w.u64(token)
        case .keepalive:
            w.u8(UDPMessageType.keepalive.rawValue)
        }
        return w.data
    }

    static func decode(_ data: Data) throws -> UDPMessage {
        var r = ByteReader(data)
        guard try r.u32() == Wire.magic else { throw ByteCodingError.badMagic }
        let rawType = try r.u8()
        guard let type = UDPMessageType(rawValue: rawType) else { throw ByteCodingError.unknownType(rawType) }
        switch type {
        case .audio:
            let channels = try r.u8()
            _ = try r.u8()
            let frameCount = Int(try r.u16())
            let sampleRate = try r.u32()
            let sequence = try r.u32()
            let timestamp = try r.i64()
            let sampleCount = frameCount * Int(channels)
            let raw = try r.bytes(sampleCount * 2)
            var samples = [Int16](repeating: 0, count: sampleCount)
            _ = samples.withUnsafeMutableBytes { dst in
                raw.copyBytes(to: dst)
            }
            return .audio(AudioPacket(sequence: sequence, timestampNs: timestamp,
                                      sampleRate: sampleRate, channels: channels, samples: samples))
        case .clockPing:
            return .clockPing(t1: try r.i64())
        case .clockPong:
            return .clockPong(t1: try r.i64(), t2: try r.i64(), t3: try r.i64())
        case .hello:
            return .hello(token: try r.u64())
        case .helloAck:
            return .helloAck(token: try r.u64())
        case .keepalive:
            return .keepalive
        }
    }
}
