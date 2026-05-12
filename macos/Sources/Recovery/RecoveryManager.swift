/// Detects frontend-to-BEAM stalls and presents a native recovery dialog.
///
/// The macOS frontend keeps accepting keyboard events even when the BEAM stops
/// reading from its port. If key events have been sent and no render batch has
/// completed for a few seconds, Ctrl-G becomes an explicit recovery gesture.

import AppKit
import Darwin
import Foundation

@MainActor
final class RecoveryManager {
    private let timeoutSeconds: CFTimeInterval
    private let restartAction: @MainActor () -> Void

    private(set) var lastBatchEndTime: CFAbsoluteTime
    private(set) var keysSinceLastRender: Int = 0
    private(set) var isShowingAlert: Bool = false

    init(timeoutSeconds: CFTimeInterval = 3.0, restartAction: @escaping @MainActor () -> Void = RecoveryManager.sendRestartSignalToParent) {
        self.timeoutSeconds = timeoutSeconds
        self.restartAction = restartAction
        self.lastBatchEndTime = CFAbsoluteTimeGetCurrent()
    }

    /// Records that a complete render batch arrived from the BEAM.
    func onRenderReceived() {
        lastBatchEndTime = CFAbsoluteTimeGetCurrent()
        keysSinceLastRender = 0
        isShowingAlert = false
    }

    /// Records that a key event was sent to the BEAM.
    func onKeySent() {
        keysSinceLastRender += 1
    }

    /// Returns true when user input is pending and the BEAM has not rendered within the timeout.
    func isUnresponsive(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        keysSinceLastRender > 0 && now - lastBatchEndTime > timeoutSeconds
    }

    /// Handles Ctrl-G. Returns true when the recovery gesture was consumed.
    @discardableResult
    func handleCtrlG() -> Bool {
        guard isUnresponsive() else { return false }
        guard !isShowingAlert else { return true }
        showRecoveryAlert()
        return true
    }

    /// Test helper for deterministic timeout checks.
    func setLastBatchEndTimeForTesting(_ time: CFAbsoluteTime) {
        lastBatchEndTime = time
    }

    private func showRecoveryAlert() {
        isShowingAlert = true
        defer { isShowingAlert = false }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Editor Unresponsive"
        alert.informativeText = "Minga has sent input to the editor core, but no render response has arrived. You can restart the editor core while preserving buffers, quit Minga, or wait for it to recover."
        alert.addButton(withTitle: "Restart Editor")
        alert.addButton(withTitle: "Quit Minga")
        alert.addButton(withTitle: "Wait")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            restartAction()
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private static func sendRestartSignalToParent() {
        let parentPid = getppid()
        guard parentPid > 1 else { return }
        kill(parentPid, SIGUSR1)
    }
}
