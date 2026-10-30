import Foundation
import Metal
import Testing
@testable import MingaUI

/// A transcript owns one device, renderer, font and readback queue for its entire
/// sequence. Every sampled image comes from the dispatcher's newly committed
/// snapshot, never a reconstructed FrameState or an earlier accepted frame.
@MainActor
final class ConformancePixelRunner {
    nonisolated static var canRun: Bool {
        ProcessInfo.processInfo.environment["MINGA_REQUIRE_METAL"] == "1"
            || !MTLCopyAllDevices().isEmpty
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fontManager: FontManager
    private let renderer: CoreTextMetalRenderer
    private let waiter: PresentationWaiter

    init() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(),
            "Metal unavailable; MINGA_REQUIRE_METAL=1 requires a real Metal device")
        let queue = try #require(device.makeCommandQueue(), "Metal readback queue unavailable")
        let fontManager = FontManager(name: "Menlo", size: 13, scale: 1)
        let waiter = PresentationWaiter()
        var factories = offscreenNativeTestFactories()
        factories.reportFailure = { waiter.fail($0) }
        self.renderer = try #require(makeOffscreenRenderer(
            device: device, factories: factories, fontManager: fontManager),
            "Production Metal renderer or shader library unavailable")
        self.device = device
        self.queue = queue
        self.fontManager = fontManager
        self.waiter = waiter
    }

    /// An applied shell-only frame can retain an older editor snapshot. Pixel
    /// evidence belongs only to the exact transaction that published the editor.
    static func snapshotForPixels(_ snapshot: CommittedEditorSnapshot?, result: FrameTransactionResult?)
        -> CommittedEditorSnapshot? {
        guard case .applied(let generation, let frameSeq)? = result,
              let snapshot, snapshot.generation == generation, snapshot.frameSeq == frameSeq else {
            return nil
        }
        return snapshot
    }

    func assertPixels(step: [String: Any], snapshot: CommittedEditorSnapshot?, result: FrameTransactionResult?,
                      rowOffsets: [UInt16: Int], colOffsets: [UInt16: Int],
                      name: String, index: Int) async throws {
        guard let expect = step["expect"] as? [String: Any],
              let regions = expect["pixels"] as? [[String: Any]] else { return }
        let context = "\(name) step \(index)"
        #expect(step["swift_only"] as? Bool == true,
                "\(context): expect.pixels requires swift_only: true (model assertions still run in Go)")
        guard let snapshot = Self.snapshotForPixels(snapshot, result: result) else {
            Issue.record("\(context): no committed snapshot for pixel expectations matching this transaction (missing, rejected, or retained from another frame)")
            return
        }
        let cellWidth = Double(fontManager.cellWidth)
        let cellHeight = Double(fontManager.cellHeight) * Double(snapshot.frameState.lineSpacing)
        let width = Int(ceil(Double(snapshot.frameState.cols) * cellWidth))
        let height = Int(ceil(Double(snapshot.frameState.rows) * cellHeight))
        let texture = try #require(OffscreenReadback.makeDrawableTexture(
            device: device, width: width, height: height), "\(context): drawable unavailable")
        let drawable = ReadbackDrawable(texture: texture, drawableID: index + 1)
        let windowID = snapshot.activeSurface?.windowId
        let offset = SIMD2<Float>(
            Float(colOffsets[windowID ?? 1] ?? 0) * Float(cellWidth),
            Float(rowOffsets[windowID ?? 1] ?? 0) * Float(cellHeight))
        let outcome = await waiter.awaitOutcome {
            renderer.render(snapshot: snapshot, fontManager: fontManager,
                cursorBlinkVisible: false, drawableProvider: { drawable },
                viewportSize: CGSize(width: width, height: height), contentScale: 1,
                scrollOffset: offset, presentationWindowId: windowID,
                presentationInputSeq: UInt32(index + 1), onPresented: { self.waiter.succeed($0) })
        }
        guard case .presented = outcome else {
            Issue.record("\(context): production render did not present: \(outcome)")
            return
        }
        #expect(drawable.presentCount == 1, "\(context): render must present exactly once")
        let image = try #require(await OffscreenReadback.read(texture: texture, queue: queue),
                                 "\(context): Metal readback failed")
        for region in regions {
            try Self.assertRegion(region, image: image, cellWidth: cellWidth,
                                  cellHeight: cellHeight, context: context)
        }
    }

    /// Cell coordinates are editor-surface absolute, top-left origin. Fractional
    /// cells allow sampling the final row/column without introducing pixel units.
    static func pixelBounds(cells: [Double], cellWidth: Double, cellHeight: Double)
        -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        (Int(floor(cells[1] * cellWidth)), Int(floor(cells[0] * cellHeight)),
         Int(ceil((cells[1] + cells[3]) * cellWidth)),
         Int(ceil((cells[0] + cells[2]) * cellHeight)))
    }

    static func fixtureColor(_ hex: String) -> PixelColor? {
        guard hex.hasPrefix("0x"), hex.count == 8,
              let rgb = UInt32(hex.dropFirst(2), radix: 16) else { return nil }
        return PixelColor(r: Double((rgb >> 16) & 255) / 255,
                          g: Double((rgb >> 8) & 255) / 255,
                          b: Double(rgb & 255) / 255, a: 1)
    }

    static func assertRegion(_ region: [String: Any], image: ReadbackImage,
                             cellWidth: Double, cellHeight: Double, context: String) throws {
        let label = "\(context) region \(region["region"] as? String ?? "<unnamed>")"
        let cells = try #require(region["cells"] as? [Double], "\(label): cells must be [row,col,rows,cols]")
        guard cells.count == 4, cells.allSatisfy({ $0.isFinite && $0 >= 0 }),
              cells[2] > 0, cells[3] > 0 else {
            Issue.record("\(label): invalid cell region \(cells)")
            return
        }
        let bounds = pixelBounds(cells: cells, cellWidth: cellWidth, cellHeight: cellHeight)
        guard bounds.x0 >= 0, bounds.y0 >= 0, bounds.x1 <= image.width,
              bounds.y1 <= image.height, bounds.x1 > bounds.x0, bounds.y1 > bounds.y0 else {
            Issue.record("\(label): cell region \(cells) exceeds \(image.width)x\(image.height) drawable")
            return
        }
        let color = try #require(fixtureColor(region["color"] as? String ?? "0x202020"),
                                "\(label): expected fixture color in 0xRRGGBB format")
        let tolerance = region["tolerance"] as? Double ?? 0.02
        guard tolerance.isFinite, tolerance >= 0 else {
            Issue.record("\(label): invalid squared RGB tolerance \(tolerance)")
            return
        }
        let center = image.pixel(x: (bounds.x0 + bounds.x1 - 1) / 2,
                                 y: (bounds.y0 + bounds.y1 - 1) / 2)
        let sample = "\(label): cells=\(cells), sampled center RGBA=(\(center.r),\(center.g),\(center.b),\(center.a)), reference=\(color), tolerance²=\(tolerance)"
        switch region["assert"] as? String {
        case "color":
            let matching = image.matching(x0: bounds.x0, y0: bounds.y0, x1: bounds.x1, y1: bounds.y1,
                                          reference: color, thresholdSquared: tolerance)
            let area = (bounds.x1 - bounds.x0) * (bounds.y1 - bounds.y0)
            #expect(matching == area, "\(sample); matching=\(matching)/\(area)")
        case "occupied", "empty":
            let occupancy = image.occupancy(x0: bounds.x0, y0: bounds.y0, x1: bounds.x1, y1: bounds.y1,
                                            differingFrom: color, thresholdSquared: tolerance)
            if region["assert"] as? String == "occupied" {
                #expect(occupancy > 0, "\(sample); glyph occupancy=\(occupancy)")
            } else {
                #expect(occupancy == 0, "\(sample); glyph occupancy=\(occupancy)")
            }
        default:
            Issue.record("\(sample); unknown pixel assertion \(String(describing: region["assert"]))")
        }
    }
}
