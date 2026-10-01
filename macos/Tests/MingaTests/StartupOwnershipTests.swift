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
        var crashed = false
        manager.onCrash = { crashed = true }
        var configuration = catConfiguration()
        configuration = BEAMLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/nonexistent/minga-test-child"),
            arguments: [], environment: configuration.environment,
            workingDirectoryURL: configuration.workingDirectoryURL
        )
        manager.start(configuration: configuration)
        #expect(crashed)
        #expect(!manager.hasLiveProcess)
        #expect(manager.readHandle == nil)
        #expect(manager.writeHandle == nil)
        manager.abortStartup()
        #expect(manager.exitIntent == .appShutdown)
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
