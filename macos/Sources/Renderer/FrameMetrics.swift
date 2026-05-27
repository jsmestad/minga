/// Per-frame render metrics collected at the CoreText/Metal render boundary.
///
/// These counters are reset at the start of each frame and emitted through os_signpost so Instruments can show whether a frame reused cached textures or spent time rasterizing and uploading new atlas content.
struct FrameMetrics: Equatable {
    var bufferRowsRasterized: Int = 0
    var bufferRowsReused: Int = 0
    var otherTexturesRasterized: Int = 0
    var otherTexturesReused: Int = 0
    var textureUploads: Int = 0
    var textureUploadBytes: Int = 0
    var atlasNewKeys: Int = 0
    var atlasHashChanges: Int = 0
    var atlasEvictions: Int = 0

    /// Reset all counters for a new frame.
    mutating func reset() {
        bufferRowsRasterized = 0
        bufferRowsReused = 0
        otherTexturesRasterized = 0
        otherTexturesReused = 0
        textureUploads = 0
        textureUploadBytes = 0
        atlasNewKeys = 0
        atlasHashChanges = 0
        atlasEvictions = 0
    }

    /// Record an atlas miss reason against the appropriate per-frame counter.
    mutating func recordMiss(_ reason: MissReason) {
        switch reason {
        case .newKey:
            atlasNewKeys += 1
        case .hashChanged:
            atlasHashChanges += 1
        case .evicted(_):
            atlasEvictions += 1
        }
    }
}
