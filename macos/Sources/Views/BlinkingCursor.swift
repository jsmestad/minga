/// Shared blinking cursor view and system blink timing utilities.
///
/// Used by MinibufferView, AgentChatView, and any future SwiftUI input
/// surfaces that need a macOS-native blinking text cursor. The Metal
/// editor cursor (#933) reads SystemBlinkTiming directly but manages
/// its own blink loop on the MTKView.

import SwiftUI

// MARK: - System blink timing

/// Reads the macOS system cursor blink rate from UserDefaults.
///
/// All cursor-blinking surfaces (SwiftUI BlinkingCursor, Metal editor
/// cursor) share this single source of truth for blink timing. The
/// system settings are NSTextInsertionPointBlinkPeriodOn/Off (milliseconds).
struct SystemBlinkTiming {
    /// Nanoseconds the cursor stays visible per blink cycle.
    let onDuration: UInt64

    /// Nanoseconds the cursor stays hidden per blink cycle.
    let offDuration: UInt64

    /// Reads the current system blink timing. Falls back to 530ms (macOS default)
    /// if the UserDefaults keys are missing or zero.
    static var system: SystemBlinkTiming {
        let onMs = UserDefaults.standard.double(forKey: "NSTextInsertionPointBlinkPeriodOn")
        let offMs = UserDefaults.standard.double(forKey: "NSTextInsertionPointBlinkPeriodOff")
        return SystemBlinkTiming(
            onDuration: onMs > 0 ? UInt64(onMs * 1_000_000) : 530_000_000,
            offDuration: offMs > 0 ? UInt64(offMs * 1_000_000) : 530_000_000
        )
    }

    /// Whether the system has disabled cursor blinking via Accessibility settings.
    /// When true, cursors should remain solid (always visible, no blink).
    @MainActor
    static var blinkingDisabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Blinking cursor view

/// A beam cursor (thin vertical bar) that blinks at the macOS system
/// insertion point rate. Resets to visible whenever `resetToken` changes,
/// so typing keeps the cursor solid during active input.
///
/// Uses a Task-based timer loop for precise on/off timing that matches
/// native macOS text cursor behavior (no fade, just toggle).
struct BlinkingCursor: View {
    let color: Color
    var width: CGFloat = 2
    var height: CGFloat = 16
    var resetToken: Int = 0

    @State private var isVisible = true
    @State private var blinkTask: Task<Void, Never>?

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width, height: height)
            .opacity(isVisible ? 1 : 0)
            .onAppear { restartBlink() }
            .onDisappear { blinkTask?.cancel() }
            .onChange(of: resetToken) { _, _ in
                restartBlink()
            }
    }

    /// Cancels any active blink timer, snaps cursor to visible, and starts
    /// a new blink cycle. Called on appear and whenever resetToken changes.
    @MainActor
    private func restartBlink() {
        blinkTask?.cancel()
        isVisible = true

        // Don't blink when Accessibility > Reduce Motion is enabled.
        guard !SystemBlinkTiming.blinkingDisabled else { return }

        let timing = SystemBlinkTiming.system

        blinkTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: timing.onDuration)
                guard !Task.isCancelled else { break }
                isVisible = false
                try? await Task.sleep(nanoseconds: timing.offDuration)
                guard !Task.isCancelled else { break }
                isVisible = true
            }
        }
    }
}
