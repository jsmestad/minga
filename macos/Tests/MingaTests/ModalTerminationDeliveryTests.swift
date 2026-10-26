import AppKit
import Darwin
import Foundation
import MingaProtocol
import Testing

@Suite("Native termination callback delivery", .serialized)
@MainActor
struct ModalTerminationDeliveryTests {
    @Test("protocol events remain ordered across nested modal loops")
    func protocolEventsDuringTermination() throws {
        let input = Pipe()
        let output = Pipe()
        var events: [String] = []
        var connection: ProtocolConnection?
        connection = try ProtocolConnection(
            connectionID: 1,
            readHandle: input.fileHandleForReading,
            writeHandle: output.fileHandleForWriting,
            resourcePolicy: .default,
            isCurrent: { $0 == 1 },
            consume: { _, _ in
                MainActor.assertIsolated()
                if events.isEmpty {
                    events.append("first began")
                    connection?.waitForBlockedReaderAdmissionForTesting()
                    var barrierReached = false
                    MainRunLoopAction { barrierReached = true }.enqueue()
                    runModalLoop(until: { barrierReached })
                    events.append("first finished")
                } else {
                    events.append("second")
                }
            },
            onTransportFailure: { _ in },
            onInputRejection: { _ in },
            onReaderDisconnect: { _, _ in }
        )
        defer { connection?.stop(); connection = nil }
        connection?.start()
        // Two complete set_window_bg packets. The reader must retain FIFO admission during nested modal processing.
        try input.fileHandleForWriting.write(contentsOf: Data([0, 0, 0, 4, OP_SET_WINDOW_BG, 1, 2, 3, 0, 0, 0, 4, OP_SET_WINDOW_BG, 4, 5, 6]))

        runModalLoop(until: { events.count == 3 })
        #expect(events == ["first began", "first finished", "second"])
    }

    @Test("confirmed child exit reaches the main actor during native termination")
    func childExitDuringTermination() {
        let manager = BEAMProcessManager()
        var replies: [Bool] = []
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { replies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )
        #expect(coordinator.begin() == .pending)
        coordinator.receive(ApplicationQuitResponse(requestID: 1, outcome: .proceeding, dirtyCount: 0, bufferName: "", detail: ""))
        manager.onNormalExit = {
            MainActor.assertIsolated()
            #expect(coordinator.coreDidExit() == .approvedTermination)
        }
        manager.start(configuration: BEAMLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            environment: [:],
            workingDirectoryURL: FileManager.default.temporaryDirectory
        ))
        defer { manager.abortStartup() }

        runModalLoop(until: { !replies.isEmpty })
        #expect(replies == [true])
        #expect(!manager.hasLiveProcess)
    }

    @Test("outbound transport failure cancels a pending quit during native termination")
    func transportFailureDuringTermination() throws {
        let output = Pipe()
        var replies: [Bool] = []
        let coordinator = ApplicationQuitCoordinator(
            sendRequest: { _ in true },
            sendDecision: { _, _ in true },
            presentDecision: { _, _ in },
            replyToAppKit: { replies.append($0) },
            presentFailure: { _ in },
            restoreFocus: {}
        )
        #expect(coordinator.begin() == .pending)
        let encoder = try ProtocolEncoder(
            output: output.fileHandleForWriting,
            writeOperation: { _, _, _ in
                errno = EPIPE
                return -1
            },
            onTransportFailure: { _ in
                MainActor.assertIsolated()
                coordinator.transportDidDisconnect()
            }
        )
        defer { encoder.disconnect(reason: .expectedTeardown) }
        encoder.send(.executeCommand(name: "quit"))

        runModalLoop(until: { !replies.isEmpty })
        #expect(replies == [false])
        #expect(coordinator.state == .idle)
    }
}

@MainActor
private func runModalLoop(until completed: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 2)
    while !completed(), Date() < deadline {
        RunLoop.main.run(mode: .modalPanel, before: deadline)
    }
}
