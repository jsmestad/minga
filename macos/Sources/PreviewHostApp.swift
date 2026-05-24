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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
    func captureAndExit() {
        guard let window = NSApplication.shared.windows.first,
              let contentView = window.contentView else {
            fputs("error: no window or content view found\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }

        window.orderFrontRegardless()
        contentView.layoutSubtreeIfNeeded()
        contentView.display()

        let outputDir = ProcessInfo.processInfo.environment["PREVIEW_OUTPUT_DIR"]
            ?? "macos/Tests/Snapshots"
        let viewName = ProcessInfo.processInfo.environment["PREVIEW_VIEW"] ?? "StatusBarView"
        let outputPath = "\(outputDir)/\(viewName).png"

        let dirURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            fputs("error: bitmapImageRepForCachingDisplay returned nil\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        contentView.cacheDisplay(in: bounds, to: bitmap)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fputs("error: PNG encoding failed\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        do {
            try pngData.write(to: outputURL)
            print(outputPath)
        } catch {
            fputs("error: failed to write PNG: \(error)\n", stderr)
        }

        NSApplication.shared.terminate(nil)
    }
}
