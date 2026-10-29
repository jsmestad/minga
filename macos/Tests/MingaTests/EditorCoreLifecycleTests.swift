import AppKit
import Foundation
import Testing

// These tests share AppKit's main run loop and observe external process termination.
@Suite("Editor core lifecycle", .serialized)
@MainActor
struct EditorCoreLifecycleTests {
    @Test("dev writer failure waits for ordered approval and EOF without recovery")
    func devWriterFailureBeforeEOF() {
        let fixture = Fixture(managed: false)
        #expect(fixture.quit.begin() == .pending)
        fixture.lifecycle.transportDidFail(message: "broken pipe")
        fixture.lifecycle.receive(approval)
        #expect(fixture.events.replies.isEmpty)
        fixture.lifecycle.readerDidClose()
        fixture.lifecycle.transportDidFail(message: "late writer failure")
        waitPastDeadline()

        #expect(fixture.events.replies == [true])
        #expect(fixture.events.retirements == 1)
        #expect(fixture.events.failures.isEmpty)
        #expect(fixture.events.terminations == 0)
    }

    @Test("dev core-initiated quit closes on EOF without a pending AppKit handshake")
    func devCoreInitiatedQuit() {
        let fixture = Fixture(managed: false)
        fixture.lifecycle.transportDidFail(message: "writer raced EOF")
        fixture.lifecycle.readerDidClose()
        waitPastDeadline()
        #expect(fixture.events.terminations == 1)
        #expect(fixture.events.replies.isEmpty)
        #expect(fixture.events.failures.isEmpty)
    }

    @Test("managed core-initiated clean quit uses normal exit without a native handshake")
    func managedCoreInitiatedQuit() throws {
        let fixture = Fixture(managed: true)
        let manager = try #require(fixture.manager)
        manager.onTermination = { _ in fixture.lifecycle.coreDidExit() }
        manager.onNormalExit = { fixture.events.terminations += 1 }
        fixture.lifecycle.readerDidClose()
        manager.handleTermination(status: 0, reason: .exit)
        waitPastDeadline()
        #expect(fixture.events.terminations == 1)
        #expect(fixture.events.retirements == 1)
        #expect(fixture.events.replies.isEmpty)
        #expect(fixture.events.failures.isEmpty)
        #expect(manager.exitIntent != .restartScheduled)
    }

    @Test("unexpected nonzero exit remains eligible for automatic restart without a pending quit")
    func unexpectedCrashRetainsRestartPolicy() throws {
        let fixture = Fixture(managed: true)
        let manager = try #require(fixture.manager)
        manager.onTermination = { _ in fixture.lifecycle.coreDidExit() }
        defer { manager.beginAppShutdown() }
        manager.handleTermination(status: 1, reason: .exit)
        #expect(manager.exitIntent == .restartScheduled)
        #expect(fixture.events.retirements == 1)
        #expect(fixture.events.replies.isEmpty)
        #expect(fixture.events.failures.isEmpty)
    }

    @Test("dead core without final approval cancels after the native-modal drain deadline")
    func missingFinalApprovalDeadline() throws {
        let fixture = Fixture(managed: true)
        let manager = try #require(fixture.manager)
        manager.onTermination = { _ in fixture.lifecycle.coreDidExit() }
        #expect(fixture.quit.begin() == .pending)
        manager.handleTermination(status: 1, reason: .exit)
        runLifecycleModalLoop(until: { fixture.events.coreStops == 1 })
        #expect(fixture.events.replies == [false])
        #expect(fixture.events.retirements == 1)
        #expect(fixture.events.coreStops == 1)
        #expect(manager.exitIntent != .restartScheduled)
    }

    @Test("approved nonzero exit retires the connection and ignores late failures")
    func approvedNonzeroExitThenLateFailure() throws {
        let fixture = Fixture(managed: true)
        let manager = try #require(fixture.manager)
        manager.onTermination = { _ in fixture.lifecycle.coreDidExit() }
        #expect(fixture.quit.begin() == .pending)
        fixture.lifecycle.receive(approval)
        fixture.lifecycle.readerDidClose()
        manager.handleTermination(status: 1, reason: .exit)
        fixture.lifecycle.transportDidFail(message: "late writer")
        fixture.lifecycle.readerDidClose()
        waitPastDeadline()

        #expect(fixture.events.replies == [true])
        #expect(fixture.events.retirements == 1)
        #expect(fixture.events.failures.isEmpty)
        #expect(manager.exitIntent == .appShutdown)
    }

    @Test("process death before final approval keeps reader delivery alive and suppresses late writer failure")
    func exitBeforeApproval() throws {
        let fixture = Fixture(managed: true)
        let manager = try #require(fixture.manager)
        manager.onTermination = { _ in fixture.lifecycle.coreDidExit() }
        #expect(fixture.quit.begin() == .pending)
        manager.handleTermination(status: 1, reason: .exit)
        fixture.lifecycle.transportDidFail(message: "late writer")
        #expect(fixture.events.retirements == 0)
        #expect(manager.exitIntent != .restartScheduled)
        fixture.lifecycle.receive(approval)
        fixture.lifecycle.readerDidClose()
        waitPastDeadline()

        #expect(fixture.events.replies == [true])
        #expect(fixture.events.retirements == 1)
        #expect(fixture.events.failures.isEmpty)
        #expect(manager.exitIntent == .appShutdown)
    }

    @Test("live managed process reaches bounded recovery inside the native quit modal loop")
    func liveProcessDeadlineDuringNativeTermination() throws {
        let fixture = Fixture(managed: true)
        let manager = try #require(fixture.manager)
        manager.start(configuration: BEAMLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            environment: [:],
            workingDirectoryURL: FileManager.default.temporaryDirectory
        ))
        defer { manager.abortStartup() }
        #expect(manager.hasLiveProcess)
        #expect(fixture.quit.begin() == .pending)
        fixture.lifecycle.receive(approval)
        fixture.lifecycle.transportDidFail(message: "broken live connection")
        runLifecycleModalLoop(until: { !fixture.events.failures.isEmpty })

        #expect(manager.hasLiveProcess)
        #expect(fixture.events.replies == [false])
        #expect(fixture.events.retirements == 1)
        #expect(fixture.events.failures == ["broken live connection"])
    }

    @Test("dev transport failure without EOF also reaches bounded recovery")
    func devTransportDeadline() {
        let fixture = Fixture(managed: false)
        fixture.lifecycle.transportDidFail(message: "broken parent connection")
        runLifecycleModalLoop(until: { !fixture.events.failures.isEmpty })
        #expect(fixture.events.failures == ["broken parent connection"])
        #expect(fixture.events.retirements == 1)
        #expect(fixture.events.terminations == 0)
    }

    @Test("reconnection invalidates the old deadline and accepts a later connection failure")
    func replacementInvalidatesDeadline() {
        let fixture = Fixture(managed: true)
        fixture.lifecycle.transportDidFail(message: "old connection")
        fixture.lifecycle.replaceConnection()
        waitPastDeadline()
        #expect(fixture.events.failures.isEmpty)
        #expect(fixture.events.retirements == 0)
        fixture.lifecycle.transportDidFail(message: "new connection")
        runLifecycleModalLoop(until: { !fixture.events.failures.isEmpty })
        #expect(fixture.events.failures == ["new connection"])
    }

    private var approval: ApplicationQuitResponse {
        ApplicationQuitResponse(requestID: 1, outcome: .proceeding, dirtyCount: 0, bufferName: "", detail: "")
    }

    private func waitPastDeadline() {
        let completion = Observations()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.04) {
            MainRunLoopAction { completion.terminations = 1 }.enqueue()
        }
        runLifecycleModalLoop(until: { completion.terminations == 1 })
    }

    @MainActor
    private final class Observations {
        var replies: [Bool] = []
        var failures: [String] = []
        var retirements = 0
        var terminations = 0
        var coreStops = 0
    }

    @MainActor
    private struct Fixture {
        let events: Observations
        let quit: ApplicationQuitCoordinator
        let manager: BEAMProcessManager?
        let lifecycle: EditorCoreLifecycle

        init(managed: Bool) {
            let events = Observations()
            let quit = ApplicationQuitCoordinator(
                sendRequest: { _ in true },
                sendDecision: { _, _ in true },
                presentDecision: { _, _ in Issue.record("Unexpected quit chooser") },
                replyToAppKit: { events.replies.append($0) },
                presentFailure: { _ in },
                restoreFocus: {}
            )
            let manager = managed ? BEAMProcessManager() : nil
            self.events = events
            self.quit = quit
            self.manager = manager
            self.lifecycle = EditorCoreLifecycle(
                quitCoordinator: quit,
                processManager: manager,
                closureTimeout: 0.01,
                retireConnection: { events.retirements += 1 },
                presentTransportFailure: { events.failures.append($0) },
                presentCoreStopped: { events.coreStops += 1 },
                terminateApplication: { events.terminations += 1 }
            )
        }
    }
}

@MainActor
private func runLifecycleModalLoop(until completed: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 2)
    while !completed(), Date() < deadline {
        RunLoop.main.run(mode: .modalPanel, before: deadline)
    }
}
