import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

private struct Frame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private struct ButtonObservation: Codable, Equatable, Sendable {
    let title: String?
    let titleAttribute: String
    let role: String
    let frame: Frame?
    let enabled: Bool?
    let pressCapable: Bool
    let centerHitsExactButton: Bool
    let labelWidth: Double?
}

private struct HostIdentity: Codable, Sendable {
    let pid: Int32
    let executable: String
    let bundleIdentifier: String
    let windowId: UInt32
}

private struct HostReady: Decodable {
    let schema: String
    let runId: String
    let width: Int
    let pid: Int32
    let executable: String
    let bundleIdentifier: String
    let windowId: UInt32
}

private struct Capture: Codable, Sendable {
    let filename: String
    let api: String
    let windowId: UInt32
    let hostPid: Int32
    let pointBounds: Frame
    let axWindowBounds: Frame
    let scale: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let sha256: String
    let decodedPixelWidth: Int
    let decodedPixelHeight: Int
}

private struct Observation: Encodable {
    let schema = "minga-approval-geometry-v2"
    let kind = "observation"
    let hitOracle = "system-wide-AX-hit-test"
    let runId: String
    let width: Int
    let observerPid: Int32
    let observerExecutable: String
    let host: HostIdentity
    let workspaceCount: Int
    let workspace: Frame?
    let buttons: [ButtonObservation]
    let capture: Capture
    let startedNs: String
    let finishedNs: String
}

private struct InfrastructureFailure: Encodable, Error {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = String(message.prefix(2_048))
    }
}

private struct FailureReceipt: Encodable {
    let schema = "minga-approval-geometry-v2"
    let kind = "infrastructure_error"
    let runId: String
    let width: Int
    let failure: InfrastructureFailure
    let observerPid: Int32
    let observerExecutable: String
}

private struct Arguments {
    let hostPid: Int32
    let executable: URL
    let ready: URL
    let width: Int
    let runId: String
    let output: URL

    init(_ values: [String]) throws {
        guard values.count == 13,
              values[1] == "--host-pid", values[3] == "--host-executable",
              values[5] == "--ready-file", values[7] == "--width",
              values[9] == "--run-id", values[11] == "--output-dir",
              let pid = Int32(values[2]), pid > 1,
              let width = Int(values[8]), [220, 320, 760].contains(width),
              values[4].hasPrefix("/"), values[6].hasPrefix("/"), values[12].hasPrefix("/") else {
            throw InfrastructureFailure("arguments", "Expected explicit --host-pid, --host-executable, --ready-file, --width, --run-id and --output-dir")
        }
        let runId = values[10]
        guard !runId.isEmpty, runId.utf8.count <= 128,
              runId.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else {
            throw InfrastructureFailure("arguments", "Invalid run identity")
        }
        let executable = URL(fileURLWithPath: values[4]).standardizedFileURL.resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.lastPathComponent == "MingaTestHost.app",
              let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.minga.test-host",
              bundle.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == executable,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InfrastructureFailure("host_identity", "Expected the current MingaTestHost executable")
        }
        let output = URL(fileURLWithPath: values[12]).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &directory), directory.boolValue,
              !FileManager.default.fileExists(atPath: output.appendingPathComponent("observation.json").path),
              !FileManager.default.fileExists(atPath: output.appendingPathComponent("window.png").path) else {
            throw InfrastructureFailure("output_directory", "Evidence directory must exist without previous acquisition outputs")
        }
        self.hostPid = pid
        self.executable = executable
        self.ready = URL(fileURLWithPath: values[6]).standardizedFileURL.resolvingSymlinksInPath()
        self.width = width
        self.runId = runId
        self.output = output
    }
}

@MainActor
private final class GeometryObserver {
    private let arguments: Arguments
    private let clock = ContinuousClock()
    private let system = AXUIElementCreateSystemWide()

    init(_ arguments: Arguments) {
        self.arguments = arguments
    }

    func run() async -> Int32 {
        do {
            guard AXIsProcessTrusted() else {
                throw InfrastructureFailure("accessibility_permission", "The geometry observer requires existing Accessibility authorization; no permission was requested")
            }
            guard CGPreflightScreenCaptureAccess() else {
                throw InfrastructureFailure("screen_capture_permission", "The geometry observer requires existing Screen Recording authorization; no permission was requested")
            }
            try check(AXUIElementSetMessagingTimeout(system, 1), "set_ax_timeout")
            let started = String(DispatchTime.now().uptimeNanoseconds)
            let deadline = clock.now.advanced(by: .seconds(10))
            let identity = try await awaitHost(deadline: deadline)
            let application = AXUIElementCreateApplication(identity.pid)
            try check(AXUIElementSetMessagingTimeout(application, 1), "set_host_ax_timeout")
            try await awaitForeground(application, deadline: deadline)
            var layout = try snapshot(application, pid: identity.pid)
            while (layout == nil || layout?.workspaceCount != 1 || (layout?.buttons.count ?? 0) < 4), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                layout = try snapshot(application, pid: identity.pid)
            }
            guard let before = layout else {
                throw InfrastructureFailure("window_readiness", "The owned host did not expose one accessibility window before the deadline")
            }
            let capture = try await Self.capture(identity: identity, bounds: before.windowFrame, output: arguments.output)
            guard let after = try snapshot(application, pid: identity.pid), before == after else {
                throw InfrastructureFailure("changed_during_capture", "External accessibility observations changed while capturing the owned window")
            }
            let observation = Observation(
                runId: arguments.runId, width: arguments.width,
                observerPid: ProcessInfo.processInfo.processIdentifier,
                observerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path,
                host: identity, workspaceCount: after.workspaceCount, workspace: after.workspace,
                buttons: after.buttons, capture: capture, startedNs: started,
                finishedNs: String(DispatchTime.now().uptimeNanoseconds)
            )
            try write(observation, to: arguments.output.appendingPathComponent("observation.json"))
            return 0
        } catch {
            let acquisition = error as? InfrastructureFailure ?? InfrastructureFailure("acquisition", String(describing: error))
            writeFailure(acquisition)
            return 2
        }
    }


    private func awaitHost(deadline: ContinuousClock.Instant) async throws -> HostIdentity {
        let ready = arguments.ready
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard clock.now < deadline else {
                throw InfrastructureFailure("host_readiness", "Owned host did not publish lifecycle readiness before the deadline")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = try Data(contentsOf: ready)
        guard data.count <= 16_384 else {
            throw InfrastructureFailure("host_readiness", "Lifecycle receipt exceeded its bound")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(HostReady.self, from: data)
        guard value.schema == "minga-approval-host-v1", value.runId == arguments.runId,
              value.width == arguments.width, value.pid == arguments.hostPid,
              URL(fileURLWithPath: value.executable).standardizedFileURL.resolvingSymlinksInPath() == arguments.executable,
              value.bundleIdentifier == "com.minga.test-host", value.windowId > 0 else {
            throw InfrastructureFailure("host_identity", "Lifecycle receipt does not identify this owned host and run")
        }
        return HostIdentity(pid: value.pid, executable: value.executable,
                            bundleIdentifier: value.bundleIdentifier, windowId: value.windowId)
    }

    private func awaitForeground(_ application: AXUIElement, deadline: ContinuousClock.Instant) async throws {
        while true {
            let frontmost: Bool? = try attribute(application, kAXFrontmostAttribute)
            if frontmost == true { return }
            guard clock.now < deadline else {
                throw InfrastructureFailure("host_foreground_readiness", "The owned test host did not become the foreground application; global button hit testing cannot start")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }


    private struct Layout: Equatable {
        let windowFrame: Frame
        let workspaceCount: Int
        let workspace: Frame?
        let buttons: [ButtonObservation]
    }

    private func snapshot(_ application: AXUIElement, pid: Int32) throws -> Layout? {
        let windows: [AXUIElement] = try attribute(application, kAXWindowsAttribute) ?? []
        guard !windows.isEmpty else { return nil }
        guard windows.count == 1 else { throw InfrastructureFailure("window_identity", "Owned fixture exposed multiple accessibility windows") }
        let window = windows[0]
        let windowFrame = try requiredFrame(window)
        let all = try descendants(window, pid: pid)
        let workspaces = try all.filter { try attribute($0, kAXIdentifierAttribute) as String? == "approval-geometry-workspace" }
        guard workspaces.count == 1 else {
            return Layout(windowFrame: windowFrame, workspaceCount: workspaces.count, workspace: nil, buttons: [])
        }
        let workspace = workspaces[0]
        let children = try descendants(workspace, pid: pid)
        var buttons: [ButtonObservation] = []
        for element in children {
            let role: String? = try attribute(element, kAXRoleAttribute)
            guard role == kAXButtonRole else { continue }
            let title: String?
            let titleAttribute: String
            if let observed: String = try attribute(element, kAXTitleAttribute), !observed.isEmpty {
                title = observed
                titleAttribute = kAXTitleAttribute
            } else {
                title = try attribute(element, kAXDescriptionAttribute)
                titleAttribute = kAXDescriptionAttribute
            }
            let enabled: Bool? = try attribute(element, kAXEnabledAttribute)
            let frame = try optionalFrame(element)
            var names: CFArray?
            let actionStatus = AXUIElementCopyActionNames(element, &names)
            if actionStatus != .success && actionStatus != .attributeUnsupported && actionStatus != .notImplemented {
                try check(actionStatus, "button_actions")
            }
            var actions: [String] = []
            if actionStatus == .success {
                guard let observed = names as? [String] else {
                    throw InfrastructureFailure("button_actions", "Unexpected native accessibility action list")
                }
                actions = observed
            }
            let pressCapable = actions.contains(kAXPressAction)
            let hit = try frame.map { try centerHits(element, frame: $0.rect, pid: pid) } ?? false
            let textWidth = title.map { Double(($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width) }
            buttons.append(ButtonObservation(title: title, titleAttribute: titleAttribute,
                                             role: kAXButtonRole, frame: frame, enabled: enabled,
                                             pressCapable: pressCapable, centerHitsExactButton: hit,
                                             labelWidth: textWidth))
        }
        return Layout(windowFrame: windowFrame, workspaceCount: 1,
                      workspace: try optionalFrame(workspace), buttons: buttons)
    }

    private func descendants(_ root: AXUIElement, pid: Int32) throws -> [AXUIElement] {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var result: [AXUIElement] = []
        while let (element, depth) = pending.popLast() {
            guard result.count < 512, depth <= 24 else {
                throw InfrastructureFailure("ax_traversal", "Owned accessibility tree exceeded its fixed traversal bound")
            }
            var owner: pid_t = 0
            try check(AXUIElementGetPid(element, &owner), "ax_owner")
            guard owner == pid else { throw InfrastructureFailure("ax_owner", "Accessibility tree left the owned process") }
            result.append(element)
            let children: [AXUIElement] = try attribute(element, kAXChildrenAttribute) ?? []
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return result
    }

    private func centerHits(_ button: AXUIElement, frame: CGRect, pid: Int32) throws -> Bool {
        guard frame.width > 0, frame.height > 0, frame.midX.isFinite, frame.midY.isFinite else { return false }
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(frame.midX), Float(frame.midY), &hit)
        if status == .noValue { return false }
        try check(status, "ax_hit_test")
        var current = hit
        for _ in 0..<24 {
            guard let element = current else { return false }
            var owner: pid_t = 0
            try check(AXUIElementGetPid(element, &owner), "hit_owner")
            guard owner == pid else { return false }
            if CFEqual(element, button) { return true }
            current = try attribute(element, kAXParentAttribute)
        }
        throw InfrastructureFailure("ax_hit_test", "Hit ancestry exceeded its fixed bound")
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) throws -> T? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        if status == .noValue || status == .attributeUnsupported { return nil }
        try check(status, name)
        guard let raw else { throw InfrastructureFailure("ax_attribute", "Missing successful value for \(name)") }
        if T.self == Bool.self, CFGetTypeID(raw) != CFBooleanGetTypeID() {
            throw InfrastructureFailure("ax_attribute", "Expected a native boolean for \(name)")
        }
        if T.self == AXUIElement.self, CFGetTypeID(raw) != AXUIElementGetTypeID() {
            throw InfrastructureFailure("ax_attribute", "Expected a native accessibility element for \(name)")
        }
        if T.self == AXValue.self, CFGetTypeID(raw) != AXValueGetTypeID() {
            throw InfrastructureFailure("ax_attribute", "Expected a native accessibility value for \(name)")
        }
        guard let value = raw as? T else {
            throw InfrastructureFailure("ax_attribute", "Unexpected value type for \(name)")
        }
        return value
    }

    private func optionalFrame(_ element: AXUIElement) throws -> Frame? {
        guard let position: AXValue = try attribute(element, kAXPositionAttribute),
              let size: AXValue = try attribute(element, kAXSizeAttribute) else { return nil }
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else {
            throw InfrastructureFailure("ax_frame", "Accessibility position or size has an unexpected type")
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else {
            throw InfrastructureFailure("ax_frame", "Could not decode accessibility position or size")
        }
        return Frame(CGRect(origin: point, size: dimensions))
    }

    private func requiredFrame(_ element: AXUIElement) throws -> Frame {
        guard let frame = try optionalFrame(element) else { throw InfrastructureFailure("ax_frame", "Owned window has no external accessibility frame") }
        return frame
    }

    private func check(_ status: AXError, _ operation: String) throws {
        guard status == .success else { throw InfrastructureFailure("ax_transport", "\(operation) failed with AXError \(status.rawValue)") }
    }

    nonisolated private static func capture(identity: HostIdentity, bounds: Frame, output: URL) async throws -> Capture {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.windowID == identity.windowId && $0.owningApplication?.processID == identity.pid && $0.isOnScreen && $0.windowLayer == 0
        }
        guard windows.count == 1 else { throw InfrastructureFailure("capture_identity", "No unique on-screen capture window matches the owned host") }
        let window = windows[0]
        // ScreenCaptureKit includes compositor chrome that AXWindow does not expose.
        guard window.frame.contains(bounds.rect) else {
            throw InfrastructureFailure("capture_mapping", "The owned capture frame does not contain its AX window: AX=\(bounds), SC=\(Frame(window.frame))")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        guard scale.isFinite, scale > 0,
              abs(filter.contentRect.width - window.frame.width) <= 0.5,
              abs(filter.contentRect.height - window.frame.height) <= 0.5 else {
            throw InfrastructureFailure("capture_mapping", "Owned-window point bounds or native pixel scale are unavailable")
        }
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.includeChildWindows = false
        configuration.captureResolution = .best
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard image.width == configuration.width, image.height == configuration.height else {
            throw InfrastructureFailure("capture_dimensions", "Captured image dimensions do not match the native-scale owned window")
        }
        let filename = "window.png"
        let destination = output.appendingPathComponent(filename)
        guard let encoder = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw InfrastructureFailure("capture_encoding", "Could not create the owned-window PNG destination")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw InfrastructureFailure("capture_encoding", "Could not finish the owned-window PNG") }
        let bytes = try Data(contentsOf: destination)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw InfrastructureFailure("capture_decoding", "The retained owned-window PNG could not be decoded")
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Capture(filename: filename, api: "ScreenCaptureKit.SCScreenshotManager.desktopIndependentWindow",
                       windowId: identity.windowId, hostPid: identity.pid, pointBounds: Frame(window.frame), axWindowBounds: bounds,
                       scale: scale, pixelWidth: image.width, pixelHeight: image.height,
                       sha256: digest, decodedPixelWidth: decoded.width, decodedPixelHeight: decoded.height)
    }

    private func write<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: destination, options: .atomic)
    }

    private func writeFailure(_ failure: InfrastructureFailure) {
        do {
            try write(FailureReceipt(runId: arguments.runId, width: arguments.width, failure: failure,
                                     observerPid: ProcessInfo.processInfo.processIdentifier,
                                     observerExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path),
                      to: arguments.output.appendingPathComponent("observation.json"))
        } catch {
            FileHandle.standardError.write(Data(("Geometry receipt failure: \(error)\n").utf8))
        }
    }
}

@main
private enum ApprovalGeometryMain {
    @MainActor static func main() async {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            let result = await GeometryObserver(arguments).run()
            exit(result)
        } catch {
            FileHandle.standardError.write(Data(("Geometry infrastructure failure: \(error)\n").utf8))
            exit(2)
        }
    }
}
