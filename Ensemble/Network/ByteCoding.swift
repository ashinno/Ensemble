import Foundation

/// Little-endian binary writer used for the UDP wire format.
struct ByteWriter {
    private(set) var data = Data()

    init(capacity: Int = 64) { data.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { append(v.littleEndian) }
    mutating func u32(_ v: UInt32) { append(v.littleEndian) }
    mutating func u64(_ v: UInt64) { append(v.littleEndian) }
    mutating func i64(_ v: Int64) { append(v.littleEndian) }
    mutating func bytes(_ d: Data) { data.append(d) }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        var v = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

enum ByteCodingError: Error { case truncated, badMagic, unknownType(UInt8) }

/// Little-endian binary reader. Works correctly on `Data` slices (non-zero startIndex).
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() throws -> UInt8 { try read() }
    mutating func u16() throws -> UInt16 { try read() }
    mutating func u32() throws -> UInt32 { try read() }
    mutating func u64() throws -> UInt64 { try read() }
    mutating func i64() throws -> Int64 { try read() }

    mutating func bytes(_ count: Int) throws -> Data {
        guard remaining >= count else { throw ByteCodingError.truncated }
        let out = data.subdata(in: offset..<(offset + count))
        offset += count
        return out
    }

    private mutating func read<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw ByteCodingError.truncated }
        var v: T = 0
        _ = withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: offset..<(offset + size))
        }
        offset += size
        return T(littleEndian: v)
    }
}
