import AppKit
import MingaProtocol
import MingaUI
import Testing

/// Scroll indicator fade lifecycle, driven by a manual clock.
///
/// A flash shows the indicator at full opacity, waits 1.5 s, then fades it in
/// six 50 ms steps. Every test controls elapsed time, so no assertion depends
/// on real delays.
@Suite("Scroll indicator fade", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ScrollIndicatorFadeTests {
    private static let fadeSteps: [Float] = [5, 4, 3, 2, 1, 0].map { Float($0) / 6.0 }

    private func makeView(clock: ManualClock) throws -> (view: EditorNSView, renderer: CoreTextMetalRenderer) {
        try autoreleasepool {
            let font = FontManager(name: "Menlo", size: 13, scale: 1)
            let gui = GUIState()
            let dispatcher = CommandDispatcher(cols: 80, rows: 24, guiState: gui)
            let renderer = try #require(makeOffscreenRenderer(
                factories: offscreenNativeTestFactories(), fontManager: font
            ))
            let view = EditorNSView(
                encoder: SpyEncoder(), dispatcher: dispatcher,
                coreTextRenderer: renderer, fontManager: font
            )
            view.editorInput = gui.editorInput
            view.scrollFadeClock = clock
            return (view, renderer)
        }
    }

    /// Flashes the indicator and waits until the fade has parked in its idle delay.
    private func flash(_ view: EditorNSView, on clock: ManualClock) async {
        view.flashScrollIndicator()
        await clock.waitForSleepers(1)
    }

    /// Advances the clock and waits until the fade has applied a step and parked again.
    private func advanceToNextStep(_ clock: ManualClock, by duration: Duration) async {
        clock.advance(by: duration)
        await clock.waitForSleepers(1)
    }

    @Test("a flash holds full opacity through the idle delay, then fades in six steps")
    func fadeRunsAfterIdleDelay() async throws {
        let clock = ManualClock()
        let (view, renderer) = try makeView(clock: clock)

        await flash(view, on: clock)
        #expect(renderer.scrollIndicatorAlpha == 1)
        clock.advance(by: .milliseconds(1_499))
        #expect(clock.sleeperCount == 1)
        #expect(renderer.scrollIndicatorAlpha == 1)

        var observed: [Float] = []
        await advanceToNextStep(clock, by: .milliseconds(1))
        observed.append(renderer.scrollIndicatorAlpha)
        for _ in 0..<4 {
            await advanceToNextStep(clock, by: .milliseconds(50))
            observed.append(renderer.scrollIndicatorAlpha)
        }
        let fade = try #require(view.scrollFadeTaskForTesting)
        clock.advance(by: .milliseconds(50))
        await fade.value
        observed.append(renderer.scrollIndicatorAlpha)

        #expect(observed == Self.fadeSteps)
        #expect(clock.sleeperCount == 0)
    }

    @Test("a second flash during the idle delay cancels the first fade and restarts the delay")
    func flashDuringIdleDelayRestartsDelay() async throws {
        let clock = ManualClock()
        let (view, renderer) = try makeView(clock: clock)

        await flash(view, on: clock)
        clock.advance(by: .milliseconds(1_000))
        let first = try #require(view.scrollFadeTaskForTesting)
        view.flashScrollIndicator()
        await first.value
        await clock.waitForSleepers(1)

        // Past the first fade's deadline: only the second fade is still waiting.
        clock.advance(by: .milliseconds(600))
        #expect(renderer.scrollIndicatorAlpha == 1)
        #expect(clock.sleeperCount == 1)

        await advanceToNextStep(clock, by: .milliseconds(900))
        #expect(renderer.scrollIndicatorAlpha == Self.fadeSteps[0])
    }

    @Test("a flash during fading cancels the remaining steps and restores full opacity")
    func flashDuringFadingRestoresOpacity() async throws {
        let clock = ManualClock()
        let (view, renderer) = try makeView(clock: clock)

        await flash(view, on: clock)
        await advanceToNextStep(clock, by: .milliseconds(1_500))
        await advanceToNextStep(clock, by: .milliseconds(50))
        #expect(renderer.scrollIndicatorAlpha == Self.fadeSteps[1])

        let fading = try #require(view.scrollFadeTaskForTesting)
        view.flashScrollIndicator()
        #expect(renderer.scrollIndicatorAlpha == 1)
        await fading.value
        await clock.waitForSleepers(1)

        // The cancelled fade's next step would have run here.
        clock.advance(by: .milliseconds(50))
        #expect(renderer.scrollIndicatorAlpha == 1)
        #expect(clock.sleeperCount == 1)

        await advanceToNextStep(clock, by: .milliseconds(1_450))
        #expect(renderer.scrollIndicatorAlpha == Self.fadeSteps[0])
    }

    @Test("always-visible scrollers stop a fade at full opacity until overlay scrollers return",
          arguments: [false, true])
    func alwaysVisibleScrollersStopFade(duringFading: Bool) async throws {
        let clock = ManualClock()
        let (view, renderer) = try makeView(clock: clock)

        await flash(view, on: clock)
        if duringFading {
            await advanceToNextStep(clock, by: .milliseconds(1_500))
            #expect(renderer.scrollIndicatorAlpha == Self.fadeSteps[0])
        }
        let fade = try #require(view.scrollFadeTaskForTesting)
        view.scrollerStyleDidChange(alwaysShowsScrollbar: true)
        #expect(renderer.scrollIndicatorAlpha == 1)
        await fade.value
        #expect(view.scrollFadeTaskForTesting == nil)
        #expect(clock.sleeperCount == 0)

        clock.advance(by: .seconds(5))
        view.flashScrollIndicator()
        #expect(view.scrollFadeTaskForTesting == nil)
        #expect(renderer.scrollIndicatorAlpha == 1)

        view.scrollerStyleDidChange(alwaysShowsScrollbar: false)
        await clock.waitForSleepers(1)
        await advanceToNextStep(clock, by: .milliseconds(1_500))
        #expect(renderer.scrollIndicatorAlpha == Self.fadeSteps[0])
    }

    @Test("removing the view from its window cancels a pending or running fade", arguments: [false, true])
    func detachCancelsFade(duringFading: Bool) async throws {
        _ = NSApplication.shared
        let clock = ManualClock()
        let (view, renderer) = try makeView(clock: clock)
        view.savesFrameInApplicationPreferences = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        container.addSubview(view)
        defer { window.close() }

        // Mounting reads the host's scroller preference; select overlay scrollers so the fade runs.
        view.scrollerStyleDidChange(alwaysShowsScrollbar: false)
        await clock.waitForSleepers(1)
        if duringFading {
            await advanceToNextStep(clock, by: .milliseconds(1_500))
        }
        let alphaAtDetach = renderer.scrollIndicatorAlpha
        let fade = try #require(view.scrollFadeTaskForTesting)

        view.removeFromSuperview()
        await fade.value
        #expect(view.scrollFadeTaskForTesting == nil)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(5))
        #expect(renderer.scrollIndicatorAlpha == alphaAtDetach)
    }

    @Test("an editor view without a fade deallocates when released")
    func viewDeallocatesWithoutFade() throws {
        weak var released: EditorNSView?
        var renderer: CoreTextMetalRenderer?
        try autoreleasepool {
            let made = try makeView(clock: ManualClock())
            released = made.view
            renderer = made.renderer
        }
        #expect(released == nil)
        #expect(renderer != nil)
    }

    @Test("a fade suspended between steps does not keep a released view alive")
    func fadeDoesNotRetainReleasedView() async throws {
        let clock = ManualClock()
        var made: (view: EditorNSView, renderer: CoreTextMetalRenderer)? = try makeView(clock: clock)
        let renderer = try #require(made?.renderer)
        weak var released = made?.view
        autoreleasepool { made?.view.flashScrollIndicator() }
        await clock.waitForSleepers(1)
        await advanceToNextStep(clock, by: .milliseconds(1_500))
        #expect(renderer.scrollIndicatorAlpha == Self.fadeSteps[0])
        let fade = try #require(made?.view.scrollFadeTaskForTesting)

        // The fade is parked between steps when the last owner releases the view.
        made = nil
        #expect(clock.sleeperCount == 1)
        #expect(released == nil)

        // The fade wakes, finds no view, and ends without another step. A leaked view
        // would keep fading, so cancel it instead and let the expectation above fail.
        if released == nil {
            clock.advance(by: .milliseconds(50))
        } else {
            fade.cancel()
        }
        await fade.value
        #expect(clock.sleeperCount == 0)
        #expect(renderer.scrollIndicatorAlpha == Self.fadeSteps[0])
    }
}
