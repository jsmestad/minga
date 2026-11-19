import Darwin
import Foundation
import MingaProtocol
import Testing

@Suite("Startup pipe ownership", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct StartupOwnershipTests {
    @Test("unstarted connection closes both handles once after writer retirement")
    func closesUnstartedConnection() throws {
        let input = Pipe()
        let output = Pipe()
        let readFD = input.fileHandleForReading.fileDescriptor
        let writeFD = output.fileHandleForWriting.fileDescriptor
        let connection = try makeConnection(input.fileHandleForReading, output.fileHandleForWriting)
        connection.stop()
        #expect(connection.encoder.waitForPendingWritesForTesting())
        #expect(fcntl(readFD, F_GETFD) == -1)
        #expect(fcntl(writeFD, F_GETFD) == -1)

        let replacement = Pipe()
        connection.stop()
        #expect(connection.encoder.waitForPendingWritesForTesting())
        #expect(fcntl(replacement.fileHandleForWriting.fileDescriptor, F_GETFD) != -1)
    }

    @Test("stop returns before an in-flight writer retires and closes its handles afterward")
    func retiresInFlightWrite() throws {
        let input = Pipe()
        let output = Pipe()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writeFD = output.fileHandleForWriting.fileDescriptor
        let connection = try makeConnection(
            input.fileHandleForReading, output.fileHandleForWriting,
            encoderFactory: { handle in
                try ProtocolEncoder(output: handle, writeOperation: { _, _, count in
                    entered.signal()
                    release.wait()
                    return count
                })
            }
        )
        connection.encoder.send(.keyPress(codepoint: 97, modifiers: 0, sequence: 0))
        #expect(entered.wait(timeout: .now() + 1) == .success)
        connection.stop()
        #expect(fcntl(writeFD, F_GETFD) != -1)
        release.signal()
        #expect(connection.encoder.waitForPendingWritesForTesting())
        #expect(fcntl(writeFD, F_GETFD) == -1)
    }

    @Test("retiring an unstarted connection makes its actual child exit")
    func connectionChildExits() async throws {
        let input = Pipe()
        let output = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        child.standardInput = input
        child.standardOutput = output
        let (exits, continuation) = AsyncStream<Int32>.makeStream()
        child.terminationHandler = { process in
            continuation.yield(process.terminationStatus)
            continuation.finish()
        }
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let connection = try makeConnection(output.fileHandleForReading, input.fileHandleForWriting)
        connection.stop()
        var iterator = exits.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        #expect(!child.isRunning)
    }

    @Test("abort before connection handoff observes child exit and suppresses restart")
    func abortOwnedLaunch() async throws {
        let manager = BEAMProcessManager()
        let (exits, continuation) = AsyncStream<Bool>.makeStream()
        manager.onNormalExit = {
            continuation.yield(true)
            continuation.finish()
        }
        manager.start(configuration: catConfiguration())
        #expect(manager.hasLiveProcess)
        let readFD = try #require(manager.readHandle).fileDescriptor
        let writeFD = try #require(manager.writeHandle).fileDescriptor
        manager.abortStartup()
        var iterator = exits.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(!manager.hasLiveProcess)
        #expect(manager.exitIntent == .appShutdown)
        #expect(fcntl(readFD, F_GETFD) == -1)
        #expect(fcntl(writeFD, F_GETFD) == -1)
        manager.start(configuration: catConfiguration())
        #expect(!manager.hasLiveProcess)
    }

    @Test("abort after handoff leaves closing to the connection")
    func abortAfterHandoff() async throws {
        let manager = BEAMProcessManager()
        let (exits, continuation) = AsyncStream<Bool>.makeStream()
        manager.onNormalExit = {
            continuation.yield(true)
            continuation.finish()
        }
        manager.start(configuration: catConfiguration())
        let readHandle = try #require(manager.readHandle)
        let writeHandle = try #require(manager.writeHandle)
        let readFD = readHandle.fileDescriptor
        let connection = try makeConnection(readHandle, writeHandle)
        manager.transferPipeOwnership()
        manager.abortStartup()
        #expect(fcntl(readFD, F_GETFD) != -1)
        connection.stop()
        #expect(connection.encoder.waitForPendingWritesForTesting())
        var iterator = exits.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(!manager.hasLiveProcess)
        #expect(fcntl(readFD, F_GETFD) == -1)
    }

    @Test("failed process launch releases its resources and can be aborted")
    func failedLaunch() {
        let manager = BEAMProcessManager()
        var failure: BEAMProcessManager.StartupFailure?
        var configuration = catConfiguration()
        configuration = BEAMLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/nonexistent/minga-test-child"),
            arguments: [], environment: configuration.environment,
            workingDirectoryURL: configuration.workingDirectoryURL
        )
        manager.start(configuration: configuration) { failure = $0 }
        guard case .launch = failure else {
            Issue.record("Expected a startup launch failure, got \(String(describing: failure))")
            return
        }
        #expect(!manager.hasLiveProcess)
        #expect(manager.readHandle == nil)
        #expect(manager.writeHandle == nil)
        manager.abortStartup()
        #expect(manager.exitIntent == .appShutdown)
    }

    @Test("startup retry waits for the owned core to exit before reporting a replacement launch failure")
    func retryWaitsForExit() async throws {
        try #require(!BEAMProcessManager.isBundleMode)
        let manager = BEAMProcessManager()
        defer { manager.abortStartup() }
        let (failures, report) = AsyncStream<BEAMProcessManager.StartupFailure>.makeStream()
        manager.start(configuration: catConfiguration())
        #expect(manager.hasLiveProcess)

        manager.retryStartup { report.yield($0) }
        var results = failures.makeAsyncIterator()
        #expect(await results.next() == .missingRelease)
        #expect(!manager.hasLiveProcess)
    }

    @Test("failure to connect closes the launch pipes and stops the owned child")
    func stopsUnconnectedStartup() async throws {
        let manager = BEAMProcessManager()
        defer { manager.abortStartup() }
        let (exits, exit) = AsyncStream<Int32>.makeStream()
        manager.onTermination = { status in exit.yield(status); return false }
        manager.start(configuration: catConfiguration())
        let input = try #require(manager.writeHandle)
        let output = try #require(manager.readHandle)
        let inputFD = input.fileDescriptor
        let outputFD = output.fileDescriptor

        manager.stopUnconnectedStartup()

        #expect(fcntl(inputFD, F_GETFD) == -1)
        #expect(fcntl(outputFD, F_GETFD) == -1)
        var observedExits = exits.makeAsyncIterator()
        #expect(await observedExits.next() != nil)
        #expect(!manager.hasLiveProcess)
        #expect(manager.exitIntent == .startupFailed)
    }

    @Test("startup retry times out without replacing a core that ignores termination")
    func retryTimeoutDoesNotReplaceCore() async throws {
        let manager = BEAMProcessManager()
        defer { manager.abortStartup() }
        let (failures, report) = AsyncStream<BEAMProcessManager.StartupFailure>.makeStream()
        let (exits, exit) = AsyncStream<Int32>.makeStream()
        manager.onTermination = { status in exit.yield(status); return false }
        manager.start(configuration: BEAMLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf x; IFS= read -r line"],
            environment: [:],
            workingDirectoryURL: FileManager.default.temporaryDirectory
        ))
        let input = try #require(manager.writeHandle)
        let output = try #require(manager.readHandle)
        try #require(output.read(upToCount: 1) == Data([120]))

        manager.retryStartup(stopTimeout: 0.05) { report.yield($0) }
        var results = failures.makeAsyncIterator()
        #expect(await results.next() == .previousCoreStopTimedOut)
        #expect(manager.hasLiveProcess)
        #expect(manager.writeHandle === input)

        try input.write(contentsOf: Data("\n".utf8))
        var observedExits = exits.makeAsyncIterator()
        #expect(await observedExits.next() == 0)
        #expect(!manager.hasLiveProcess)
        #expect(manager.exitIntent == .startupFailed)
    }

    @Test("an exit handled after the startup stop deadline cannot start a replacement")
    func lateExitDoesNotReplaceCore() throws {
        let manager = BEAMProcessManager()
        defer { manager.abortStartup() }
        manager.start(configuration: catConfiguration())
        let output = try #require(manager.readHandle)
        var failure: BEAMProcessManager.StartupFailure?

        // Keep the main run loop from processing the queued deadline until the termination path has run.
        manager.retryStartup(stopTimeout: 0) { failure = $0 }
        let data = try output.read(upToCount: 1)
        #expect(data == nil || data?.isEmpty == true)
        manager.handleTermination(status: SIGTERM, reason: .uncaughtSignal)

        #expect(failure == .previousCoreStopTimedOut)
        #expect(!manager.hasLiveProcess)
    }

    private func makeConnection(
        _ readHandle: FileHandle,
        _ writeHandle: FileHandle,
        encoderFactory: ProtocolConnection.EncoderFactory? = nil
    ) throws -> ProtocolConnection {
        try ProtocolConnection(
            connectionID: 1, readHandle: readHandle, writeHandle: writeHandle,
            resourcePolicy: .default, isCurrent: { _ in true }, consume: { _, _ in },
            onTransportFailure: { _ in }, onInputRejection: { _ in },
            onReaderDisconnect: { _, _ in }, encoderFactory: encoderFactory
        )
    }

    private func catConfiguration() -> BEAMLaunchConfiguration {
        BEAMLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            environment: [:], workingDirectoryURL: URL(fileURLWithPath: "/private/tmp")
        )
    }
}
