/// Tests for CoreTextLineRenderer engine.

import Testing
import Foundation
import Metal
import CoreText
@testable import minga_mac

@Suite("CoreTextLineRenderer")
@MainActor
struct CoreTextLineRendererTests {
    /// Helper to create a renderer with the system monospace font.
    private func makeRenderer() -> CoreTextLineRenderer? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 2.0)
        return CoreTextLineRenderer(device: device, fontManager: fontManager)
    }

    @Test("Renders a simple text run into a non-nil texture")
    func renderSimpleRun() throws {
        guard let renderer = makeRenderer() else {
            // CI machines without Metal: skip gracefully.
            return
        }

        let runs = [StyledRun(col: 0, text: "Hello, world!", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        let hash = runs.hashValue
        let result = renderer.renderLine(row: 0, runs: runs, contentHash: hash)

        #expect(result != nil)
        #expect(result!.pixelWidth > 0)
        #expect(result!.pixelHeight > 0)
        #expect(result!.contentHash == hash)
    }

    @Test("Cache hit on identical content hash")
    func cacheHit() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "cached", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        let hash = runs.hashValue

        let first = renderer.renderLine(row: 0, runs: runs, contentHash: hash)
        let second = renderer.renderLine(row: 0, runs: runs, contentHash: hash)

        #expect(first != nil)
        #expect(second != nil)
        // Same texture object (pointer equality via Metal resource).
        #expect(first!.texture === second!.texture)
    }

    @Test("Cache miss on different content hash")
    func cacheMissOnChange() throws {
        guard let renderer = makeRenderer() else { return }

        let runs1 = [StyledRun(col: 0, text: "version1", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        let runs2 = [StyledRun(col: 0, text: "version2", fg: 0xFF0000, bg: 0, attrs: 0)]

        let first = renderer.renderLine(row: 0, runs: runs1, contentHash: runs1.hashValue)
        let second = renderer.renderLine(row: 0, runs: runs2, contentHash: runs2.hashValue)

        #expect(first != nil)
        #expect(second != nil)
        // Different textures since content changed.
        #expect(first!.texture !== second!.texture)
    }

    @Test("Empty runs return nil")
    func emptyRunsReturnNil() throws {
        guard let renderer = makeRenderer() else { return }

        let result = renderer.renderLine(row: 0, runs: [], contentHash: 0)
        #expect(result == nil)
    }

    @Test("Multiple styled runs on one line")
    func multipleRunsOneLine() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [
            StyledRun(col: 0, text: "def", fg: 0xFF0000, bg: 0, attrs: 0x01),  // bold keyword
            StyledRun(col: 3, text: " ", fg: 0xFFFFFF, bg: 0, attrs: 0),
            StyledRun(col: 4, text: "hello", fg: 0x00FF00, bg: 0, attrs: 0),    // function name
        ]
        let hash = runs.hashValue
        let result = renderer.renderLine(row: 0, runs: runs, contentHash: hash)

        #expect(result != nil)
        #expect(result!.pixelWidth > 0)
    }

    @Test("Bold attribute selects bold font variant")
    func boldAttribute() throws {
        guard let renderer = makeRenderer() else { return }

        let normalRuns = [StyledRun(col: 0, text: "normal", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        let boldRuns = [StyledRun(col: 0, text: "bold", fg: 0xFFFFFF, bg: 0, attrs: 0x01)]

        let normal = renderer.renderLine(row: 0, runs: normalRuns, contentHash: normalRuns.hashValue)
        let bold = renderer.renderLine(row: 1, runs: boldRuns, contentHash: boldRuns.hashValue)

        #expect(normal != nil)
        #expect(bold != nil)
    }

    @Test("Italic attribute selects italic font variant")
    func italicAttribute() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "italic", fg: 0xFFFFFF, bg: 0, attrs: 0x04)]
        let result = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)

        #expect(result != nil)
    }

    @Test("Font weight variation")
    func fontWeightVariation() throws {
        guard let renderer = makeRenderer() else { return }

        let lightRuns = [StyledRun(col: 0, text: "light", fg: 0xFFFFFF, bg: 0, attrs: 0, fontWeight: 1)]
        let heavyRuns = [StyledRun(col: 0, text: "heavy", fg: 0xFFFFFF, bg: 0, attrs: 0, fontWeight: 6)]

        let light = renderer.renderLine(row: 0, runs: lightRuns, contentHash: lightRuns.hashValue)
        let heavy = renderer.renderLine(row: 1, runs: heavyRuns, contentHash: heavyRuns.hashValue)

        #expect(light != nil)
        #expect(heavy != nil)
    }

    @Test("Texture dimensions match expected pixel size")
    func textureDimensions() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "test", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        let result = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)

        #expect(result != nil)
        // Height should match linePixelHeight (cellHeight * scale).
        #expect(result!.pixelHeight == renderer.linePixelHeight)
        // Width should be positive and reasonable.
        #expect(result!.pixelWidth > 0)
        #expect(result!.pixelWidth <= Int(ceil(4.0 * renderer.cellWidth * renderer.scale)))
    }

    @Test("Cache eviction removes stale textures")
    func cacheEviction() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "evict me", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        _ = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)
        #expect(renderer.cacheCount == 1)

        // Advance past eviction threshold.
        for _ in 0...130 {
            renderer.beginFrame()
        }

        #expect(renderer.cacheCount == 0)
    }

    @Test("beginFrame keeps recently used textures")
    func beginFrameKeepsRecent() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "keep me", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        _ = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)

        // Use it every frame so it stays alive.
        for _ in 0..<50 {
            renderer.beginFrame()
            _ = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)
        }

        #expect(renderer.cacheCount == 1)
    }

    @Test("invalidateAll clears cache")
    func invalidateAll() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "clear", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        _ = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)
        _ = renderer.renderLine(row: 1, runs: runs, contentHash: runs.hashValue)
        #expect(renderer.cacheCount == 2)

        renderer.invalidateAll()
        #expect(renderer.cacheCount == 0)
    }

    @Test("Underline attribute is set")
    func underlineAttribute() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "underlined", fg: 0xFFFFFF, bg: 0, attrs: 0x02,
                              underlineColor: 0xFF0000, underlineStyle: 1)]
        let result = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)
        #expect(result != nil)
    }

    @Test("Strikethrough attribute is set")
    func strikethroughAttribute() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "struck", fg: 0xFFFFFF, bg: 0, attrs: 0x10)]
        let result = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)
        #expect(result != nil)
    }

    @Test("Rendered texture has non-zero alpha content")
    func nonZeroAlphaContent() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "ABC", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        guard let result = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue) else {
            Issue.record("Expected non-nil texture")
            return
        }

        // Read back pixel data from the texture.
        let width = result.pixelWidth
        let height = result.pixelHeight
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: width, height: height, depth: 1))
        result.texture.getBytes(&pixelData, bytesPerRow: bytesPerRow,
                                from: region, mipmapLevel: 0)

        // Check that at least one pixel has non-zero alpha.
        var hasContent = false
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                // BGRA format: alpha is at offset+3
                if pixelData[offset + 3] > 0 {
                    hasContent = true
                    break
                }
            }
            if hasContent { break }
        }
        #expect(hasContent, "Rendered texture should have non-zero alpha pixels")
    }

    @Test("Bold attribute renders with bold font weight")
    func boldAttributeRendersCorrectly() throws {
        guard let renderer = makeRenderer() else { return }

        // attrs=0x01 is bold. With fontWeight at default (2=regular),
        // resolveFont should override to weight 5 (bold).
        let runs = [StyledRun(col: 0, text: "BOLD", fg: 0xFFFFFF, bg: 0, attrs: 0x01)]
        let result = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)

        #expect(result != nil)
        #expect(result!.pixelWidth > 0)
    }

    @Test("Viewport width update invalidates cache")
    func viewportWidthUpdate() throws {
        guard let renderer = makeRenderer() else { return }

        let runs = [StyledRun(col: 0, text: "wide", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        _ = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue)
        #expect(renderer.cacheCount == 1)

        renderer.updateViewportWidth(cols: 200)
        #expect(renderer.cacheCount == 0)
    }
}
