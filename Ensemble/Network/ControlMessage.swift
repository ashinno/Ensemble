import Foundation

/// Statistics a receiver reports back to the host once per second.
struct ReceiverStats: Codable, Equatable {
    var rttMs: Double = 0
    var clockOffsetMs: Double = 0
    var jitterMs: Double = 0
    var bufferMs: Double = 0
    var latencyMs: Double = 0
    var driftMs: Double = 0
    var rateCorrectionPPM: Double = 0
    var underruns: Int = 0
    var resyncs: Int = 0
    var packetsReceived: Int = 0
    var packetsLost: Int = 0
    var volume: Float = 1
    var outputLatencyMs: Double = 0
    var clockSynced: Bool = false
    /// Peak playback level (0…1) since the previous report, for the host's per-speaker meter.
    var level: Float = 0
    /// 95th percentile of capture→arrival latency (host timeline) over the last few seconds.
    var transitP95Ms: Double = 0
    /// Delay this receiver needs to avoid underruns on the current network (p95 + margin).
    var requiredDelayMs: Double = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case rttMs, clockOffsetMs, jitterMs, bufferMs, latencyMs, driftMs, rateCorrectionPPM, underruns, resyncs,
             packetsReceived, packetsLost, volume, outputLatencyMs, clockSynced, level, transitP95Ms, requiredDelayMs
    }

    /// Every field is optional on the wire so hosts and receivers of different versions interoperate.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rttMs = try c.decodeIfPresent(Double.self, forKey: .rttMs) ?? 0
        clockOffsetMs = try c.decodeIfPresent(Double.self, forKey: .clockOffsetMs) ?? 0
        jitterMs = try c.decodeIfPresent(Double.self, forKey: .jitterMs) ?? 0
        bufferMs = try c.decodeIfPresent(Double.self, forKey: .bufferMs) ?? 0
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs) ?? 0
        driftMs = try c.decodeIfPresent(Double.self, forKey: .driftMs) ?? 0
        rateCorrectionPPM = try c.decodeIfPresent(Double.self, forKey: .rateCorrectionPPM) ?? 0
        underruns = try c.decodeIfPresent(Int.self, forKey: .underruns) ?? 0
        resyncs = try c.decodeIfPresent(Int.self, forKey: .resyncs) ?? 0
        packetsReceived = try c.decodeIfPresent(Int.self, forKey: .packetsReceived) ?? 0
        packetsLost = try c.decodeIfPresent(Int.self, forKey: .packetsLost) ?? 0
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        outputLatencyMs = try c.decodeIfPresent(Double.self, forKey: .outputLatencyMs) ?? 0
        clockSynced = try c.decodeIfPresent(Bool.self, forKey: .clockSynced) ?? false
        level = try c.decodeIfPresent(Float.self, forKey: .level) ?? 0
        transitP95Ms = try c.decodeIfPresent(Double.self, forKey: .transitP95Ms) ?? 0
        requiredDelayMs = try c.decodeIfPresent(Double.self, forKey: .requiredDelayMs) ?? 0
    }

    var lossPercent: Double {
        let total = packetsReceived + packetsLost
        return total == 0 ? 0 : Double(packetsLost) * 100 / Double(total)
    }
}

/// Reliable control messages exchanged over the TCP connection (JSON, length-prefixed).
enum ControlMessage: Codable {
    // receiver -> host
    case hello(name: String, pairingCode: String?, protocolVersion: Int)
    case stats(ReceiverStats)
    case goodbye

    // host -> receiver
    case welcome(sessionToken: UInt64, udpPort: UInt16, hostName: String,
                 latencyMs: Double, sampleRate: Double, channels: Int)
    case pending(message: String)
    case rejected(reason: String)
    case setLatency(ms: Double)
    case setVolume(volume: Float)
    /// Play a short click at this host-clock time (used by the synchronization test).
    case syncTest(hostTimeNs: Int64)
}

/// 4-byte big-endian length prefix + JSON body.
enum ControlFraming {
    static let maxFrame = 1 << 20

    static func frame(_ message: ControlMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        var out = Data(capacity: body.count + 4)
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }
}

/// Accumulates bytes from a TCP stream and yields complete control messages.
struct ControlFrameParser {
    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    mutating func drainMessages() throws -> [ControlMessage] {
        var messages: [ControlMessage] = []
        while buffer.count >= 4 {
            let len = buffer.withUnsafeBytes { ptr -> UInt32 in
                UInt32(bigEndian: ptr.loadUnaligned(as: UInt32.self))
            }
            guard len <= ControlFraming.maxFrame else { throw ByteCodingError.badMagic }
            guard buffer.count >= 4 + Int(len) else { break }
            let body = buffer.subdata(in: 4..<(4 + Int(len)))
            buffer.removeSubrange(0..<(4 + Int(len)))
            messages.append(try JSONDecoder().decode(ControlMessage.self, from: body))
        }
        return messages
    }
}
