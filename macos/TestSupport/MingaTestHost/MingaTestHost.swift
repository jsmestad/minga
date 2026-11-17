import AppKit
import SwiftUI
import MingaUI

/// Hosts isolated native tests and the approval geometry fixture without production startup.
@main
@MainActor
enum MingaTestHost {
    static func main() {
        let application = NSApplication.shared
        let delegate = MingaTestHostDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class MingaTestHostDelegate: NSObject, NSApplicationDelegate {
    private var fixtureWindow: NSWindow?
    private var geometryLifeline: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        let requested = application.setActivationPolicy(.regular)
        guard application.activationPolicy() == .regular else {
            fatalError("MingaTestHost requires regular activation policy after launch; previous=\(previousPolicy.rawValue) requested=\(requested) actual=\(application.activationPolicy().rawValue)")
        }
        print("[MingaTestHost] didFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "-") executable=\(Bundle.main.executableURL?.path ?? "-")")
        if let rawWidth = ProcessInfo.processInfo.environment["MINGA_TEST_APPROVAL_WIDTH"] {
            guard let width = Double(rawWidth), [220, 320, 760].contains(width),
                  let runId = ProcessInfo.processInfo.environment["MINGA_APPROVAL_GEOMETRY_RUN_ID"],
                  let readyPath = ProcessInfo.processInfo.environment["MINGA_APPROVAL_GEOMETRY_READY"],
                  readyPath.hasPrefix("/") else {
                fatalError("Approval geometry requires a supported width and an owned observer lifeline")
            }
            showApprovalGeometry(width: width, runId: runId, ready: URL(fileURLWithPath: readyPath))
        }
    }

    private func showApprovalGeometry(width: CGFloat, runId: String, ready: URL) {
        let root = AgentApprovalCard(
            name: "shell", summary: "git diff --cached",
            toolCallId: "tool-a", sessionId: "session-a", requestId: "request-a",
            previewKind: 2, previewLines: ["git diff --cached"],
            sendAction: { [weak self] action in
                self?.fixtureWindow?.title = "Approval Geometry: \(String(describing: action))"
            }
        )
        .padding(.horizontal, Spacing.xl)
        .frame(width: width, height: 400, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.themeColors, ThemeColors())
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval-geometry-workspace")
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Approval Geometry"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        fixtureWindow = window
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        guard let executable = Bundle.main.executableURL,
              let bundleIdentifier = Bundle.main.bundleIdentifier,
              let windowId = UInt32(exactly: window.windowNumber), windowId > 0 else {
            fatalError("Approval geometry host has no complete lifecycle identity")
        }
        window.setAccessibilityIdentifier("minga-approval-window:\(runId):\(windowId)")
        geometryLifeline = Task { @MainActor in
            do {
                for try await _ in FileHandle.standardInput.bytes {}
            } catch {
                FileHandle.standardError.write(Data(("Approval supervisor lifeline failed: \(error)\n").utf8))
            }
            NSApplication.shared.terminate(nil)
        }
        let receipt = GeometryReady(
            runId: runId, width: Int(width), pid: ProcessInfo.processInfo.processIdentifier,
            executable: executable.standardizedFileURL.resolvingSymlinksInPath().path,
            bundleIdentifier: bundleIdentifier, windowId: windowId
        )
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            try encoder.encode(receipt).write(to: ready, options: .atomic)
        } catch {
            fatalError("Approval geometry could not publish lifecycle readiness: \(error)")
        }
    }

    private struct GeometryReady: Encodable {
        let schema = "minga-approval-host-v1"
        let runId: String
        let width: Int
        let pid: Int32
        let executable: String
        let bundleIdentifier: String
        let windowId: UInt32
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
