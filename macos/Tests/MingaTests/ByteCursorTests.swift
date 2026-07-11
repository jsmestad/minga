import Foundation
import Testing

@Suite("ByteCursor")
struct ByteCursorTests {
    @Test("decodes integers and strings with checked offsets")
    func primitives() throws {
        var cursor = ByteCursor(Data([0x7F, 0x12, 0x34, 0x00, 0x00, 0x00, 0x02, 0x68, 0x69]))

        #expect(try cursor.readUInt8() == 0x7F)
        #expect(try cursor.readUInt16() == 0x1234)
        #expect(try cursor.readUInt32() == 2)
        #expect(try cursor.readString(count: 2) == "hi")
        #expect(cursor.isAtEnd)
        #expect(cursor.bytesCopied == 2)
        #expect(cursor.allocations == 1)
    }

    @Test("bounded slices do not copy packet bytes")
    func boundedSlicesAreZeroCopy() throws {
        let packet = Data(repeating: 0xAB, count: 1_048_576)
        var cursor = ByteCursor(packet)
        let slice = try cursor.readSlice(count: 16)

        #expect(slice.count == 16)
        #expect(slice.first == 0xAB)
        #expect(cursor.remaining == packet.count - 16)
        #expect(cursor.bytesCopied == 0)
        #expect(cursor.allocations == 0)
    }

    @Test("subcursor cannot escape its containing section")
    func boundedSubcursor() throws {
        var cursor = ByteCursor(Data([1, 2, 3, 4]))
        var section = try cursor.readSubcursor(count: 2)
        #expect(try section.readUInt16() == 0x0102)
        #expect(throws: ByteCursor.BoundsError.self) {
            try section.readUInt8()
        }
        #expect(cursor.remaining == 2)
    }

    @Test("oversized and negative lengths fail without integer overflow")
    func invalidLengths() {
        var cursor = ByteCursor(Data([1]))
        #expect(throws: ByteCursor.BoundsError.self) {
            try cursor.advance(by: Int.max)
        }
        #expect(throws: ByteCursor.BoundsError.self) {
            try cursor.advance(by: -1)
        }
        #expect(cursor.offset == 0)
    }
}
