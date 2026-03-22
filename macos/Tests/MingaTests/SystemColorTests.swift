/// Tests for system color integration (accent color, cursor color).

import Testing
import Foundation

@Suite("System Colors")
@MainActor
struct SystemColorTests {
    @Test("readAccentColor returns values in valid 0-1 range")
    func accentColorRange() {
        let c = CoreTextMetalRenderer.readAccentColor()
        #expect(c.x >= 0 && c.x <= 1, "Red component out of range: \(c.x)")
        #expect(c.y >= 0 && c.y <= 1, "Green component out of range: \(c.y)")
        #expect(c.z >= 0 && c.z <= 1, "Blue component out of range: \(c.z)")
    }

    @Test("readAccentColor returns system accent, not fallback gray")
    func accentColorNotFallback() {
        let c = CoreTextMetalRenderer.readAccentColor()
        // On a real Mac, controlAccentColor is never the fallback (0.8, 0.8, 0.8).
        // CI without a display may hit the fallback, so this test is informational.
        let isFallback = c.x == 0.8 && c.y == 0.8 && c.z == 0.8
        #expect(!isFallback, "Expected system accent color, got fallback gray")
    }

    @Test("cursorColor on renderer matches readAccentColor")
    func cursorColorMatchesAccent() {
        guard let renderer = CoreTextMetalRenderer() else {
            // No Metal device (CI). Skip gracefully.
            return
        }
        let accent = CoreTextMetalRenderer.readAccentColor()
        let cursor = renderer.cursorColor
        #expect(cursor.x == accent.x)
        #expect(cursor.y == accent.y)
        #expect(cursor.z == accent.z)
    }
}
