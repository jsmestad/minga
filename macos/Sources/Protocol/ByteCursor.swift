/// Checked, zero-copy cursor primitives for protocol packet decoding.

import Foundation
import MingaProtocol

/// A bounds-checked, `Sendable` cursor over an immutable `Data` range.
///
/// `readSlice(count:)` and `readSubcursor(count:)` retain a bounded view of the
/// packet instead of materializing the unconsumed tail. Owned values are only
/// created by operations such as `readString(count:)` that publish a final
/// immutable value beyond the decode call.
struct ByteCursor: Sendable {
    struct BoundsError: Error, Equatable, Sendable {
        let offset: Int
        let required: Int
        let remaining: Int
    }

    private let data: Data
    private let bounds: Range<Data.Index>
    private(set) var index: Data.Index
    private(set) var bytesCopied = 0
    private(set) var allocations = 0

    init(_ data: Data) {
        self.data = data
        self.bounds = data.startIndex..<data.endIndex
        self.index = data.startIndex
    }

    init(_ data: Data, range: Range<Data.Index>) throws {
        guard range.lowerBound >= data.startIndex,
              range.upperBound >= range.lowerBound,
              range.upperBound <= data.endIndex else {
            let offset = max(data.startIndex, min(range.lowerBound, data.endIndex))
            throw BoundsError(
                offset: data.distance(from: data.startIndex, to: offset),
                required: max(range.count, 0),
                remaining: data.distance(from: offset, to: data.endIndex)
            )
        }
        self.data = data
        self.bounds = range
        self.index = range.lowerBound
    }

    private init(data: Data, bounds: Range<Data.Index>) {
        self.data = data
        self.bounds = bounds
        self.index = bounds.lowerBound
    }

    var offset: Int { data.distance(from: data.startIndex, to: index) }
    var remaining: Int { data.distance(from: index, to: bounds.upperBound) }
    var isAtEnd: Bool { index == bounds.upperBound }

    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        let value = data[index]
        data.formIndex(after: &index)
        return value
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = UInt16(try readUInt8())
        return high << 8 | UInt16(try readUInt8())
    }

    mutating func readUInt32() throws -> UInt32 {
        let high = UInt32(try readUInt16())
        return high << 16 | UInt32(try readUInt16())
    }

    mutating func readUInt64() throws -> UInt64 {
        let high = UInt64(try readUInt32())
        return high << 32 | UInt64(try readUInt32())
    }

    /// Returns a bounded packet view without copying its bytes.
    mutating func readSlice(count: Int) throws -> Data.SubSequence {
        let range = try consumeRange(count: count)
        return data[range]
    }

    /// Returns a checked cursor restricted to the next `count` bytes.
    mutating func readSubcursor(count: Int) throws -> ByteCursor {
        ByteCursor(data: data, bounds: try consumeRange(count: count))
    }

    /// Decodes one final immutable UTF-8 value and accounts for its owned bytes.
    mutating func readString(count: Int) throws -> String {
        // Reserve before creating the owned String backing storage.
        try FrameDecodeAccounting.reserve(.ownedUTF8Bytes, count)
        let slice = try readSlice(count: count)
        guard let value = String(data: slice, encoding: .utf8) else {
            throw ProtocolDecodeError.malformed
        }
        bytesCopied += count
        allocations += 1
        return value
    }

    mutating func advance(by count: Int) throws {
        _ = try consumeRange(count: count)
    }

    private mutating func consumeRange(count: Int) throws -> Range<Data.Index> {
        try require(count)
        let start = index
        data.formIndex(&index, offsetBy: count)
        return start..<index
    }

    private func require(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw BoundsError(offset: offset, required: max(count, 0), remaining: remaining)
        }
    }
}
