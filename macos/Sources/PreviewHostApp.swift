/// Minimal macOS app that renders SwiftUI chrome previews to PNG screenshots and exits.
///
/// Used by agents to get visual feedback on SwiftUI chrome views and production shell previews without starting the BEAM process. Full-shell previews exercise the real ContentView and editor rendering path; smaller component previews still render isolated SwiftUI views.

import AppKit
import CoreText
import ScreenCaptureKit
import SwiftUI

@main
struct PreviewHostApp: App {
    @NSApplicationDelegateAdaptor(PreviewHostDelegate.self) var delegate
    init() {
        do {
            _ = try PreviewSnapshotPolicy.agentWidth(ProcessInfo.processInfo.environment["PREVIEW_AGENT_WIDTH"])
            guard (ProcessInfo.processInfo.environment["PREVIEW_THEME"] ?? "doom-one") == "doom-one" else {
                throw PreviewCaptureError.unsupportedTheme
            }
        } catch {
            fputs("error: unsupported preview configuration: \(error)\n", stderr)
            exit(1)
        }
    }

    var body: some Scene {
        WindowGroup {
            previewContent()
                .allowsHitTesting(false)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .background(PreviewWindowProbe { window, fixtureView in
                    delegate.captureAndExit(window: window, fixtureView: fixtureView)
                })
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
    case unsupportedTheme
}

/// Selects the window actually hosting the requested fixture, not an unrelated
/// first application window. No desktop automation or Accessibility is involved.
private struct PreviewWindowProbe: NSViewRepresentable {
    let ready: @MainActor (NSWindow, NSView) -> Void

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(ready: ready)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        let ready: @MainActor (NSWindow, NSView) -> Void

        init(ready: @escaping @MainActor (NSWindow, NSView) -> Void) {
            self.ready = ready
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { ready(window, self) }
        }
    }
}

@MainActor
final class PreviewHostDelegate: NSObject, NSApplicationDelegate {
    private var started = false

    private func fail(_ message: String) -> Never {
        fputs("error: \(message)\n", stderr)
        exit(1)
    }

    func captureAndExit(window: NSWindow, fixtureView: NSView) {
        guard !started else { return }
        started = true
        window.ignoresMouseEvents = true
        Task { @MainActor in
            await captureAndExitAsync(window: window, fixtureView: fixtureView)
        }
    }

    /// Readiness and metadata belong to this revision's production surface.
    /// Cross-revision evidence shares only the capture transport helpers below.
    private func captureAndExitAsync(window: NSWindow, fixtureView: NSView) async {
        guard let contentView = window.contentView else {
            fail("fixture window has no content view")
        }
        guard fixtureView.window === window else {
            fail("fixture view does not belong to the capture window")
        }

        let outputDir = ProcessInfo.processInfo.environment["PREVIEW_OUTPUT_DIR"]
            ?? "macos/Tests/Snapshots"
        let viewName = ProcessInfo.processInfo.environment["PREVIEW_VIEW"] ?? "StatusBarView"
        let outputName = ProcessInfo.processInfo.environment["PREVIEW_OUTPUT_NAME"] ?? viewName
        let outputPath = "\(outputDir)/\(outputName).png"

        window.setContentSize(PreviewSnapshotPolicy.size(named: viewName))
        window.center()
        window.orderFrontRegardless()
        contentView.layoutSubtreeIfNeeded()
        contentView.display()
        // Let AppKit's layout/display and the compositor run after final sizing.
        // The outer driver also enforces a deadline if an OS capture call stalls.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(200))
        contentView.layoutSubtreeIfNeeded()
        contentView.display()
        if viewName == "AgentChromeView" {
            guard let state = PreviewRegistry.captureAppState,
                  let editor = state.editorNSView,
                  editor.dispatcher.committedEditorSnapshot != nil,
                  state.gui.agentChatState.visible,
                  !state.gui.agentChatState.messages.isEmpty,
                  !state.gui.agentChatState.prompt.isEmpty else {
                fail("agent workspace fixture is missing its production renderer, committed frame, transcript, or prompt")
            }
        }
        if let state = PreviewRegistry.captureAppState, state.gui.agentChatState.visible {
            guard await waitForCanonicalAgentPromptPresentation(state) else {
                let editor = state.editorNSView
                let visible = editor?.dispatcher.visibleEditorPresentation
                let pane = visible?.textLayout?.panes.first(where: { $0.windowID == 65534 })
                let expectedID = visible?.snapshot.metadata.textPresentations[65534]
                let matchingID = pane.map { expectedID == $0.presentationID } ?? false
                fputs(
                    "agent fixture readiness: placement=\(String(describing: editor?.agentPromptPlacement)) "
                    + "visible_presentation=\(visible != nil) pane65534=\(pane != nil) "
                    + "expected_id=\(String(describing: expectedID)) presented_id=\(String(describing: pane?.presentationID)) "
                    + "matching_id=\(matchingID) bounds=\(String(describing: editor?.bounds)) "
                    + "window_attached=\(editor?.window != nil) hidden=\(String(describing: editor?.isHiddenOrHasHiddenAncestor))\n",
                    stderr
                )
                fail("agent fixture has not presented its canonical prompt window through the production Metal aperture")
            }
        }

        let dirURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            fail("cannot create output directory: \(error)")
        }

        let pngData = await captureSettledPNG(window: window, contentView: contentView, fixtureView: fixtureView, viewName: viewName)
        guard let capturedBitmap = NSBitmapImageRep(data: pngData) else {
            fail("encoded preview PNG could not be decoded for its metadata")
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        do {
            var metadata: [String: Any] = [
                "view": viewName, "theme": "doom-one",
                "fixture": viewName == "AgentChromeView" ? "completed-transcript" : "registered-preview",
                "motion": viewName == "AgentChromeView" ? "frozen" : "animations-disabled",
                "transport": PreviewSnapshotPolicy.shouldUseRenderedWindowCapture(viewName) ? "ScreenCaptureKit" : "AppKit",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "system_reduce_motion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                "backing_scale": window.backingScaleFactor,
                "content_points": ["width": contentView.bounds.width, "height": contentView.bounds.height],
                "fixture_points": ["width": fixtureView.bounds.width, "height": fixtureView.bounds.height],
                "image_pixels": ["width": capturedBitmap.pixelsWide, "height": capturedBitmap.pixelsHigh],
                "window_points": ["width": window.frame.width, "height": window.frame.height],
                "window_id": window.windowNumber,
                "system_font": NSFont.systemFont(ofSize: 12).fontName,
                "build": ProcessInfo.processInfo.environment["PREVIEW_BUILD_CONFIGURATION"] ?? "unrecorded",
            ]
            if let editor = PreviewRegistry.captureAppState?.editorNSView {
                let face = editor.fontManager.primary.ctFont
                metadata["editor_font"] = [
                    "postscript_name": CTFontCopyPostScriptName(face) as String,
                    "family": CTFontCopyFamilyName(face) as String,
                    "size": CTFontGetSize(face),
                    "scale": editor.fontManager.scale,
                ]
                metadata["editor_frame"] = editor.dispatcher.lastCommittedFrameSeq
                metadata["editor_visibility"] = viewName == "AgentChromeView" ? "hidden-by-production-chat" : "visible"
            }
            let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try metadataData.write(to: URL(fileURLWithPath: "\(outputDir)/\(outputName).json"), options: .atomic)
            try pngData.write(to: outputURL, options: .atomic)
            print(outputPath)
        } catch {
            fail("failed to write PNG: \(error)")
        }

        NSApplication.shared.terminate(nil)
    }

    /// Layout schedules asynchronous offscreen rendering and drawable-copy completion.
    /// Observe the same strict postcondition until it is published, not for a fixed delay.
    private func waitForCanonicalAgentPromptPresentation(_ state: AppState) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !Task.isCancelled, clock.now < deadline {
            if let editor = state.editorNSView,
               editor.agentPromptPlacement != nil,
               let visible = editor.dispatcher.visibleEditorPresentation,
               let pane = visible.textLayout?.panes.first(where: { $0.windowID == 65534 }),
               visible.snapshot.metadata.textPresentations[65534] == pane.presentationID {
                return true
            }
            do {
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(16))))
            } catch {
                return false
            }
        }
        return false
    }

    /// Require three identical compositor frames after layout, rather than
    /// treating a fixed sleep or window existence as successful rendering.
    private func captureSettledPNG(window: NSWindow, contentView: NSView, fixtureView: NSView, viewName: String) async -> Data {
        guard viewName == "AgentChromeView" else {
            return await captureWindowPNG(window: window, contentView: contentView, fixtureView: fixtureView, viewName: viewName)
        }
        var previous: Data?
        var identicalFrames = 0
        for _ in 0..<20 {
            let png = await captureWindowPNG(window: window, contentView: contentView, fixtureView: fixtureView, viewName: viewName)
            identicalFrames = png == previous ? identicalFrames + 1 : 1
            if identicalFrames == 3 { return png }
            previous = png
            try? await Task.sleep(for: .milliseconds(100))
            contentView.layoutSubtreeIfNeeded()
            contentView.display()
        }
        fail("agent workspace did not settle to three identical rendered frames within 20 samples")
    }

    private func captureWindowPNG(window: NSWindow, contentView: NSView, fixtureView: NSView, viewName: String) async -> Data {
        let expectedPixelSize = PreviewSnapshotPolicy.expectedPixelSize(named: viewName, scale: window.backingScaleFactor)

        if PreviewSnapshotPolicy.shouldUseRenderedWindowCapture(viewName) {
            do {
                let scale = window.backingScaleFactor
                // Capture the entire native window, including its titlebar.
                // Content size excludes that chrome; cropping to it cut off the
                // workspace's bottom edge on the current SDK.
                let windowPixels = CGSize(
                    width: Int(window.frame.width * scale),
                    height: Int(window.frame.height * scale))
                let image = try await Self.captureRenderedWindow(
                    windowID: CGWindowID(window.windowNumber),
                    width: Int(window.frame.width * scale),
                    height: Int(window.frame.height * scale))
                try PreviewSnapshotPolicy.validateRenderedSize(
                    actual: CGSize(width: image.width, height: image.height), expected: windowPixels)
                return encodePNG(from: image, expectedPixelSize: windowPixels, viewName: viewName)
            } catch {
                if PreviewSnapshotPolicy.requiresRenderedWindowCapture(viewName) {
                    fail("rendered window capture failed for \(viewName): \(error)")
                }
            }
        }

        // The hosting view can include native titlebar space. Capture the actual fixture region, not that container.
        let bounds = fixtureView.convert(fixtureView.bounds, to: contentView)
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

    private nonisolated static func captureRenderedWindow(windowID: CGWindowID, width: Int, height: Int) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        guard let shareableWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw PreviewCaptureError.windowNotShareable
        }

        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
