// OverlayVolume.swift
//
// FSKit filesystem implementation for Minga changesets.
//
// This is the macOS 15+ sanctioned approach to userspace filesystems.
// The volume is mounted as a real filesystem that any Unix tool can read.
// File content is served from the BEAM's in-memory changeset over a
// Unix domain socket.
//
// ## How it works
//
// 1. Minga's BEAM creates a changeset and starts a ChangesetFs.Server
//    listening on a Unix domain socket
// 2. The Swift frontend tells this FSKit extension to mount with the
//    socket path and project root as parameters
// 3. When any process reads a file from the mount point, FSKit calls
//    our lookup/read/readdir implementations
// 4. We forward the request to the BEAM over the socket
// 5. The BEAM checks: is this file modified in the changeset? If yes,
//    serve from memory. If no, read from the real project.
// 6. We return the content to FSKit, which returns it to the caller
//
// ## Integration with Minga
//
// This extension would be bundled in the Minga.app as an app extension:
//
//   Minga.app/
//     Contents/
//       Extensions/
//         ChangesetFS.appex/
//           Contents/
//             Info.plist  (FSKit extension point)
//             MacOS/
//               ChangesetFS
//
// The Info.plist declares the extension point:
//
//   <key>NSExtension</key>
//   <dict>
//     <key>NSExtensionPointIdentifier</key>
//     <string>com.apple.filesystems.fs-module</string>
//     <key>NSExtensionPrincipalClass</key>
//     <string>ChangesetFS.OverlayModule</string>
//   </dict>
//
// ## Mounting
//
// The BEAM triggers a mount via the Swift frontend:
//
//   FSClient.install(name: "changeset-abc123") { result in
//       // Volume is now mounted at /Volumes/changeset-abc123
//       // or a user-specified mount point
//   }
//
// All processes see the mount as a regular filesystem.

import Foundation

// ─── Protocol Client ────────────────────────────────────────────────

/// Communicates with the BEAM's ChangesetFs.Server over a Unix domain socket.
/// Each request is a length-prefixed binary message matching the protocol
/// defined in ChangesetFs.Protocol (Elixir side).
final class BEAMClient {
    private let socket: Int32
    
    init(socketPath: String) throws {
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw FSError.connectionFailed
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let bound = pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    strlcpy(dest, ptr, 104)
                }
                _ = bound
            }
        }
        
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard result == 0 else {
            close(socket)
            throw FSError.connectionFailed
        }
    }
    
    deinit {
        close(socket)
    }
    
    /// Sends a request and reads the response.
    func request(_ data: Data) throws -> Data {
        // Write length prefix (4 bytes big-endian) + payload
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        
        try send(header)
        try send(data)
        
        // Read response length
        let respHeader = try recv(4)
        let respLength = respHeader.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // Read response payload
        return try recv(Int(respLength))
    }
    
    private func send(_ data: Data) throws {
        try data.withUnsafeBytes { ptr in
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(socket, ptr.baseAddress! + sent, data.count - sent, 0)
                guard n > 0 else { throw FSError.sendFailed }
                sent += n
            }
        }
    }
    
    private func recv(_ count: Int) throws -> Data {
        var buffer = Data(count: count)
        var received = 0
        while received < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                Darwin.recv(socket, ptr.baseAddress! + received, count - received, 0)
            }
            guard n > 0 else { throw FSError.recvFailed }
            received += n
        }
        return buffer
    }
}

// ─── Protocol Encoding (matches ChangesetFs.Protocol in Elixir) ─────

enum FSRequest {
    static func lookup(parent: String, name: String) -> Data {
        var data = Data([0x01])
        data.append(encodeString(parent))
        data.append(encodeString(name))
        return data
    }
    
    static func read(path: String, offset: UInt32, count: UInt32) -> Data {
        var data = Data([0x02])
        data.append(encodeString(path))
        data.append(uint32(offset))
        data.append(uint32(count))
        return data
    }
    
    static func readdir(path: String) -> Data {
        var data = Data([0x03])
        data.append(encodeString(path))
        return data
    }
    
    static func getattr(path: String) -> Data {
        var data = Data([0x04])
        data.append(encodeString(path))
        return data
    }
    
    private static func encodeString(_ s: String) -> Data {
        let bytes = Data(s.utf8)
        var data = Data()
        data.append(uint16(UInt16(bytes.count)))
        data.append(bytes)
        return data
    }
    
    private static func uint16(_ v: UInt16) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 2)
    }
    
    private static func uint32(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }
}

// ─── FSKit Integration Points ───────────────────────────────────────
//
// The actual FSKit code requires importing FSKit framework and
// implementing these protocols. Shown here as the integration spec.
//
// @available(macOS 15.0, *)
// final class OverlayModule: FSModule {
//     func makeVolume(name: String, options: FSVolumeOptions) async throws -> OverlayVolumeImpl {
//         let socketPath = options.string(forKey: "socketPath")!
//         let projectRoot = options.string(forKey: "projectRoot")!
//         let client = try BEAMClient(socketPath: socketPath)
//         return OverlayVolumeImpl(client: client, projectRoot: projectRoot)
//     }
// }
//
// @available(macOS 15.0, *)
// final class OverlayVolumeImpl: FSVolume {
//     let client: BEAMClient
//     let projectRoot: String
//
//     // FSKit calls this when any process does stat() on a file
//     func getattr(_ item: FSItem) async throws -> FSItemAttributes {
//         let response = try client.request(FSRequest.getattr(path: item.path))
//         // decode response into FSItemAttributes
//     }
//
//     // FSKit calls this when any process does open() + read()
//     func read(_ item: FSItem, offset: UInt64, count: UInt32) async throws -> Data {
//         let response = try client.request(FSRequest.read(
//             path: item.path, offset: UInt32(offset), count: count))
//         // decode response, return file data
//     }
//
//     // FSKit calls this when any process does readdir()
//     func readdir(_ item: FSItem, offset: UInt64, count: UInt32) async throws -> [FSDirectoryEntry] {
//         let response = try client.request(FSRequest.readdir(path: item.path))
//         // decode response into directory entries
//     }
//
//     // FSKit calls this when any process does lookup (path resolution)
//     func lookup(name: FSFileName, in directory: FSItem) async throws -> FSItem {
//         let response = try client.request(FSRequest.lookup(
//             parent: directory.path, name: name.string))
//         // decode response, return FSItem
//     }
// }

enum FSError: Error {
    case connectionFailed
    case sendFailed
    case recvFailed
}
