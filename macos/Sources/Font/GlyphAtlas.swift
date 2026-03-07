/// Texture atlas for packing glyph bitmaps using a skyline bin-packing algorithm.
///
/// Manages a square BGRA texture that stores rasterized glyphs. The atlas
/// grows on demand (512 → 1024 → 2048 → ...) when space runs out.
/// Consumers check `modified` to know when to re-upload to the GPU.

import Foundation

/// A rectangular region in the atlas.
struct AtlasRegion {
    let x: UInt32
    let y: UInt32
    let width: UInt32
    let height: UInt32
}

/// Skyline bin-packing atlas for BGRA glyph bitmaps.
final class GlyphAtlas {
    /// Raw BGRA pixel data (row-major, size * size * 4 bytes).
    private(set) var data: [UInt8]
    /// Width and height of the atlas (always square).
    private(set) var size: UInt32

    /// Skyline nodes tracking the top edge of allocated space.
    private var nodes: [SkylineNode]

    /// Incremented on every modification. Compare against a cached value
    /// to know when to re-upload to the GPU.
    private(set) var modified: Int = 0

    /// Incremented on every resize (requires creating a new GPU texture).
    private(set) var resized: Int = 0

    private struct SkylineNode {
        var x: UInt32
        var y: UInt32
        var width: UInt32
    }

    init(initialSize: UInt32) {
        self.size = initialSize
        self.data = [UInt8](repeating: 0, count: Int(initialSize) * Int(initialSize) * 4)
        self.nodes = [SkylineNode(x: 0, y: 0, width: initialSize)]
    }

    /// Reserve a region of `width x height` pixels.
    /// Returns nil if the atlas is full (caller should grow and retry).
    func reserve(width: UInt32, height: UInt32) -> AtlasRegion? {
        if width == 0 && height == 0 {
            return AtlasRegion(x: 0, y: 0, width: 0, height: 0)
        }

        // Find best-fit node (lowest y, then narrowest).
        var bestH: UInt32 = .max
        var bestW: UInt32 = .max
        var bestIdx: Int?
        var bestX: UInt32 = 0
        var bestY: UInt32 = 0

        for i in nodes.indices {
            guard let y = fit(index: i, width: width, height: height) else { continue }
            if (y + height) < bestH || ((y + height) == bestH && nodes[i].width < bestW) {
                bestIdx = i
                bestW = nodes[i].width
                bestH = y + height
                bestX = nodes[i].x
                bestY = y
            }
        }

        guard let idx = bestIdx else { return nil }

        // Insert new skyline node.
        nodes.insert(SkylineNode(x: bestX, y: bestY + height, width: width), at: idx)

        // Shrink/remove overlapping nodes to the right.
        var i = idx + 1
        while i < nodes.count {
            let prev = nodes[i - 1]
            if nodes[i].x < prev.x + prev.width {
                let shrink = prev.x + prev.width - nodes[i].x
                nodes[i].x += shrink
                if nodes[i].width <= shrink {
                    nodes.remove(at: i)
                    continue
                }
                nodes[i].width -= shrink
            }
            i += 1
        }

        // Merge adjacent nodes at the same y.
        merge()
        modified += 1

        return AtlasRegion(x: bestX, y: bestY, width: width, height: height)
    }

    /// Write pixel data into a region of the atlas.
    func set(x: UInt32, y: UInt32, width: UInt32, height: UInt32, data source: [UInt8]) {
        let depth = 4 // BGRA
        let atlasStride = Int(size) * depth
        let sourceStride = Int(width) * depth

        for row in 0..<Int(height) {
            let srcStart = row * sourceStride
            let dstStart = (Int(y) + row) * atlasStride + Int(x) * depth

            guard srcStart + sourceStride <= source.count,
                  dstStart + sourceStride <= self.data.count else { continue }

            self.data.replaceSubrange(dstStart..<(dstStart + sourceStride),
                                      with: source[srcStart..<(srcStart + sourceStride)])
        }

        modified += 1
    }

    /// Grow the atlas to a new (larger) square size. Copies existing data.
    func grow(newSize: UInt32) {
        guard newSize > size else { return }

        let depth = 4
        var newData = [UInt8](repeating: 0, count: Int(newSize) * Int(newSize) * depth)

        // Copy existing rows.
        let oldStride = Int(size) * depth
        let newStride = Int(newSize) * depth
        for row in 0..<Int(size) {
            let srcStart = row * oldStride
            let dstStart = row * newStride
            newData.replaceSubrange(dstStart..<(dstStart + oldStride),
                                    with: data[srcStart..<(srcStart + oldStride)])
        }

        data = newData
        size = newSize
        resized += 1
        modified += 1
    }

    // MARK: - Private

    /// Check if a region fits at the given node index.
    /// Returns the y coordinate it would sit at, or nil if it doesn't fit.
    private func fit(index: Int, width: UInt32, height: UInt32) -> UInt32? {
        let node = nodes[index]
        guard node.x + width <= size else { return nil }

        var y = node.y
        var remainingWidth: Int64 = Int64(width)
        var i = index

        while remainingWidth > 0 {
            guard i < nodes.count else { return nil }
            y = max(y, nodes[i].y)
            guard y + height <= size else { return nil }
            remainingWidth -= Int64(nodes[i].width)
            i += 1
        }

        return y
    }

    /// Merge adjacent nodes that share the same y coordinate.
    private func merge() {
        var i = 0
        while i + 1 < nodes.count {
            if nodes[i].y == nodes[i + 1].y {
                nodes[i].width += nodes[i + 1].width
                nodes.remove(at: i + 1)
            } else {
                i += 1
            }
        }
    }
}
