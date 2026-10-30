import AppKit

/// Owns only the native application lifecycle required by the hosted unit bundle.
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        let requested = application.setActivationPolicy(.regular)
        guard application.activationPolicy() == .regular else {
            fatalError("MingaTestHost requires regular activation policy after launch; previous=\(previousPolicy.rawValue) requested=\(requested) actual=\(application.activationPolicy().rawValue)")
        }
        print("[MingaTestHost] didFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "-") executable=\(Bundle.main.executableURL?.path ?? "-")")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
