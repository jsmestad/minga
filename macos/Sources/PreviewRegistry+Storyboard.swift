/// The macOS half of the storyboard renderer (#4036).
///
/// The storyboard factory records every packet the BEAM sends while it drives a scenario (test/support/storyboard/render.ex).
/// This mode replays each transcript through the production decoder and CommandDispatcher, hosts the production ContentView in a window of the transcript's size, and writes:
///   - `<output>.png`: the window as the compositor draws it, Metal editor included (ScreenCaptureKit);
///   - `<output>.json`: every anatomy part the chrome tagged (`View.anatomyPart`) and the AppKit accessibility tree
///     (the Metal editor's text area), with frames in window points.
/// The JSON is the macOS baseline that design/tools/storyboard/renders.py diffs; the PNG is for the storyboard page and visual review.
///
/// Run it through `scripts/storyboard render-macos`, which builds PreviewHost and passes `PREVIEW_VIEW=Storyboard` and `PREVIEW_STORYBOARD_JOBS`.

import AppKit
import MingaProtocol
import ScreenCaptureKit
import MingaUI
import SwiftUI

@MainActor
enum StoryboardCapture {
    /// One capture: a transcript in, a PNG and an export out (`output` has no extension).
    struct Job: Decodable {
        let transcript: String
        let output: String
    }

    private struct Transcript: Decodable {
        struct Window: Decodable {
            let width: Int
            let height: Int
        }

        let version: Int
        let scenario: String
        let frontend: String
        let theme: String
        let size: String
        let cols: Int
        let rows: Int
        let window: Window?
        let digest: String?
        let packets: [String]
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String, Error)
        case malformed(String)
        case rejected(String)
        case notPresented(String)
        case gridMismatch(scenario: String, size: String, expected: String, measured: String)

        var description: String {
            switch self {
            case .unreadable(let path, let error): "cannot read \(path): \(error)"
            case .malformed(let message): message
            case .rejected(let message): message
            case .notPresented(let message): message
            case let .gridMismatch(scenario, size, expected, measured):
                "\(scenario) at \(size) pt: the transcript was laid out in \(expected), but this window reports \(measured). Update test/storyboard/macos_geometry.json."
            }
        }
    }

    /// Runs every job in `PREVIEW_STORYBOARD_JOBS` and returns the failures. Each job gets a fresh window and state.
    static func runAll() async -> [String] {
        guard let path = ProcessInfo.processInfo.environment["PREVIEW_STORYBOARD_JOBS"] else {
            return ["PREVIEW_STORYBOARD_JOBS is not set"]
        }
        let jobs: [Job]
        do {
            jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            return ["cannot read the job list \(path): \(error)"]
        }
        var failures: [String] = []
        for job in jobs {
            do {
                try await capture(job)
                print(job.output + ".png")
            } catch {
                failures.append("\(job.transcript): \(error)")
            }
        }
        return failures
    }

    private static func capture(_ job: Job) async throws {
        let transcript: Transcript
        do {
            transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: job.transcript)))
        } catch {
            throw Failure.unreadable(job.transcript, error)
        }
        guard transcript.version == 1, transcript.frontend == "macos", let size = transcript.window else {
            throw Failure.malformed("\(job.transcript) is not a macOS storyboard transcript")
        }

        let recorder = AnatomyPartRecorder()
        AnatomyPartRecorder.shared = recorder
        defer { AnatomyPartRecorder.shared = nil }

        let appState = AppState()
        appState.windowTitle = "Minga"
        let encoder = PreviewFixtures.encoder()
        appState.encoder = encoder
        appState.gui.settingsState.sendAction = FrontendActionComposition.settingsStateHandler(encoder: encoder)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let fontManager = FontManager(name: "Menlo", size: 13, scale: scale)
        guard let renderer = CoreTextMetalRenderer() else {
            throw Failure.rejected("the production Metal renderer is unavailable")
        }
        renderer.setupRenderers(fontManager: fontManager)

        var editor: EditorNSView?
        let dispatcher = CommandDispatcher(
            cols: UInt16(transcript.cols), rows: UInt16(transcript.rows), guiState: appState.gui,
            applicationEffectSink: { effect in
                apply(effect, appState: appState, editor: editor, renderer: renderer, fontManager: fontManager, scale: scale)
            }
        )
        dispatcher.fontManager = fontManager
        let view = EditorNSView(
            encoder: encoder, dispatcher: dispatcher, coreTextRenderer: renderer,
            fontManager: fontManager, reduceMotionEnabled: true)
        view.setCursorBlinkEnabled(false)
        view.editorInput = appState.gui.editorInput
        view.statusBarState = appState.gui.statusBarState
        editor = view
        appState.editorNSView = view
        // The effect sink holds the editor and the app state; break the cycle so each capture frees its Metal renderer.
        defer {
            editor = nil
            appState.editorNSView = nil
        }

        for (index, encoded) in transcript.packets.enumerated() {
            guard let packet = Data(base64Encoded: encoded) else {
                throw Failure.malformed("\(transcript.scenario): packet \(index) is not base64")
            }
            do {
                dispatcher.dispatch(try decodeFrame(from: packet))
            } catch {
                throw Failure.rejected("\(transcript.scenario): packet \(index) failed to decode: \(error)")
            }
        }
        guard dispatcher.committedEditorSnapshot != nil else {
            throw Failure.rejected("\(transcript.scenario): no editor frame was committed")
        }
        appState.startup = nil

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let host = NSHostingView(rootView:
            PreviewRegistry.productionContentView(appState)
                .frame(width: CGFloat(size.width), height: CGFloat(size.height))
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                })
        window.contentView = host
        window.setContentSize(NSSize(width: size.width, height: size.height))
        window.orderFrontRegardless()
        // Tear the SwiftUI tree down before the editor is released, so no late body update finds it gone.
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        try await waitForPresentation(of: dispatcher, view: view, host: host, scenario: transcript.scenario)

        let measured = view.reportedGrid
        guard Int(measured.cols) == transcript.cols, Int(measured.rows) == transcript.rows else {
            throw Failure.gridMismatch(
                scenario: transcript.scenario, size: transcript.size,
                expected: "\(transcript.cols)x\(transcript.rows)", measured: "\(measured.cols)x\(measured.rows)")
        }

        let png = try await settledPNG(window: window, host: host)
        let export = exportJSON(transcript: transcript, window: window, host: host, parts: recorder.frames,
                                scale: window.backingScaleFactor, fontManager: fontManager)
        let base = URL(fileURLWithPath: job.output)
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: base.appendingPathExtension("png"), options: .atomic)
        try export.write(to: base.appendingPathExtension("json"), options: .atomic)
    }

    /// The application effects a real app applies from the same packets; the rest have no visible effect in a still.
    private static func apply(_ effect: ApplicationCommitEffect, appState: AppState, editor: EditorNSView?,
                              renderer: CoreTextMetalRenderer, fontManager: FontManager, scale: CGFloat) {
        switch effect {
        case .fontChanged(let family, let size, let ligatures, let weight):
            let update = fontManager.setPrimaryFont(FontManager.Configuration(
                family: family, size: CGFloat(size), scale: scale, ligatures: ligatures, weight: weight))
            guard update.configurationChanged else { return }
            renderer.setupRenderers(fontManager: fontManager)
            editor?.fontConfigurationChanged(metricsChanged: update.metricsChanged)
        case .titleChanged(let title):
            appState.windowTitle = title
        case .windowBackgroundChanged(let red, let green, let blue):
            let luminance = (Double(red) * 0.299 + Double(green) * 0.587 + Double(blue) * 0.114) / 255
            appState.windowBgIsDark = luminance < 0.5
        default:
            break
        }
    }

    /// Waits until the Metal surface has presented the last committed frame, never for a fixed delay.
    private static func waitForPresentation(of dispatcher: CommandDispatcher, view: EditorNSView,
                                            host: NSView, scenario: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            host.display()
            view.renderFrame()
            if let visible = dispatcher.visibleEditorPresentation,
               visible.snapshot.frameSeq == dispatcher.lastCommittedFrameSeq {
                return
            }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(16))))
        }
        throw Failure.notPresented("\(scenario): the editor did not present frame \(dispatcher.lastCommittedFrameSeq) within 10 s")
    }

    /// Requires three identical compositor frames, so a capture never catches a half-laid-out window.
    private static func settledPNG(window: NSWindow, host: NSView) async throws -> Data {
        let scale = window.backingScaleFactor
        let width = Int(window.frame.width * scale)
        let height = Int(window.frame.height * scale)
        var previous: Data?
        var identical = 0
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            host.display()
            let image = try await captureWindow(
                windowID: CGWindowID(window.windowNumber), width: width, height: height)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw Failure.rejected("PNG encoding failed")
            }
            identical = png == previous ? identical + 1 : 1
            if identical == 3 { return png }
            previous = png
            try await Task.sleep(for: .milliseconds(80))
        }
        throw Failure.notPresented("the window did not settle to three identical frames")
    }

    /// The window as the compositor draws it, Metal editor included. PreviewHost's own capture transport stays private
    /// to its delegate, so the chrome preview evidence can share it between revisions unchanged.
    private nonisolated static func captureWindow(windowID: CGWindowID, width: Int, height: Int) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw Failure.notPresented("the storyboard window is not shareable with ScreenCaptureKit")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    }

    /// The accessibility tree as a flat list in document order, frames in window points with a top-left origin, rounded to half a point.
    private static func exportJSON(transcript: Transcript, window: NSWindow, host: NSView, parts: [AnatomyPartFrame],
                                   scale: CGFloat, fontManager: FontManager) -> Data {
        var elements: [[String: Any]] = []
        walk(host, depth: 0, window: window, into: &elements)
        let measured: [[String: Any]] = parts.map { part in
            var entry: [String: Any] = [
                "part": part.name,
                "frame": [half(part.frame.minX), half(part.frame.minY), half(part.frame.width), half(part.frame.height)],
            ]
            if let text = part.text { entry["text"] = text }
            if let baseline = part.baseline { entry["baseline"] = half(baseline) }
            return entry
        }
        let object: [String: Any] = [
            "version": 1,
            "scenario": transcript.scenario,
            "frontend": "macos",
            "theme": transcript.theme,
            "size": transcript.size,
            "window": ["width": window.frame.width, "height": window.frame.height],
            "backing_scale": scale,
            "grid": ["cols": transcript.cols, "rows": transcript.rows],
            "transcript_digest": transcript.digest ?? "",
            "editor_font": [
                "postscript_name": CTFontCopyPostScriptName(fontManager.primary.ctFont) as String,
                "size": CTFontGetSize(fontManager.primary.ctFont),
            ],
            "parts": measured,
            "elements": elements,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private static func walk(_ element: Any, depth: Int, window: NSWindow, into elements: inout [[String: Any]]) {
        guard depth < 64, let node = element as? NSAccessibilityProtocol else { return }
        if let entry = describe(node, depth: depth, window: window) {
            elements.append(entry)
        }
        let children = node.accessibilityChildren() ?? []
        for child in children {
            walk(child, depth: depth + 1, window: window, into: &elements)
        }
        // Views that expose no accessibility children still host subviews that do (the Metal editor, AppKit controls).
        if children.isEmpty, let view = node as? NSView {
            for subview in view.subviews {
                walk(subview, depth: depth + 1, window: window, into: &elements)
            }
        }
    }

    /// AppKit elements that say something: the Metal editor's text area and native controls. Identifiers carry
    /// per-run presentation ids, so the export keeps the role, label, value and frame.
    private static func describe(_ node: NSAccessibilityProtocol, depth: Int, window: NSWindow) -> [String: Any]? {
        let label = node.accessibilityLabel() ?? ""
        let value = node.accessibilityValue() as? String ?? ""
        let screen = node.accessibilityFrame()
        guard screen.width > 1, screen.height > 1, !(label.isEmpty && value.isEmpty) else { return nil }
        let origin = window.frame.origin
        let x = screen.minX - origin.x
        let y = window.frame.height - (screen.maxY - origin.y)
        var entry: [String: Any] = [
            "role": node.accessibilityRole()?.rawValue ?? "",
            "frame": [half(x), half(y), half(screen.width), half(screen.height)],
        ]
        if !label.isEmpty { entry["label"] = label }
        if !value.isEmpty { entry["value"] = value }
        return entry
    }

    private static func half(_ value: CGFloat) -> Double { (Double(value) * 2).rounded() / 2 }
}
