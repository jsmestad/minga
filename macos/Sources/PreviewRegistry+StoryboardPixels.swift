import AppKit

/// Colours read from a captured storyboard window, for the layout audit's contrast rule (#4036).
///
/// The surface under a part is its most common colour. Text is antialiased, so its edge pixels are blends of the
/// surface and the ink; the ink itself is the colour farthest from the surface in its direction that still covers a
/// few pixels, the full-coverage stem of a glyph. Colours are hex strings so the audit never decodes the PNG.
struct StoryboardPixels {
    private let width: Int
    private let height: Int
    private let rgb: [UInt32]
    let scale: CGFloat

    init?(png: Data, scale: CGFloat) {
        guard let bitmap = NSBitmapImageRep(data: png),
              let srgb = bitmap.converting(to: .sRGB, renderingIntent: .default) else { return nil }
        width = srgb.pixelsWide
        height = srgb.pixelsHigh
        self.scale = scale
        var pixels = [UInt32](repeating: 0, count: width * height)
        let samples = srgb.samplesPerPixel
        guard let data = srgb.bitmapData, srgb.bitsPerSample == 8 else { return nil }
        let rowBytes = srgb.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let base = y * rowBytes + x * samples
                pixels[y * width + x] = (UInt32(data[base]) << 16) | (UInt32(data[base + 1]) << 8) | UInt32(data[base + 2])
            }
        }
        rgb = pixels
    }

    /// The surface and the inks under a part given in window points, or nil for an empty frame. The surface is the
    /// most common colour; each ink is the farthest colour in its direction from the surface that covers a few pixels,
    /// so an icon and the words beside it come out as two inks and their antialiased edges as none.
    func sample(_ frame: CGRect, excluding covered: CGRect? = nil) -> (inks: [String], bg: String)? {
        guard let histogram = histogram(frame, excluding: covered),
              let bg = histogram.counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let counts = histogram.counts
        let visible = counts.filter { $0.key != bg && Self.distance($0.key, bg) > 24 }
        let floor = max(3, (visible.values.max() ?? 0) / 20)
        let candidates = visible.filter { $0.value >= floor }
            .sorted { Self.distance($0.key, bg) > Self.distance($1.key, bg) }
        var kept: [UInt32] = []
        for (color, _) in candidates where !kept.contains(where: { Self.sameDirection(color, $0, from: bg) }) {
            kept.append(color)
        }
        return kept.isEmpty ? nil : (kept.map(Self.hex).sorted(), Self.hex(bg))
    }

    /// The surface and every distinct ink in a frame: per direction away from a surface, the farthest colour that
    /// covers enough pixels to be a stem. A region can have several surfaces (the editor background, the cursor
    /// line, a selection); a colour that lies between any surface and a kept ink is an antialiased edge, not an ink.
    /// Syntax colours in the editor come out once each.
    func inks(_ frame: CGRect, minimumPixels: Int = 12, excluding covered: CGRect? = nil) -> (bg: String, inks: [String])? {
        guard let histogram = histogram(frame, excluding: covered, identifyBands: covered != nil),
              let bg = histogram.counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let counts = histogram.counts
        let total = counts.values.reduce(0, +)
        var surfaces = histogram.bands
        for (color, count) in counts where count * 50 >= total {
            surfaces.insert(color)
        }
        let visible = counts.filter { entry in
            !surfaces.contains(entry.key) && surfaces.allSatisfy { Self.distance(entry.key, $0) > 24 }
        }
        // A glyph's stems repeat its ink many times; an antialiased blend is scattered. Keep colours that cover at
        // least a twentieth as many pixels as the most common ink.
        let floor = max(minimumPixels, (visible.values.max() ?? 0) / 20)
        let candidates = visible.filter { $0.value >= floor }
            .sorted { Self.distance($0.key, bg) > Self.distance($1.key, bg) }
        var kept: [UInt32] = []
        for (color, _) in candidates where !kept.contains(where: { ink in
            surfaces.contains { Self.sameDirection(color, ink, from: $0) && Self.distance(color, $0) < Self.distance(ink, $0) }
        }) {
            kept.append(color)
        }
        return (Self.hex(bg), kept.map(Self.hex).sorted())
    }

    private func histogram(_ frame: CGRect, excluding covered: CGRect?, identifyBands: Bool = false)
        -> (counts: [UInt32: Int], bands: Set<UInt32>)? {
        let x0 = max(Int((frame.minX * scale).rounded(.down)), 0)
        let y0 = max(Int((frame.minY * scale).rounded(.down)), 0)
        let x1 = min(Int((frame.maxX * scale).rounded(.up)), width)
        let y1 = min(Int((frame.maxY * scale).rounded(.up)), height)
        guard x1 > x0, y1 > y0 else { return nil }
        let hole = covered.map { $0.intersection(frame) } ?? .null
        let maskX0 = hole.isNull ? x1 : max(x0, Int((hole.minX * scale).rounded(.down)))
        let maskX1 = hole.isNull ? x1 : min(x1, Int((hole.maxX * scale).rounded(.up)))
        let maskY0 = hole.isNull ? y1 : max(y0, Int((hole.minY * scale).rounded(.down)))
        let maskY1 = hole.isNull ? y1 : min(y1, Int((hole.maxY * scale).rounded(.up)))
        var counts: [UInt32: Int] = [:]
        var bands: Set<UInt32> = []
        // Masking a modal can leave a cursor-line band below the global surface threshold.
        // A continuous fill spanning an eighth of the editor width is a surface, not a glyph stem.
        let bandWidth = identifyBands ? max(1, (x1 - x0) / 8) : nil
        func add(_ span: Range<Int>, row: Int) {
            if let bandWidth {
                var previous: UInt32 = 0
                var run = 0
                for x in span {
                    let color = rgb[row + x]
                    counts[color, default: 0] += 1
                    run = color == previous ? run + 1 : 1
                    previous = color
                    if run == bandWidth { bands.insert(color) }
                }
            } else {
                for x in span { counts[rgb[row + x], default: 0] += 1 }
            }
        }
        for y in y0..<y1 {
            let row = y * width
            if y >= maskY0 && y < maskY1 {
                add(x0..<maskX0, row: row)
                add(maskX1..<x1, row: row)
            } else {
                add(x0..<x1, row: row)
            }
        }
        return (counts, bands)
    }

    private static func channels(_ color: UInt32) -> (Double, Double, Double) {
        (Double(color >> 16 & 255), Double(color >> 8 & 255), Double(color & 255))
    }

    private static func distance(_ a: UInt32, _ b: UInt32) -> Double {
        let (ar, ag, ab) = channels(a), (br, bg, bb) = channels(b)
        return ((ar - br) * (ar - br) + (ag - bg) * (ag - bg) + (ab - bb) * (ab - bb)).squareRoot()
    }

    /// True when `a` lies on the blend from `surface` toward `b`: an antialiased edge of the same ink.
    private static func sameDirection(_ a: UInt32, _ b: UInt32, from surface: UInt32) -> Bool {
        let (sr, sg, sb) = channels(surface), (ar, ag, ab) = channels(a), (br, bg, bb) = channels(b)
        let va = (ar - sr, ag - sg, ab - sb), vb = (br - sr, bg - sg, bb - sb)
        let dot = va.0 * vb.0 + va.1 * vb.1 + va.2 * vb.2
        let na = (va.0 * va.0 + va.1 * va.1 + va.2 * va.2).squareRoot()
        let nb = (vb.0 * vb.0 + vb.1 * vb.1 + vb.2 * vb.2).squareRoot()
        guard na > 0, nb > 0 else { return true }
        return dot / (na * nb) > 0.99
    }

    private static func hex(_ color: UInt32) -> String { String(format: "#%06x", color) }
}
