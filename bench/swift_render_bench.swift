import AppKit
import Foundation
import Metal

@main
struct SwiftRenderBench {
    static let rowCount = 80
    static let frameCount = 220
    static let warmupFrames = 40
    static let columnCount = 140

    @MainActor
    static func main() {
        setenv("MINGA_DISABLE_OSLOG", "1", 1)

        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("Swift render benchmark requires a Metal device\n", stderr)
            exit(1)
        }

        let fontManager = FontManager(name: "Menlo", size: 14.0, scale: 2.0)
        let rasterizer = BitmapRasterizer()
        let renderer = WindowContentRenderer(device: device, fontManager: fontManager, rasterizer: rasterizer)
        let atlas = LineTextureAtlas(device: device, slotHeight: renderer.linePixelHeight)
        let atlasWidth = Int(ceil(CGFloat(columnCount) * fontManager.cellWidth * fontManager.scale))
        atlas.ensureCapacity(maxSlots: rowCount * 3, width: atlasWidth)

        var rows = makeRows(frame: 0)
        for frame in 0..<warmupFrames {
            rows = mutateRows(rows, frame: frame)
            renderFrame(renderer: renderer, atlas: atlas, rows: rows)
        }

        var frameTimes: [Double] = []
        frameTimes.reserveCapacity(frameCount)

        for frame in 0..<frameCount {
            rows = mutateRows(rows, frame: frame + warmupFrames)
            let start = DispatchTime.now().uptimeNanoseconds
            renderFrame(renderer: renderer, atlas: atlas, rows: rows)
            let end = DispatchTime.now().uptimeNanoseconds
            frameTimes.append(Double(end - start) / 1_000.0)
        }

        let coldRows = makeRows(frame: 10_000)
        renderer.invalidateAll()
        atlas.invalidateAll()
        let coldStart = DispatchTime.now().uptimeNanoseconds
        renderFrame(renderer: renderer, atlas: atlas, rows: coldRows)
        let coldEnd = DispatchTime.now().uptimeNanoseconds
        let coldFrameUs = Double(coldEnd - coldStart) / 1_000.0

        let hitStart = DispatchTime.now().uptimeNanoseconds
        renderFrame(renderer: renderer, atlas: atlas, rows: coldRows)
        let hitEnd = DispatchTime.now().uptimeNanoseconds
        let cacheHitFrameUs = Double(hitEnd - hitStart) / 1_000.0

        printMetric("swift_frame_us", percentile(frameTimes, 0.50))
        printMetric("swift_frame_p95_us", percentile(frameTimes, 0.95))
        printMetric("swift_cold_frame_us", coldFrameUs)
        printMetric("swift_cache_hit_frame_us", cacheHitFrameUs)
        printMetric("swift_rows", Double(rowCount))
    }

    @MainActor
    static func renderFrame(renderer: WindowContentRenderer, atlas: LineTextureAtlas, rows: [GUIVisualRow]) {
        renderer.beginFrame()
        atlas.beginFrame()
        for (index, row) in rows.enumerated() {
            _ = renderer.renderRowToAtlas(displayRow: UInt16(index), row: row, atlas: atlas)
        }
    }

    static func makeRows(frame: Int) -> [GUIVisualRow] {
        (0..<rowCount).map { rowIndex in
            makeRow(rowIndex: rowIndex, frame: frame, revision: 0)
        }
    }

    static func mutateRows(_ rows: [GUIVisualRow], frame: Int) -> [GUIVisualRow] {
        var next = rows
        let rowIndex = frame % rowCount
        next[rowIndex] = makeRow(rowIndex: rowIndex, frame: frame, revision: frame + 1)
        return next
    }

    static func makeRow(rowIndex: Int, frame: Int, revision: Int) -> GUIVisualRow {
        let text = "def render_row_\(rowIndex)(_arg), do: {:ok, \(revision), \"The quick brown fox jumps over semantic row \(rowIndex) at frame \(frame)\"}"
        let spans = [
            GUIHighlightSpan(startCol: 0, endCol: 3, fg: 0xC678DD, bg: 0, attrs: 0x01, fontWeight: 2, fontId: 0),
            GUIHighlightSpan(startCol: 4, endCol: 18, fg: 0x61AFEF, bg: 0, attrs: 0x00, fontWeight: 2, fontId: 0),
            GUIHighlightSpan(startCol: 34, endCol: 38, fg: 0x98C379, bg: 0, attrs: 0x00, fontWeight: 2, fontId: 0),
            GUIHighlightSpan(startCol: 44, endCol: UInt16(min(text.count, 100)), fg: 0xE5C07B, bg: 0, attrs: 0x00, fontWeight: 2, fontId: 0)
        ]

        return GUIVisualRow(rowType: .normal, bufLine: UInt32(rowIndex), contentHash: stableHash(text), text: text, spans: spans)
    }

    static func stableHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }

    static func printMetric(_ name: String, _ value: Double) {
        print(String(format: "METRIC %@=%.2f", name, value))
    }
}
