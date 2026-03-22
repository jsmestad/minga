/// A cached line texture with its content hash for invalidation.
///
/// Used by WindowContentRenderer to cache rasterized CTLine textures
/// in Metal for content and gutter rendering.

import Metal

struct CachedLineTexture {
    /// The Metal texture containing the rendered line.
    let texture: MTLTexture
    /// Content hash for cache invalidation.
    let contentHash: Int
    /// Frame number when this texture was last used (for LRU eviction).
    var lastUsedFrame: UInt64
    /// Pixel width of the rendered content.
    let pixelWidth: Int
    /// Pixel height of the rendered content.
    let pixelHeight: Int
}
