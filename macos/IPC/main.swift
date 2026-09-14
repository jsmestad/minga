import Darwin
import Foundation

private let version = 1
private let maximumFrame = 65_536
private let startupTimeoutNanoseconds: UInt64 = 15_000_000_000
private let endpointTransientExit: Int32 = 3
private let endpointInsecureExit: Int32 = 4
private let preAcceptanceEndpointLossExit: Int32 = 5

private struct Descriptor: Decodable {
    let version: Int
    let appInstanceID: String
    let coreInstanceID: String
    let appPID: Int32
    let launchNonce: String?
    let socketPath: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case version
        case appInstanceID = "app_instance_id"
        case coreInstanceID = "core_instance_id"
        case appPID = "app_pid"
        case launchNonce = "launch_nonce"
        case socketPath = "socket_path"
        case token
    }
}

private enum IPCError: Error, CustomStringConvertible {
    case transient(String)
    case endpointDisconnected(String)
    case insecure(String)
    case operational(String)
    case launchConflict(String)
    case endpointLostBeforeAcceptance(String)
    case appExited(String)

    var description: String {
        switch self {
        case .transient(let message), .endpointDisconnected(let message),
             .insecure(let message), .operational(let message),
             .launchConflict(let message), .endpointLostBeforeAcceptance(let message),
             .appExited(let message):
            message
        }
    }

    var probeStatus: Int32 {
        switch self {
        case .transient, .endpointDisconnected, .endpointLostBeforeAcceptance: endpointTransientExit
        case .insecure: endpointInsecureExit
        case .operational, .launchConflict, .appExited: 1
        }
    }
}

private struct MonotonicDeadline {
    let uptimeNanoseconds: UInt64

    static func after(nanoseconds: UInt64) -> MonotonicDeadline {
        MonotonicDeadline(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds &+ nanoseconds)
    }

    func remainingTimespec() throws -> timespec {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < uptimeNanoseconds else {
            throw IPCError.transient("Minga.app did not publish its IPC endpoint within 15 seconds")
        }
        let remaining = uptimeNanoseconds - now
        return timespec(
            tv_sec: Int(remaining / 1_000_000_000),
            tv_nsec: Int(remaining % 1_000_000_000)
        )
    }

    func remainingPollMilliseconds() throws -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < uptimeNanoseconds else {
            throw IPCError.transient("Minga.app did not accept the request within 15 seconds")
        }
        let remaining = uptimeNanoseconds - now
        return Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
    }
}

private func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("minga: \(message)\n".utf8))
    exit(status)
}

private func permissions(_ mode: mode_t) -> mode_t { mode & 0o777 }

private func runtimeParentDirectory() -> String {
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    guard length > 1 else { fail("cannot discover Darwin's per-user temporary directory") }

    var buffer = [CChar](repeating: 0, count: length)
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) == length else {
        fail("cannot read Darwin's per-user temporary directory")
    }

    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
}

private func runtimeDirectory() -> String {
    URL(fileURLWithPath: runtimeParentDirectory(), isDirectory: true)
        .appendingPathComponent("com.minga.editor", isDirectory: true).path
}

private func descriptorPath() -> String { runtimeDirectory() + "/current.json" }

private func validateDirectory(_ path: String, exactMode: mode_t?) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
        if errno == ENOENT { throw IPCError.transient("no authenticated app endpoint") }
        throw IPCError.operational("cannot inspect IPC directory")
    }
    let modeIsSafe = exactMode.map { permissions(info.st_mode) == $0 }
        ?? ((permissions(info.st_mode) & 0o077) == 0)
    guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), modeIsSafe else {
        throw IPCError.insecure("insecure IPC directory: \(path)")
    }
}

private func validateRuntimeDirectory() throws {
    try validateDirectory(runtimeParentDirectory(), exactMode: nil)
    try validateDirectory(runtimeDirectory(), exactMode: 0o700)

    let expected = URL(fileURLWithPath: runtimeParentDirectory(), isDirectory: true)
        .appendingPathComponent("com.minga.editor", isDirectory: true).standardizedFileURL.path
    guard URL(fileURLWithPath: runtimeDirectory()).standardizedFileURL.path == expected else {
        throw IPCError.insecure("IPC runtime directory escapes Darwin's per-user temporary directory")
    }
}

private func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
}

private func processIsAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

private func loadDescriptor() throws -> Descriptor {
    try validateRuntimeDirectory()

    var info = stat()
    guard lstat(descriptorPath(), &info) == 0 else {
        if errno == ENOENT { throw IPCError.transient("no authenticated app endpoint") }
        throw IPCError.operational("cannot inspect IPC descriptor")
    }
    guard (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == geteuid(),
          permissions(info.st_mode) == 0o600
    else { throw IPCError.insecure("insecure IPC descriptor") }

    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: descriptorPath()), options: .mappedIfSafe)
    } catch {
        throw IPCError.transient("IPC descriptor changed while being read")
    }

    let descriptor: Descriptor
    do {
        descriptor = try JSONDecoder().decode(Descriptor.self, from: data)
    } catch {
        throw IPCError.insecure("invalid IPC descriptor")
    }

    guard descriptor.version == version,
          descriptor.appPID > 1,
          !descriptor.appInstanceID.isEmpty,
          decodeBase64URL(descriptor.coreInstanceID)?.count == 16,
          decodeBase64URL(descriptor.token)?.count == 32
    else { throw IPCError.insecure("invalid IPC descriptor identity") }

    let expectedParent = URL(fileURLWithPath: runtimeDirectory()).standardizedFileURL.path
    let socketURL = URL(fileURLWithPath: descriptor.socketPath).standardizedFileURL
    guard socketURL.deletingLastPathComponent().path == expectedParent else {
        throw IPCError.insecure("IPC socket escapes its private runtime directory")
    }

    var socketInfo = stat()
    guard lstat(socketURL.path, &socketInfo) == 0 else {
        if errno == ENOENT { throw IPCError.transient("stale IPC descriptor") }
        throw IPCError.operational("cannot inspect IPC socket")
    }
    guard (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
          socketInfo.st_uid == geteuid(),
          permissions(socketInfo.st_mode) == 0o600
    else { throw IPCError.insecure("insecure IPC socket") }

    guard processIsAlive(descriptor.appPID) else {
        throw IPCError.endpointLostBeforeAcceptance("Minga.app exited before accepting the request")
    }
    return descriptor
}

private final class VnodeWatcher {
    private let queue: Int32
    private let appPID: Int32?
    private var descriptors: [Int32] = []

    init(appPID: Int32? = nil) throws {
        self.appPID = appPID
        queue = kqueue()
        guard queue >= 0 else { throw IPCError.operational("cannot create startup event queue") }

        do {
            try add(path: runtimeParentDirectory())
            if FileManager.default.fileExists(atPath: runtimeDirectory()) {
                try add(path: runtimeDirectory())
            }
            if let appPID { try addProcess(appPID) }
        } catch {
            close(queue)
            throw error
        }
    }

    deinit {
        for descriptor in descriptors { close(descriptor) }
        close(queue)
    }

    private func add(path: String) throws {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw IPCError.operational("cannot watch for Minga.app startup") }
        descriptors.append(descriptor)

        var change = kevent(
            ident: UInt(descriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME | NOTE_DELETE),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            throw IPCError.operational("cannot register startup directory watch")
        }
    }

    private func addProcess(_ pid: Int32) throws {
        var change = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            throw IPCError.endpointLostBeforeAcceptance("Minga.app exited before accepting the request")
        }
    }

    func wait(until deadline: MonotonicDeadline) throws {
        while true {
            var event = kevent()
            var timeout = try deadline.remainingTimespec()
            let count = kevent(queue, nil, 0, &event, 1, &timeout)
            if count == 0 { throw IPCError.transient("Minga.app did not publish its IPC endpoint within 15 seconds") }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw IPCError.operational("IPC startup watch failed") }
            if event.filter == Int16(EVFILT_PROC), let appPID, event.ident == UInt(appPID) {
                throw IPCError.endpointLostBeforeAcceptance("Minga.app exited before accepting the request")
            }
            return
        }
    }
}

private func waitForDescriptor(
    expectedNonce: String?,
    allowLaunchConflict: Bool,
    deadline: MonotonicDeadline
) throws -> (Descriptor, String?) {
    while true {
        // Establish watches before inspection so publication cannot land in a
        // check/open gap. Parent watches cover runtime-directory replacement;
        // the child watch covers atomic descriptor publication.
        let watcher = try VnodeWatcher()
        do {
            let descriptor = try loadDescriptor()
            guard let expectedNonce else { return (descriptor, nil) }
            if descriptor.launchNonce == expectedNonce { return (descriptor, expectedNonce) }
            if allowLaunchConflict { return (descriptor, nil) }
            throw IPCError.launchConflict(
                "another Minga.app instance won startup; requested startup-only flags were not applied"
            )
        } catch let error as IPCError {
            switch error {
            case .transient:
                break
            case .endpointLostBeforeAcceptance where expectedNonce != nil:
                break
            case .endpointDisconnected, .endpointLostBeforeAcceptance, .insecure, .operational,
                 .launchConflict, .appExited:
                throw error
            }
        }
        try watcher.wait(until: deadline)
    }
}

private func descriptorIdentityChanged(_ current: Descriptor, from previous: Descriptor) -> Bool {
    current.appInstanceID != previous.appInstanceID
        || current.coreInstanceID != previous.coreInstanceID
        || current.appPID != previous.appPID
        || current.socketPath != previous.socketPath
        || current.token != previous.token
}

private func waitForEndpointChange(
    from descriptor: Descriptor,
    deadline: MonotonicDeadline
) throws {
    while true {
        // Register both vnode and process watches before re-reading the
        // descriptor. This closes the check/wait race and prevents a valid but
        // refusing stale socket from causing a tight reconnect loop.
        let watcher = try VnodeWatcher(appPID: descriptor.appPID)
        do {
            let current = try loadDescriptor()
            if descriptorIdentityChanged(current, from: descriptor) { return }
        } catch let error as IPCError {
            switch error {
            case .transient:
                break
            case .endpointDisconnected, .endpointLostBeforeAcceptance, .insecure, .operational,
                 .launchConflict, .appExited:
                throw error
            }
        }
        try watcher.wait(until: deadline)
    }
}

private func connect(to path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IPCError.operational("cannot create IPC socket") }

    var noSignal: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
        close(fd)
        throw IPCError.operational("cannot configure IPC socket")
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else {
        close(fd)
        throw IPCError.insecure("IPC socket path is too long")
    }

    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
    }

    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
    }
    guard result == 0 else {
        let saved = errno
        close(fd)
        if saved == ENOENT || saved == ECONNREFUSED {
            throw IPCError.transient("stale IPC endpoint")
        }
        throw IPCError.operational("cannot connect to authenticated app endpoint (errno \(saved))")
    }
    return fd
}

private final class AppExitMonitor {
    private let queue: Int32
    private let appPID: Int32

    init(appPID: Int32) throws {
        self.appPID = appPID
        queue = kqueue()
        guard queue >= 0 else { throw IPCError.operational("cannot monitor Minga.app") }

        var change = kevent(
            ident: UInt(appPID),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            close(queue)
            throw IPCError.appExited("Minga.app process exited")
        }
    }

    deinit { close(queue) }

    private func socketHasBufferedData(_ fd: Int32) throws -> Bool {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count > 0 { return true }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return false }
            if errno == EINTR { continue }
            throw IPCError.operational("cannot inspect buffered IPC response")
        }
    }

    func waitForSocket(_ fd: Int32, deadline: MonotonicDeadline?) throws {
        var socketChange = kevent(
            ident: UInt(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: 0, data: 0, udata: nil
        )
        guard kevent(queue, &socketChange, 1, nil, 0, nil) == 0 else {
            throw IPCError.operational("cannot monitor IPC socket")
        }

        while true {
            var event = kevent()
            var timeout = try deadline?.remainingTimespec() ?? timespec(tv_sec: 3600, tv_nsec: 0)
            let count = kevent(queue, nil, 0, &event, 1, &timeout)
            if count == 0 {
                if deadline != nil { throw IPCError.transient("Minga.app did not accept the request within 15 seconds") }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw IPCError.operational("IPC process monitor failed") }
            if event.filter == Int16(EVFILT_PROC), event.ident == UInt(appPID) {
                // NOTE_EXIT and EVFILT_READ can become ready in the same turn.
                // Prefer bytes already queued by the server so a complete
                // terminal frame is not discarded merely because kqueue chose
                // the process event first.
                if try socketHasBufferedData(fd) { return }
                throw IPCError.appExited("Minga.app exited before the edit completed")
            }
            if event.filter == Int16(EVFILT_READ), event.ident == UInt(fd) { return }
        }
    }
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw IPCError.endpointDisconnected("IPC connection closed before request acceptance")
            }
            offset += count
        }
    }
}

private func readExact(
    _ fd: Int32,
    count: Int,
    deadline: MonotonicDeadline?,
    appMonitor: AppExitMonitor?
) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        if let appMonitor {
            try appMonitor.waitForSocket(fd, deadline: deadline)
        } else if let deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&descriptor, 1, try deadline.remainingPollMilliseconds())
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw IPCError.transient("Minga.app did not accept the request within 15 seconds") }
        }

        let readCount = data.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
        }
        if readCount < 0 && errno == EINTR { continue }
        guard readCount > 0 else { throw IPCError.endpointDisconnected("IPC endpoint disconnected before completion") }
        offset += readCount
    }
    return data
}

private func sendJSON(_ fd: Int32, _ object: [String: Any]) throws {
    let payload = try JSONSerialization.data(withJSONObject: object)
    guard payload.count <= maximumFrame else { throw IPCError.operational("IPC request exceeds 64 KiB") }
    var length = UInt32(payload.count).bigEndian
    try writeAll(fd, Data(bytes: &length, count: 4))
    try writeAll(fd, payload)
}

private func receiveJSON(
    _ fd: Int32,
    deadline: MonotonicDeadline?,
    appMonitor: AppExitMonitor? = nil
) throws -> [String: Any] {
    let prefix = try readExact(fd, count: 4, deadline: deadline, appMonitor: appMonitor)
    let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length <= maximumFrame else { throw IPCError.insecure("IPC response exceeds 64 KiB") }
    let payload = try readExact(fd, count: Int(length), deadline: deadline, appMonitor: appMonitor)
    guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
        throw IPCError.insecure("invalid IPC response")
    }
    return object
}

private func authenticatedConnection(_ descriptor: Descriptor, expectedNonce: String?) throws -> Int32 {
    let fd = try connect(to: descriptor.socketPath)
    do {
        try sendJSON(fd, [
            "version": version,
            "type": "hello",
            "app_instance_id": descriptor.appInstanceID,
            "core_instance_id": descriptor.coreInstanceID,
            "token": descriptor.token,
            "expected_launch_nonce": expectedNonce ?? NSNull()
        ])
        return fd
    } catch {
        close(fd)
        throw error
    }
}

private func connectionForRequest(
    expectedNonce: String?,
    allowLaunchConflict: Bool,
    deadline: MonotonicDeadline
) throws -> (Descriptor, Int32) {
    while true {
        let (descriptor, authenticatedNonce) = try waitForDescriptor(
            expectedNonce: expectedNonce,
            allowLaunchConflict: allowLaunchConflict,
            deadline: deadline
        )
        do {
            return (
                descriptor,
                try authenticatedConnection(descriptor, expectedNonce: authenticatedNonce)
            )
        } catch let error as IPCError {
            switch error {
            case .transient, .endpointDisconnected:
                try waitForEndpointChange(from: descriptor, deadline: deadline)
            case .endpointLostBeforeAcceptance, .insecure, .operational, .launchConflict, .appExited:
                throw error
            }
        }
    }
}

private func probe(expectedNonce: String?, allowLaunchConflict: Bool) throws {
    let deadline = MonotonicDeadline.after(nanoseconds: startupTimeoutNanoseconds)
    let connection: (Descriptor, Int32)
    if expectedNonce == nil {
        let descriptor = try loadDescriptor()
        connection = (descriptor, try authenticatedConnection(descriptor, expectedNonce: nil))
    } else {
        connection = try connectionForRequest(
            expectedNonce: expectedNonce,
            allowLaunchConflict: allowLaunchConflict,
            deadline: deadline
        )
    }
    let (descriptor, fd) = connection
    defer { close(fd) }
    try sendJSON(fd, ["version": version, "type": "probe"])
    let response = try receiveJSON(fd, deadline: deadline)
    guard response["type"] as? String == "ready",
          response["app_instance_id"] as? String == descriptor.appInstanceID,
          response["core_instance_id"] as? String == descriptor.coreInstanceID,
          response["app_pid"] as? Int == Int(descriptor.appPID)
    else { throw IPCError.insecure("endpoint probe identity mismatch") }
}

private func open(
    paths: [String],
    editorMode: Bool,
    expectedNonce: String?,
    allowLaunchConflict: Bool
) throws -> Int32 {
    let deadline = MonotonicDeadline.after(nanoseconds: startupTimeoutNanoseconds)

    while true {
        var fd: Int32 = -1
        var attemptedDescriptor: Descriptor?
        do {
            let (descriptor, connectedFD) = try connectionForRequest(
                expectedNonce: expectedNonce,
                allowLaunchConflict: allowLaunchConflict,
                deadline: deadline
            )
            attemptedDescriptor = descriptor
            fd = connectedFD
            let monitor = try AppExitMonitor(appPID: descriptor.appPID)
            try sendJSON(fd, ["version": version, "type": "open", "paths": paths, "editor": editorMode])
            let response = try receiveJSON(fd, deadline: deadline, appMonitor: monitor)
            guard response["type"] as? String == "completed" else {
                throw IPCError.insecure("invalid open completion")
            }
            let status = completionStatus(response)
            close(fd)
            return status
        } catch let error as IPCError {
            if fd >= 0 { close(fd) }
            switch error {
            case .transient:
                if let attemptedDescriptor {
                    try waitForEndpointChange(from: attemptedDescriptor, deadline: deadline)
                } else {
                    _ = try deadline.remainingTimespec()
                }
            case .endpointDisconnected:
                throw IPCError.endpointLostBeforeAcceptance(
                    "Minga.app endpoint disconnected before accepting the open request"
                )
            case .appExited:
                throw IPCError.endpointLostBeforeAcceptance(
                    "Minga.app exited before accepting the open request"
                )
            case .endpointLostBeforeAcceptance, .insecure, .operational, .launchConflict:
                throw error
            }
        }
    }
}

private func beginWait(
    path: String,
    editorMode: Bool,
    expectedNonce: String?,
    allowLaunchConflict: Bool,
    deadline: MonotonicDeadline
) throws -> (Descriptor, Int32, AppExitMonitor, [String: Any]) {
    while true {
        var fd: Int32 = -1
        var attemptedDescriptor: Descriptor?
        do {
            let (descriptor, connectedFD) = try connectionForRequest(
                expectedNonce: expectedNonce,
                allowLaunchConflict: allowLaunchConflict,
                deadline: deadline
            )
            attemptedDescriptor = descriptor
            fd = connectedFD
            let monitor = try AppExitMonitor(appPID: descriptor.appPID)
            try sendJSON(fd, ["version": version, "type": "open_wait", "path": path, "editor": editorMode])
            let first = try receiveJSON(fd, deadline: deadline, appMonitor: monitor)
            return (descriptor, fd, monitor, first)
        } catch let error as IPCError {
            if fd >= 0 { close(fd) }
            switch error {
            case .transient:
                if let attemptedDescriptor {
                    try waitForEndpointChange(from: attemptedDescriptor, deadline: deadline)
                } else {
                    _ = try deadline.remainingTimespec()
                }
            case .endpointDisconnected:
                throw IPCError.endpointLostBeforeAcceptance(
                    "Minga.app endpoint disconnected before accepting the wait request"
                )
            case .appExited:
                throw IPCError.endpointLostBeforeAcceptance(
                    "Minga.app exited before accepting the wait request"
                )
            case .endpointLostBeforeAcceptance, .insecure, .operational, .launchConflict:
                throw error
            }
        }
    }
}

private func wait(
    path: String,
    editorMode: Bool,
    expectedNonce: String?,
    allowLaunchConflict: Bool
) throws -> Int32 {
    let deadline = MonotonicDeadline.after(nanoseconds: startupTimeoutNanoseconds)
    let (descriptor, fd, monitor, first) = try beginWait(
        path: path,
        editorMode: editorMode,
        expectedNonce: expectedNonce,
        allowLaunchConflict: allowLaunchConflict,
        deadline: deadline
    )
    defer { close(fd) }
    if first["type"] as? String == "completed" {
        guard let requestID = first["request_id"] as? String else {
            throw IPCError.insecure("wait completion omitted request identity")
        }
        try sendJSON(fd, ["version": version, "type": "completion_ack", "request_id": requestID])
        return completionStatus(first)
    }
    guard first["type"] as? String == "accepted",
          let requestID = first["request_id"] as? String,
          first["app_instance_id"] as? String == descriptor.appInstanceID,
          first["core_instance_id"] as? String == descriptor.coreInstanceID,
          first["app_pid"] as? Int == Int(descriptor.appPID)
    else { throw IPCError.insecure("invalid wait acceptance identity") }

    let terminal = try receiveJSON(fd, deadline: nil, appMonitor: monitor)
    guard terminal["type"] as? String == "completed",
          terminal["request_id"] as? String == requestID
    else { throw IPCError.insecure("invalid wait completion") }

    // The server keeps the VM alive during orderly shutdown until this ack is
    // observed, so a delivered completion cannot be truncated by VM teardown.
    try sendJSON(fd, ["version": version, "type": "completion_ack", "request_id": requestID])
    return completionStatus(terminal)
}

private func completionStatus(_ response: [String: Any]) -> Int32 {
    let code = (response["exit_code"] as? Int) ?? 1
    if code != 0, let message = response["message"] as? String, !message.isEmpty {
        FileHandle.standardError.write(Data("minga: \(message)\n".utf8))
    }
    return code == 0 ? 0 : 1
}

private func printJSON(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func receiptStatus(_ response: [String: Any]) -> Int32 {
    guard let receipt = response["receipt"] as? [String: Any] else { return 1 }
    let outcome = receipt["outcome"] as? String
    return outcome == "ready" || outcome == "applied" ? 0 : 1
}

private func semanticRequest(
    object: [String: Any], waitsForReceipt: Bool, deadlineMilliseconds: Int = 15_000
) throws -> Int32 {
    let descriptor = try loadDescriptor()
    let fd = try authenticatedConnection(descriptor, expectedNonce: nil)
    defer { close(fd) }
    let monitor = try AppExitMonitor(appPID: descriptor.appPID)
    try sendJSON(fd, object)
    let deadline = MonotonicDeadline.after(
        nanoseconds: UInt64(deadlineMilliseconds + 1_000) * 1_000_000
    )
    let first = try receiveJSON(fd, deadline: deadline, appMonitor: monitor)
    if !waitsForReceipt {
        try printJSON(first)
        return first["type"] as? String == "error" ? 1 : 0
    }
    guard first["type"] as? String == "accepted",
          let acceptedReceipt = first["receipt"] as? [String: Any]
    else {
        try printJSON(first)
        return 1
    }
    do {
        var terminal = try receiveJSON(fd, deadline: deadline, appMonitor: monitor)
        if terminal["type"] as? String == "progress" {
            terminal = try receiveJSON(fd, deadline: deadline, appMonitor: monitor)
        }
        if terminal["receipt"] == nil { terminal["receipt"] = acceptedReceipt }
        try printJSON(terminal)
        return receiptStatus(terminal)
    } catch {
        return try printPostAdmissionFailure(error: error, receipt: acceptedReceipt)
    }
}

private func optionValues(_ args: [String]) throws -> [String: String] {
    var values: [String: String] = [:]
    var index = 1
    while index < args.count {
        let argument = args[index]
        guard argument.hasPrefix("--") else {
            throw IPCError.operational("invalid semantic argument: \(argument)")
        }
        let body = String(argument.dropFirst(2))
        if let equals = body.firstIndex(of: "=") {
            let name = String(body[..<equals])
            guard values[name] == nil else {
                throw IPCError.operational("duplicate semantic option: --\(name)")
            }
            values[name] = String(body[body.index(after: equals)...])
            index += 1
        } else {
            guard index + 1 < args.count else {
                throw IPCError.operational("missing value for --\(body)")
            }
            guard values[body] == nil else {
                throw IPCError.operational("duplicate semantic option: --\(body)")
            }
            values[body] = args[index + 1]
            index += 2
        }
    }
    return values
}

private func requiredOption(_ values: [String: String], _ name: String) throws -> String {
    guard let value = values[name], !value.isEmpty else {
        throw IPCError.operational("semantic command requires --\(name)")
    }
    return value
}

private func positiveIntegerOption(_ values: [String: String], _ name: String) throws -> Int {
    guard let value = try integerOption(values, name), value > 0 else {
        throw IPCError.operational("--\(name) must be a positive integer")
    }
    return value
}

private func validateOptions(_ values: [String: String], allowed: Set<String>) throws {
    if let unknown = values.keys.first(where: { !allowed.contains($0) }) {
        throw IPCError.operational("unknown semantic option: --\(unknown)")
    }
}

private func integerOption(
    _ values: [String: String], _ name: String, required: Bool = true
) throws -> Int? {
    guard let encoded = values[name] else {
        if required { throw IPCError.operational("semantic command requires --\(name)") }
        return nil
    }
    guard let value = Int(encoded), value >= 0 else {
        throw IPCError.operational("--\(name) must be a non-negative integer")
    }
    return value
}

private func semanticCommand(_ args: [String], command: String) throws -> Int32 {
    let values = try optionValues(args)
    if command == "capabilities" {
        guard values.isEmpty else { throw IPCError.operational("capabilities does not accept arguments") }
        return try semanticRequest(
            object: ["version": version, "type": "capabilities"], waitsForReceipt: false
        )
    }
    if command == "inspect" {
        try validateOptions(values, allowed: ["continuation", "choice-limit"])
        var request: [String: Any] = ["version": version, "type": "inspect"]
        if let continuation = values["continuation"] { request["continuation"] = continuation }
        if let limit = try integerOption(values, "choice-limit", required: false) {
            guard limit > 0, limit <= 25 else {
                throw IPCError.operational("--choice-limit must be between 1 and 25")
            }
            request["choice_limit"] = limit
        }
        return try semanticRequest(object: request, waitsForReceipt: false)
    }

    let commonOptions: Set<String> = [
        "app-instance-id", "core-instance-id", "target-token", "deadline-ms",
    ]
    let commandOptions: Set<String>
    switch command {
    case "select-tab":
        commandOptions = ["tab-id"]
    case "focus-pane":
        commandOptions = ["tab-id", "pane-id"]
    case "goto-location":
        commandOptions = ["tab-id", "pane-id", "buffer-id", "buffer-revision", "line", "column"]
    case "activate-picker-choice":
        commandOptions = ["picker-generation", "activation-id", "choice-kind"]
    default:
        throw IPCError.operational("unknown semantic command")
    }
    try validateOptions(values, allowed: commonOptions.union(commandOptions))

    var request: [String: Any] = [
        "version": version,
        "type": command.replacingOccurrences(of: "-", with: "_"),
        "app_instance_id": try requiredOption(values, "app-instance-id"),
        "core_instance_id": try requiredOption(values, "core-instance-id"),
        "target_token": try requiredOption(values, "target-token"),
    ]
    switch command {
    case "select-tab":
        request["tab_id"] = try positiveIntegerOption(values, "tab-id")
    case "focus-pane":
        request["tab_id"] = try positiveIntegerOption(values, "tab-id")
        request["pane_id"] = try positiveIntegerOption(values, "pane-id")
    case "goto-location":
        request["tab_id"] = try positiveIntegerOption(values, "tab-id")
        request["pane_id"] = try positiveIntegerOption(values, "pane-id")
        request["buffer_id"] = try requiredOption(values, "buffer-id")
        request["buffer_revision"] = try integerOption(values, "buffer-revision")!
        request["line"] = try positiveIntegerOption(values, "line")
        request["column"] = try integerOption(values, "column")!
    case "activate-picker-choice":
        request["picker_generation"] = try positiveIntegerOption(values, "picker-generation")
        request["activation_id"] = try positiveIntegerOption(values, "activation-id")
        let choiceKind = try requiredOption(values, "choice-kind")
        guard choiceKind == "item" || choiceKind == "action" else {
            throw IPCError.operational("--choice-kind must be item or action")
        }
        request["choice_kind"] = choiceKind
    default:
        throw IPCError.operational("unknown semantic command")
    }
    let deadline = try integerOption(values, "deadline-ms", required: false) ?? 15_000
    guard deadline > 0, deadline <= 30_000 else {
        throw IPCError.operational("--deadline-ms must be between 1 and 30000")
    }
    request["deadline_ms"] = deadline
    return try semanticRequest(object: request, waitsForReceipt: true, deadlineMilliseconds: deadline)
}

private func postAdmissionResult(error: Error, receipt: [String: Any]) -> String {
    let acceptedAppID = receipt["app_instance_id"] as? String
    let acceptedCoreID = receipt["core_instance_id"] as? String
    if let current = try? loadDescriptor() {
        if current.appInstanceID != acceptedAppID { return "app_replaced" }
        if current.coreInstanceID != acceptedCoreID { return "core_replaced" }
    }
    if case IPCError.appExited = error { return "app_replaced" }
    if case IPCError.transient = error { return "timeout" }
    return "indeterminate"
}

private func printPostAdmissionFailure(error: Error, receipt: [String: Any]) throws -> Int32 {
    try printJSON([
        "version": version,
        "type": "operation_result",
        "result": postAdmissionResult(error: error, receipt: receipt),
        "receipt": receipt,
    ])
    return (error as? IPCError)?.probeStatus ?? 1
}

private func openReady(
    path: String,
    editorMode: Bool,
    expectedNonce: String?,
    allowLaunchConflict: Bool,
    deadlineMilliseconds: Int
) throws -> Int32 {
    let startupDeadline = MonotonicDeadline.after(nanoseconds: startupTimeoutNanoseconds)
    let (descriptor, fd) = try connectionForRequest(
        expectedNonce: expectedNonce,
        allowLaunchConflict: allowLaunchConflict,
        deadline: startupDeadline
    )
    defer { close(fd) }
    let monitor = try AppExitMonitor(appPID: descriptor.appPID)
    try sendJSON(fd, [
        "version": version,
        "type": "open_ready",
        "path": path,
        "editor": editorMode,
        "deadline_ms": deadlineMilliseconds,
    ])
    let receiptDeadline = MonotonicDeadline.after(
        nanoseconds: UInt64(deadlineMilliseconds + 1_000) * 1_000_000
    )
    let accepted = try receiveJSON(fd, deadline: receiptDeadline, appMonitor: monitor)
    guard accepted["type"] as? String == "accepted",
          let acceptedReceipt = accepted["receipt"] as? [String: Any]
    else { throw IPCError.insecure("invalid operation receipt acceptance") }

    do {
        var response = try receiveJSON(fd, deadline: receiptDeadline, appMonitor: monitor)
        if response["type"] as? String == "progress" {
            response = try receiveJSON(fd, deadline: receiptDeadline, appMonitor: monitor)
        }
        guard response["type"] as? String == "completed" || response["type"] as? String == "operation_result" else {
            throw IPCError.insecure("invalid operation receipt completion")
        }
        if response["receipt"] == nil { response["receipt"] = acceptedReceipt }
        try printJSON(response)
        return receiptStatus(response)
    } catch {
        return try printPostAdmissionFailure(error: error, receipt: acceptedReceipt)
    }
}

private func observeReceipt(
    commandType: String,
    appInstanceID: String,
    coreInstanceID: String,
    operationID: String,
    deadlineMilliseconds: Int
) throws -> Int32 {
    let descriptor = try loadDescriptor()
    let fd = try authenticatedConnection(descriptor, expectedNonce: nil)
    defer { close(fd) }
    let monitor = try AppExitMonitor(appPID: descriptor.appPID)
    try sendJSON(fd, [
        "version": version,
        "type": commandType,
        "app_instance_id": appInstanceID,
        "core_instance_id": coreInstanceID,
        "operation_id": operationID,
        "deadline_ms": deadlineMilliseconds,
    ])
    let deadline = MonotonicDeadline.after(
        nanoseconds: UInt64(deadlineMilliseconds + 1_000) * 1_000_000
    )
    let response = try receiveJSON(fd, deadline: deadline, appMonitor: monitor)
    try printJSON(response)
    return receiptStatus(response)
}

private struct ReceiptArguments {
    let appInstanceID: String
    let coreInstanceID: String
    let operationID: String
    let deadlineMilliseconds: Int
}

private func parseReceiptArguments(_ args: [String]) throws -> ReceiptArguments {
    var appInstanceID: String?
    var coreInstanceID: String?
    var operationID: String?
    var deadlineMilliseconds = 15_000
    var index = 1
    while index < args.count {
        switch args[index] {
        case "--app-instance-id" where index + 1 < args.count:
            appInstanceID = args[index + 1]
            index += 2
        case "--core-instance-id" where index + 1 < args.count:
            coreInstanceID = args[index + 1]
            index += 2
        case "--operation-id" where index + 1 < args.count:
            operationID = args[index + 1]
            index += 2
        case "--deadline-ms" where index + 1 < args.count:
            guard let value = Int(args[index + 1]), value > 0, value <= 30_000 else {
                throw IPCError.operational("--deadline-ms must be between 1 and 30000")
            }
            deadlineMilliseconds = value
            index += 2
        default:
            throw IPCError.operational("invalid receipt argument: \(args[index])")
        }
    }
    guard let appInstanceID, let coreInstanceID, let operationID else {
        throw IPCError.operational("receipt commands require app, core, and operation identity")
    }
    return ReceiptArguments(
        appInstanceID: appInstanceID,
        coreInstanceID: coreInstanceID,
        operationID: operationID,
        deadlineMilliseconds: deadlineMilliseconds
    )
}

private func parseRequestArguments(
    _ args: [String], command: String
) throws -> (Bool, String?, Bool, [String]) {
    var editorMode = false
    var expectedNonce: String?
    var allowLaunchConflict = false
    var paths: [String] = []
    var index = 1
    while index < args.count {
        if args[index] == "--editor" {
            editorMode = true
            index += 1
        } else if args[index] == "--allow-launch-conflict" {
            allowLaunchConflict = true
            index += 1
        } else if args[index] == "--expected-launch-nonce", index + 1 < args.count {
            expectedNonce = args[index + 1]
            index += 2
        } else {
            paths.append(args[index])
            index += 1
        }
    }
    guard !allowLaunchConflict || expectedNonce != nil else {
        throw IPCError.operational("--allow-launch-conflict requires --expected-launch-nonce")
    }
    guard paths.allSatisfy({ $0.hasPrefix("/") }) else {
        throw IPCError.operational("\(command) requires absolute file paths")
    }
    return (editorMode, expectedNonce, allowLaunchConflict, paths)
}

private func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { fail("minga-ipc requires a command") }

    do {
        switch command {
        case "nonce":
            print(UUID().uuidString.lowercased())
            return 0
        case "probe":
            let (_, expectedNonce, allowLaunchConflict, paths) = try parseRequestArguments(
                args, command: command
            )
            guard paths.isEmpty else { throw IPCError.operational("probe does not accept file paths") }
            try probe(expectedNonce: expectedNonce, allowLaunchConflict: allowLaunchConflict)
            return 0
        case "open":
            let (editorMode, expectedNonce, allowLaunchConflict, paths) = try parseRequestArguments(
                args, command: command
            )
            guard !paths.isEmpty else {
                throw IPCError.operational("open requires at least one file path")
            }
            return try open(
                paths: paths,
                editorMode: editorMode,
                expectedNonce: expectedNonce,
                allowLaunchConflict: allowLaunchConflict
            )
        case "wait":
            let (editorMode, expectedNonce, allowLaunchConflict, paths) = try parseRequestArguments(
                args, command: command
            )
            guard paths.count == 1 else { throw IPCError.operational("wait accepts exactly one file path") }
            return try wait(
                path: paths[0],
                editorMode: editorMode,
                expectedNonce: expectedNonce,
                allowLaunchConflict: allowLaunchConflict
            )
        case "open-ready":
            let (editorMode, expectedNonce, allowLaunchConflict, paths) = try parseRequestArguments(
                args.filter { !$0.hasPrefix("--deadline-ms=") }, command: command
            )
            guard paths.count == 1 else { throw IPCError.operational("open-ready accepts exactly one file path") }
            let deadline = args.compactMap { argument -> Int? in
                guard argument.hasPrefix("--deadline-ms=") else { return nil }
                return Int(argument.dropFirst("--deadline-ms=".count))
            }.first ?? 15_000
            guard deadline > 0, deadline <= 30_000 else {
                throw IPCError.operational("--deadline-ms must be between 1 and 30000")
            }
            return try openReady(
                path: paths[0], editorMode: editorMode,
                expectedNonce: expectedNonce, allowLaunchConflict: allowLaunchConflict,
                deadlineMilliseconds: deadline
            )
        case "receipt", "wait-receipt":
            let parsed = try parseReceiptArguments(args)
            return try observeReceipt(
                commandType: command == "receipt" ? "operation_lookup" : "operation_wait",
                appInstanceID: parsed.appInstanceID, coreInstanceID: parsed.coreInstanceID,
                operationID: parsed.operationID, deadlineMilliseconds: parsed.deadlineMilliseconds
            )
        case "capabilities", "inspect", "focus-pane", "select-tab", "goto-location",
             "activate-picker-choice":
            return try semanticCommand(args, command: command)
        default:
            throw IPCError.operational("unknown minga-ipc command: \(command)")
        }
    } catch let error as IPCError {
        if command == "probe" { return error.probeStatus }
        if case .endpointLostBeforeAcceptance = error {
            fail(error.description, status: preAcceptanceEndpointLossExit)
        }
        fail(error.description, status: error.probeStatus == endpointInsecureExit ? endpointInsecureExit : 1)
    } catch {
        fail("native IPC failure: \(error)")
    }
}

exit(main())
