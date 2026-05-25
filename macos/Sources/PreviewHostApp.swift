/// Minimal macOS app that renders SwiftUI chrome previews to PNG screenshots and exits.
///
/// Used by agents to get visual feedback on SwiftUI chrome views and production shell previews without starting the BEAM process. Full-shell previews exercise the real ContentView and editor rendering path; smaller component previews still render isolated SwiftUI views.

import AppKit
import ScreenCaptureKit
import SwiftUI

@main
struct PreviewHostApp: App {
    @NSApplicationDelegateAdaptor(PreviewHostDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            previewContent()
                .onAppear {
                    // Wait for SwiftUI to finish layout before capturing the preview.
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
        let size = PreviewRegistry.size(named: viewName)
        return PreviewRegistry.view(named: viewName)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private enum PreviewCaptureError: Error {
    case windowNotShareable
}

@MainActor
final class PreviewHostDelegate: NSObject, NSApplicationDelegate {
    private func fail(_ message: String) -> Never {
        fputs("error: \(message)\n", stderr)
        exit(1)
    }

    func captureAndExit() {
        Task { @MainActor in
            await captureAndExitAsync()
        }
    }

    private func captureAndExitAsync() async {
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

        let pngData = await captureWindowPNG(window: window, contentView: contentView, viewName: viewName)

        let outputURL = URL(fileURLWithPath: outputPath)
        do {
            try pngData.write(to: outputURL)
            print(outputPath)
        } catch {
            fail("failed to write PNG: \(error)")
        }

        NSApplication.shared.terminate(nil)
    }

    private func captureWindowPNG(window: NSWindow, contentView: NSView, viewName: String) async -> Data {
        let expectedPixelSize = PreviewSnapshotPolicy.expectedPixelSize(named: viewName, scale: window.backingScaleFactor)

        if PreviewSnapshotPolicy.shouldUseRenderedWindowCapture(viewName) {
            do {
                let image = try await captureRenderedWindow(window)
                let normalized = normalizeRenderedCapture(image, expectedPixelSize: expectedPixelSize, viewName: viewName)
                return encodePNG(from: normalized, expectedPixelSize: expectedPixelSize, viewName: viewName)
            } catch {
                if PreviewSnapshotPolicy.requiresRenderedWindowCapture(viewName) {
                    fail("rendered window capture failed for \(viewName): \(error)")
                }
            }
        }

        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            fail("bitmapImageRepForCachingDisplay returned nil")
        }
        contentView.cacheDisplay(in: bounds, to: bitmap)

        assertBitmapDimensions(bitmap, expectedPixelSize: expectedPixelSize, viewName: viewName)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fail("PNG encoding failed")
        }
        return pngData
    }

    private func normalizeRenderedCapture(_ image: CGImage, expectedPixelSize: CGSize, viewName: String) -> CGImage {
        let expectedWidth = Int(expectedPixelSize.width.rounded())
        let expectedHeight = Int(expectedPixelSize.height.rounded())

        guard image.width >= expectedWidth, image.height >= expectedHeight else {
            fail("rendered window capture for \(viewName) is too small: got \(image.width)x\(image.height), expected at least \(expectedWidth)x\(expectedHeight)")
        }

        if image.width == expectedWidth && image.height == expectedHeight {
            return image
        }

        let cropRect = CGRect(x: 0, y: 0, width: expectedWidth, height: expectedHeight)
        guard let cropped = image.cropping(to: cropRect) else {
            fail("rendered window capture for \(viewName) could not be cropped to \(expectedWidth)x\(expectedHeight)")
        }
        return cropped
    }

    private func encodePNG(from image: CGImage, expectedPixelSize: CGSize, viewName: String) -> Data {
        assertCGImageDimensions(image, expectedPixelSize: expectedPixelSize, viewName: viewName)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fail("PNG encoding failed for \(viewName)")
        }
        return pngData
    }

    private func assertBitmapDimensions(_ bitmap: NSBitmapImageRep, expectedPixelSize: CGSize, viewName: String) {
        let expectedWidth = Int(expectedPixelSize.width.rounded())
        let expectedHeight = Int(expectedPixelSize.height.rounded())
        guard bitmap.pixelsWide == expectedWidth, bitmap.pixelsHigh == expectedHeight else {
            fail("bitmap capture for \(viewName) had unexpected dimensions: got \(bitmap.pixelsWide)x\(bitmap.pixelsHigh), expected \(expectedWidth)x\(expectedHeight)")
        }
    }

    private func assertCGImageDimensions(_ image: CGImage, expectedPixelSize: CGSize, viewName: String) {
        let expectedWidth = Int(expectedPixelSize.width.rounded())
        let expectedHeight = Int(expectedPixelSize.height.rounded())
        guard image.width == expectedWidth, image.height == expectedHeight else {
            fail("rendered capture for \(viewName) had unexpected dimensions: got \(image.width)x\(image.height), expected \(expectedWidth)x\(expectedHeight)")
        }
    }

    private func captureRenderedWindow(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        let windowID = CGWindowID(window.windowNumber)
        guard let shareableWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw PreviewCaptureError.windowNotShareable
        }

        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
