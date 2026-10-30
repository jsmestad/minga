/// Consumer coverage comes only from the generated schema declarations.
import Foundation
import Testing

@Suite("Protocol consumer declarations")
struct ProtocolConsumersTests {
    @Test("Every BEAM-to-frontend opcode is required or explicitly skipped")
    func generatedDeclarationsCoverEveryOpcode() {
        let required = Set(SwiftRequiredOpcode.allCases.map(\.rawValue))
        let skipped = Set(swiftSkippedOpcodes.keys)

        #expect(required.isDisjoint(with: skipped))
        #expect(required.union(skipped) == beamToFrontendOpcodes)
        for (opcode, reason) in swiftSkippedOpcodes {
            #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Skipped opcode \(opcode) must explain why it is not consumed")
        }
    }

    @Test("Declared skips use generated framing and preserve the next command")
    func declaredSkipsPreserveCommandBoundaries() throws {
        let sentinel: [UInt8] = [OP_COMMIT_FRAME, 0, 0, 0, 7, 0, 0, 0, 0]
        for opcode in swiftSkippedOpcodes.keys.sorted() {
            let probe = [opcode] + [UInt8](repeating: 0, count: 64)
            guard case .sized(let size) = commandSize(probe), size > 0, size <= probe.count else {
                Issue.record("Skipped opcode \(opcode) must have generated, bounded framing")
                continue
            }

            let data = Data(probe.prefix(size) + sentinel)
            let (command, consumed) = try decodeCommand(data: data, offset: 0)
            #expect(consumed == size)
            guard case nil = command else {
                Issue.record("Declared skip \(opcode) produced a render command")
                continue
            }
            let (next, nextSize) = try decodeCommand(data: data, offset: consumed)
            guard case .commitFrame(let frameSeq, _) = next else {
                Issue.record("Skipped opcode \(opcode) did not preserve the commit sentinel")
                continue
            }
            #expect(frameSeq == 7)
            #expect(nextSize == sentinel.count)
        }
    }

    @Test("Undeclared opcodes fail closed, including parser and input directions")
    func undeclaredOpcodesAreRejected() {
        let declared = Set(SwiftRequiredOpcode.allCases.map(\.rawValue))
            .union(swiftSkippedOpcodes.keys)
        for opcode in UInt8.min...UInt8.max where !declared.contains(opcode) {
            let data = Data([opcode] + [UInt8](repeating: 0, count: 64))
            do {
                _ = try decodeCommand(data: data, offset: 0)
                Issue.record("Undeclared opcode \(opcode) decoded instead of failing closed")
            } catch ProtocolDecodeError.unknownOpcode(let rejected) {
                #expect(rejected == opcode)
            } catch {
                Issue.record("Undeclared opcode \(opcode) must throw unknownOpcode, got \(error)")
            }
        }
    }

    @Test("Malformed required commands cannot fall back to a sized skip")
    func requiredCommandDoesNotUseSkipFallback() {
        // Generated len32 framing accepts an empty clipboard payload, but its
        // required semantic decoder must reject the missing target and text length.
        #expect(SwiftRequiredOpcode(rawValue: OP_CLIPBOARD_WRITE) != nil)
        #expect(throws: ProtocolDecodeError.self) {
            _ = try decodeCommand(data: Data([OP_CLIPBOARD_WRITE, 0, 0, 0, 0]), offset: 0)
        }
    }
}
