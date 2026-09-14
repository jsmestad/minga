import Foundation
import MingaProtocol
import Testing

@Suite("Operation receipt protocol")
struct OperationProtocolTests {
    @Test("decodes exact presentation target and operation correlation")
    func decodePresentationCorrelation() throws {
        var target = Data([OP_PRESENTATION_TARGET])
        appendU64(&target, 0x0102_0304_0506_0708)
        appendU16(&target, 9)
        appendU32(&target, 42)
        target.append(1)

        let (targetCommand, targetSize) = try decodeCommand(data: target, offset: 0)
        #expect(targetSize == 16)
        guard case .presentationTarget(let decodedTarget) = targetCommand else {
            Issue.record("expected presentation target")
            return
        }
        #expect(decodedTarget == PresentationTarget(token: 0x0102_0304_0506_0708, windowID: 9, applicationRevision: 42, focusRequired: true))

        var operation = Data([OP_PRESENTATION_OPERATION])
        appendU64(&operation, 71)
        appendU64(&operation, 0x0102_0304_0506_0708)
        appendU16(&operation, 9)
        appendU32(&operation, 42)
        operation.append(1)

        let (operationCommand, operationSize) = try decodeCommand(data: operation, offset: 0)
        #expect(operationSize == 24)
        guard case .presentationOperation(let decodedOperation) = operationCommand else {
            Issue.record("expected presentation operation")
            return
        }
        #expect(decodedOperation == PresentationOperation(operationID: 71, targetToken: 0x0102_0304_0506_0708, windowID: 9, applicationRevision: 42, focusRequired: true))
    }

    @Test("rejects malformed presentation correlation")
    func rejectMalformedPresentationCorrelation() {
        let shortTarget = Data([OP_PRESENTATION_TARGET] + Array(repeating: 0, count: 14))
        #expect(throws: ProtocolDecodeError.self) { try decodeCommand(data: shortTarget, offset: 0) }

        var invalidFocus = Data([OP_PRESENTATION_TARGET] + Array(repeating: 0, count: 15))
        invalidFocus[15] = 2
        #expect(throws: ProtocolDecodeError.self) { try decodeCommand(data: invalidFocus, offset: 0) }

        var invalidPostcondition = Data([OP_PRESENTATION_OPERATION] + Array(repeating: 0, count: 23))
        invalidPostcondition[23] = 2
        #expect(throws: ProtocolDecodeError.self) { try decodeCommand(data: invalidPostcondition, offset: 0) }
    }

    @Test("encodes attempted and last-visible evidence in fixed layout")
    func encodeNativeResult() {
        let pipe = Pipe()
        let encoder = try! ProtocolEncoder(output: pipe.fileHandleForWriting)
        let evidence = NativePresentationEvidence(targetToken: 72, applicationRevision: 44, generation: 3, frameSeq: 10, windowID: 4, focusReady: true, boundary: .metalDrawableCompleted)
        let lastVisible = NativePresentationEvidence(targetToken: 61, applicationRevision: 43, generation: 2, frameSeq: 9, windowID: 1, focusReady: true, boundary: .metalDrawableCompleted)

        encoder.sendOperationNativeResult(NativeOperationResult(operationID: 71, targetToken: 72, outcome: .ready, evidence: evidence, lastVisible: lastVisible))
        #expect(encoder.waitForPendingWritesForTesting())
        pipe.fileHandleForWriting.closeFile()
        let framed = pipe.fileHandleForReading.readDataToEndOfFile()
        let payload = framed.subdata(in: 4..<framed.count)

        #expect(payload.count == 57)
        #expect(payload[0] == OP_OPERATION_NATIVE_RESULT)
        #expect(readU64(payload, 1) == 71)
        #expect(readU64(payload, 9) == 72)
        #expect(readU32(payload, 17) == 3)
        #expect(readU32(payload, 21) == 10)
        #expect(readU16(payload, 25) == 4)
        #expect(payload[27] == NativeOperationResult.Outcome.ready.rawValue)
        #expect(payload[28] == 1)
        #expect(payload[29] == NativePresentationEvidence.Boundary.metalDrawableCompleted.rawValue)
        #expect(readU32(payload, 30) == 44)
        #expect(readU64(payload, 34) == 61)
        #expect(readU32(payload, 42) == 2)
        #expect(readU32(payload, 46) == 9)
        #expect(readU16(payload, 50) == 1)
        #expect(payload[52] == 1)
        #expect(readU32(payload, 53) == 43)
    }

    private func appendU16(_ data: inout Data, _ value: UInt16) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func appendU32(_ data: inout Data, _ value: UInt32) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func appendU64(_ data: inout Data, _ value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readU32(data, offset)) << 32 | UInt64(readU32(data, offset + 4))
    }
}
