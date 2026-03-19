/// Debug test to verify CoreText line rendering produces visible pixels.

import Testing
import Foundation
import Metal
import CoreText
@testable import minga_mac

@Suite("CoreText Render Debug")
struct CoreTextRenderDebugTests {
    @Test("Verify rendered line has visible text pixels at expected positions")
    func verifyTextPixelPositions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 2.0)
        let renderer = CoreTextLineRenderer(device: device, fontManager: fontManager)

        // Simulate a line with a gap: gutter "19" at col 0, then content "hello" at col 5
        let runs = [
            StyledRun(col: 0, text: "19", fg: 0x888888, bg: 0, attrs: 0),
            StyledRun(col: 5, text: "hello", fg: 0xFFFFFF, bg: 0, attrs: 0),
        ]
        let hash = runs.hashValue
        guard let result = renderer.renderLine(row: 0, runs: runs, contentHash: hash) else {
            Issue.record("renderLine returned nil")
            return
        }

        let width = result.pixelWidth
        let height = result.pixelHeight
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: width, height: height, depth: 1))
        result.texture.getBytes(&pixelData, bytesPerRow: bytesPerRow,
                                from: region, mipmapLevel: 0)

        // Check for non-zero alpha pixels in the gutter area (first 2 cells)
        let cellPixelWidth = Int(ceil(CGFloat(fontManager.cellWidth) * 2.0))
        var gutterHasContent = false
        for y in 0..<height {
            for x in 0..<min(cellPixelWidth * 2, width) {
                let offset = y * bytesPerRow + x * 4
                if pixelData[offset + 3] > 10 {  // BGRA: alpha at +3
                    gutterHasContent = true
                    break
                }
            }
            if gutterHasContent { break }
        }
        #expect(gutterHasContent, "Gutter area (col 0-1) should have visible '19' text")

        // Check for non-zero alpha pixels in the content area (col 5+)
        let contentStartPx = cellPixelWidth * 5
        var contentHasContent = false
        for y in 0..<height {
            for x in contentStartPx..<min(contentStartPx + cellPixelWidth * 5, width) {
                let offset = y * bytesPerRow + x * 4
                if pixelData[offset + 3] > 10 {
                    contentHasContent = true
                    break
                }
            }
            if contentHasContent { break }
        }
        #expect(contentHasContent, "Content area (col 5+) should have visible 'hello' text")

        // Check gap area (col 2-4) is mostly empty
        var gapPixelCount = 0
        for y in 0..<height {
            for x in (cellPixelWidth * 2)..<min(cellPixelWidth * 5, width) {
                let offset = y * bytesPerRow + x * 4
                if pixelData[offset + 3] > 10 {
                    gapPixelCount += 1
                }
            }
        }
        // Gap should have very few content pixels (maybe some antialiasing bleed)
        let gapTotalPixels = (cellPixelWidth * 3) * height
        let gapContentRatio = Double(gapPixelCount) / Double(gapTotalPixels)
        #expect(gapContentRatio < 0.05, "Gap area (col 2-4) should be mostly empty, got \(Int(gapContentRatio * 100))% content")

        // Print some debug info
        print("Texture: \(width)x\(height) pixels")
        print("Cell pixel width: \(cellPixelWidth)")
        print("Gutter has content: \(gutterHasContent)")
        print("Content has content: \(contentHasContent)")
        print("Gap content ratio: \(Int(gapContentRatio * 100))%")
    }

    @Test("Verify text renders in the correct vertical position (not upside down)")
    func verifyVerticalPosition() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 2.0)
        let renderer = CoreTextLineRenderer(device: device, fontManager: fontManager)

        let runs = [StyledRun(col: 0, text: "Xy", fg: 0xFFFFFF, bg: 0, attrs: 0)]
        guard let result = renderer.renderLine(row: 0, runs: runs, contentHash: runs.hashValue) else {
            Issue.record("renderLine returned nil")
            return
        }

        let width = result.pixelWidth
        let height = result.pixelHeight
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: width, height: height, depth: 1))
        result.texture.getBytes(&pixelData, bytesPerRow: bytesPerRow,
                                from: region, mipmapLevel: 0)

        // Find the vertical range of content
        var topRow = height
        var bottomRow = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                if pixelData[offset + 3] > 10 {
                    topRow = min(topRow, y)
                    bottomRow = max(bottomRow, y)
                    break
                }
            }
        }

        print("Text vertical range: rows \(topRow) to \(bottomRow) (of \(height) total)")
        print("Top margin: \(topRow) pixels")
        print("Bottom margin: \(height - 1 - bottomRow) pixels")

        // Text should not be at the very top (should have some top margin for ascent positioning)
        // and should not be at the very bottom (should have space for descenders)
        #expect(topRow >= 0, "Text should start somewhere in the texture")
        #expect(bottomRow < height, "Text should end within the texture")
        #expect(topRow < height / 2, "Text should be in the upper portion (not just at the bottom)")
    }
}
