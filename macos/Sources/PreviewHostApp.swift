/// Minimal macOS app that renders one SwiftUI chrome view to a PNG screenshot and exits.
///
/// Used by Claude Code to get visual feedback on SwiftUI chrome views
/// without the BEAM process, Metal renderer, or protocol stack.

import AppKit
import SwiftUI

@main
struct PreviewHostApp: App {
    @NSApplicationDelegateAdaptor(PreviewHostDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            previewContent()
                .frame(width: 800, height: 600)
                .onAppear {
                    // Wait for SwiftUI to finish layout before capturing the window bitmap.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        delegate.captureAndExit()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

    @MainActor
    func previewContent() -> some View {
        let viewName = ProcessInfo.processInfo.environment["PREVIEW_VIEW"] ?? "StatusBarView"
        return PreviewRegistry.view(named: viewName)
    }
}

@MainActor
final class PreviewHostDelegate: NSObject, NSApplicationDelegate {
    private func fail(_ message: String) -> Never {
        fputs("error: \(message)\n", stderr)
        exit(1)
    }

    func captureAndExit() {
        guard let window = NSApplication.shared.windows.first,
              let contentView = window.contentView else {
            fail("no window or content view found")
        }

        window.orderFrontRegardless()
        contentView.layoutSubtreeIfNeeded()
        contentView.display()

        let outputDir = ProcessInfo.processInfo.environment["PREVIEW_OUTPUT_DIR"]
            ?? "macos/Tests/Snapshots"
        let viewName = ProcessInfo.processInfo.environment["PREVIEW_VIEW"] ?? "StatusBarView"
        let outputPath = "\(outputDir)/\(viewName).png"

        let dirURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            fail("cannot create output directory: \(error)")
        }

        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            fail("bitmapImageRepForCachingDisplay returned nil")
        }
        contentView.cacheDisplay(in: bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fail("PNG encoding failed")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        do {
            try pngData.write(to: outputURL)
            print(outputPath)
        } catch {
            fail("failed to write PNG: \(error)")
        }

        NSApplication.shared.terminate(nil)
    }
}
