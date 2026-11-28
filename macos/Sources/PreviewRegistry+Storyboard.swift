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

        /// The composer fit the transcript was laid out in, when the scenario shows a conversation.
        struct PromptFit: Decodable {
            let cols: Int
            let rows: Int
        }

        let version: Int
        let scenario: String
        let frontend: String
        let theme: String
        let size: String
        let cols: Int
        let rows: Int
        let window: Window?
        let prompt: PromptFit?
        let digest: String?
        let packets: [String]
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String, Error)
        case malformed(String)
        case rejected(String)
        case notPresented(String)
        case gridMismatch(scenario: String, size: String, expected: String, measured: String)
        case promptFitMismatch(scenario: String, size: String, expected: String, measured: String)
        case promptPaneWidthMismatch(scenario: String, size: String, expected: Int, measured: Int?)

        var description: String {
            switch self {
            case .unreadable(let path, let error): "cannot read \(path): \(error)"
            case .malformed(let message): message
            case .rejected(let message): message
            case .notPresented(let message): message
            case let .gridMismatch(scenario, size, expected, measured):
                "\(scenario) at \(size) pt: the transcript was laid out in \(expected), but this window reports \(measured). Update test/storyboard/macos_geometry.json."
            case let .promptFitMismatch(scenario, size, expected, measured):
                "\(scenario) at \(size) pt: the transcript laid the composer out in \(expected), but this window reports \(measured). Update the chrome's `prompt` in test/storyboard/macos_geometry.json."
            case let .promptPaneWidthMismatch(scenario, size, expected, measured):
                "\(scenario) at \(size) pt: the transcript requires a \(expected)-column prompt pane, but Metal presented \(measured.map { "\($0) columns" } ?? "no prompt pane"). Check the BEAM prompt fit relay."
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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true

        var editor: EditorNSView?
        let dispatcher = CommandDispatcher(
            cols: UInt16(transcript.cols), rows: UInt16(transcript.rows), guiState: appState.gui,
            applicationEffectSink: { effect in
                apply(effect, appState: appState, window: window, editor: editor, renderer: renderer, fontManager: fontManager, scale: scale)
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
        // Tear the SwiftUI tree down and break the effect sink's cycle before releasing the editor.
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
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

        let host = NSHostingView(rootView:
            PreviewRegistry.productionContentView(appState)
                .frame(width: CGFloat(size.width), height: CGFloat(size.height))
                .environment(\.motionPaused, true)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                })
        window.contentView = host
        window.setContentSize(NSSize(width: size.width, height: size.height))
        window.orderFrontRegardless()

        let presented = try await waitForPresentation(
            of: dispatcher, view: view, host: host, scenario: transcript.scenario,
            requiresPrompt: transcript.prompt != nil
        )

        let measured = view.reportedGrid
        guard Int(measured.cols) == transcript.cols, Int(measured.rows) == transcript.rows else {
            throw Failure.gridMismatch(
                scenario: transcript.scenario, size: transcript.size,
                expected: "\(transcript.cols)x\(transcript.rows)", measured: "\(measured.cols)x\(measured.rows)")
        }

        // The width must match the aperture exactly. The frontend may have room for more rows
        // than the BEAM's composer uses, but it must have room for every row in the transcript's fit.
        let measuredPrompt = view.reportedPromptFit
        switch (transcript.prompt, measuredPrompt) {
        case (nil, nil):
            break
        case let (expected?, actual?) where expected.cols == Int(actual.cols) && expected.rows <= Int(actual.rows):
            break
        default:
            throw Failure.promptFitMismatch(
                scenario: transcript.scenario, size: transcript.size,
                expected: transcript.prompt.map { "\($0.cols)x\($0.rows)" } ?? "no composer",
                measured: measuredPrompt.map { "\($0.cols)x\($0.rows)" } ?? "no composer")
        }
        if let expected = transcript.prompt {
            let columns = presented.snapshot.surface(for: 65534).map { Int($0.paneGeometry.textRect.width) }
            guard columns == expected.cols else {
                throw Failure.promptPaneWidthMismatch(
                    scenario: transcript.scenario, size: transcript.size, expected: expected.cols, measured: columns)
            }
        }

        let png = try await settledPNG(window: window, host: host)
        let export = exportJSON(transcript: transcript, window: window, host: host, parts: recorder.frames,
                                pixels: StoryboardPixels(png: png, scale: window.backingScaleFactor),
                                scale: window.backingScaleFactor, fontManager: fontManager,
                                snapshot: presented.snapshot)
        let base = URL(fileURLWithPath: job.output)
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: base.appendingPathExtension("png"), options: .atomic)
        try export.write(to: base.appendingPathExtension("json"), options: .atomic)
    }

    /// The application effects a real app applies from the same packets; the rest have no visible effect in a still.
    private static func apply(_ effect: ApplicationCommitEffect, appState: AppState, window: NSWindow,
                              editor: EditorNSView?, renderer: CoreTextMetalRenderer, fontManager: FontManager, scale: CGFloat) {
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
            let r = CGFloat(red) / 255
            let g = CGFloat(green) / 255
            let b = CGFloat(blue) / 255
            let isDark = (r * 0.299 + g * 0.587 + b * 0.114) < 0.5
            appState.windowBgIsDark = isDark
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            // The continuously mounted editor clears to transparent outside the prompt pane.
            // Its backing window must use the theme, just as it does in the app.
            window.backgroundColor = NSColor(red: r, green: g, blue: b, alpha: 1)
        default:
            break
        }
    }

    /// Waits for the final frame and, for a conversation, for Metal to draw in the current composer aperture.
    private static func waitForPresentation(of dispatcher: CommandDispatcher, view: EditorNSView,
                                            host: NSView, scenario: String,
                                            requiresPrompt: Bool) async throws -> VisibleEditorPresentation {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            host.display()
            view.renderFrame()
            if let visible = dispatcher.visibleEditorPresentation,
               visible.snapshot.frameSeq == dispatcher.lastCommittedFrameSeq {
                let clip = visible.textLayout?.promptTransform?.clip
                if !requiresPrompt || (clip != nil && clip == view.agentPromptPlacement?.rect) {
                    return visible
                }
            }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(16))))
        }
        let requirement = requiresPrompt ? " in the current composer aperture" : ""
        throw Failure.notPresented("\(scenario): the editor did not present frame \(dispatcher.lastCommittedFrameSeq)\(requirement) within 10 s")
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

    /// The surface and every ink under each part that shows text. A part can hold an icon and words; each ink is
    /// judged, so a strong icon cannot pass weak words.
    private static func samples(_ parts: [AnatomyPartFrame], pixels: StoryboardPixels?, covered: [CGRect]) -> [[String: Any]] {
        guard let pixels else { return [] }
        return parts.compactMap { part in
            guard let text = part.text, !text.trimmingCharacters(in: .whitespaces).isEmpty,
                  let sample = pixels.sample(part.frame, excluding: part.name == "breadcrumb.segment" ? covered : []) else { return nil }
            return ["part": part.name, "text": text, "inks": sample.inks, "bg": sample.bg]
        }
    }

    /// Every distinct ink colour in the visible Metal text, syntax colours included, with its surface.
    private static func code(_ elements: [[String: Any]], pixels: StoryboardPixels?, covered: [CGRect]) -> [String: Any] {
        guard let pixels,
              let editor = elements.first(where: { element in
                  guard element["role"] as? String == "AXTextArea",
                        let value = element["value"] as? String else { return false }
                  return value.contains(where: { !$0.isWhitespace })
              }),
              let frame = editor["frame"] as? [Double], frame.count == 4,
              let found = pixels.inks(CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]), excluding: covered) else { return [:] }
        // The block cursor is the system accent colour, a glyph rather than text. The audit leaves out inks near it:
        // a sampled colour can move by a step through Metal, capture and colour conversion, so not by equality.
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB).map {
            String(format: "#%02x%02x%02x", Int(($0.redComponent * 255).rounded()),
                   Int(($0.greenComponent * 255).rounded()), Int(($0.blueComponent * 255).rounded()))
        } ?? ""
        return ["bg": found.bg, "inks": found.inks, "cursor": accent]
    }

    // Record visible authored marks independently of pixel antialiasing and transient unit IDs.
    private static func authorship(_ snapshot: CommittedEditorSnapshot) -> [[String: Any]] {
        snapshot.surfaces.flatMap { surface -> [[String: Any]] in
            guard let gutter = surface.gutter.gutter, let authored = gutter.authorship, !authored.isEmpty else {
                return []
            }
            var firstSourceRow = true
            return surface.visibleRowRange.enumerated().compactMap { offset, index in
                guard let row = surface.content.rowStore.row(at: index),
                      row.rowType == .normal || row.rowType == .wrapContinuation else { return nil }
                let pin = firstSourceRow
                firstSourceRow = false
                guard let mark = authored.region(at: row.bufLine, pin: pin, continuation: row.rowType == .wrapContinuation) else {
                    return nil
                }
                return ["row": Int(gutter.contentRow) + offset, "column": gutter.contentCol,
                        "role": mark.region.role.rawValue, "head": mark.head, "shared": mark.shared]
            }
        }
    }

    /// The accessibility tree as a flat list in document order, frames in window points with a top-left origin, rounded to half a point.
    private static func exportJSON(transcript: Transcript, window: NSWindow, host: NSView, parts: [AnatomyPartFrame],
                                   pixels: StoryboardPixels?, scale: CGFloat, fontManager: FontManager,
                                   snapshot: CommittedEditorSnapshot) -> Data {
        var elements: [[String: Any]] = []
        walk(host, depth: 0, window: window, into: &elements)
        // Sample visible editor and breadcrumb ink, not the overlaid panel's fill or text.
        // Two interior bars of the rounded Act menu leave its transparent corners and shadow in the sample.
        let covered = parts.flatMap { part -> [CGRect] in
            switch part.name {
            case "picker.panel":
                [part.frame]
            case "actMenu.panel":
                [part.frame.insetBy(dx: Radius.lg, dy: 0), part.frame.insetBy(dx: 0, dy: Radius.lg)]
            default:
                []
            }
        }
        let measured: [[String: Any]] = parts.filter { $0.name != "picker.panel" }.map { part in
            var entry: [String: Any] = [
                "part": part.name,
                "frame": [half(part.frame.minX), half(part.frame.minY), half(part.frame.width), half(part.frame.height)],
            ]
            if let text = part.text { entry["text"] = text }
            if let baseline = part.baseline { entry["baseline"] = half(baseline) }
            return entry
        }
        var object: [String: Any] = [
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
            // Colours read from the pixels, for the layout audit's contrast rule. Not part of the baseline: antialiasing
            // can move a sampled colour by a step between runners.
            "samples": samples(parts, pixels: pixels, covered: covered),
            "code": code(elements, pixels: pixels, covered: covered),
        ]
        let marks = authorship(snapshot)
        if !marks.isEmpty { object["authorship"] = marks }
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
