import AppKit

/// Owns only the native application lifecycle required by the hosted unit bundle.
@main
@MainActor
enum MingaTestHost {
    static func main() {
        let application = NSApplication.shared
        let delegate = MingaTestHostDelegate()
        application.delegate = delegate
        guard application.setActivationPolicy(.regular) else {
            fatalError("MingaTestHost requires regular activation policy")
        }
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class MingaTestHostDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[MingaTestHost] didFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "-") executable=\(Bundle.main.executableURL?.path ?? "-")")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
