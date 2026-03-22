/// Metal pipeline state binary archive cache.
///
/// Caches compiled render pipeline states to disk using `MTLBinaryArchive`
/// so subsequent launches skip runtime shader compilation (~50-100ms savings).
/// The cache is invalidated automatically when the Metal shader library changes
/// (detected via SHA-256 hash of the metallib binary).
///
/// Cache location: `~/Library/Caches/com.minga.editor/pipelines-<hash>.metalarchive`

import Metal
import CryptoKit
import os.log
import Foundation

private let pipelineLog = OSLog(subsystem: "com.minga.editor", category: "PipelineCache")

/// Manages loading and saving of Metal binary archives for pipeline state caching.
struct PipelineCache {

    /// Directory where pipeline caches are stored.
    /// Tests can override by passing a custom directory to load/save/clean methods.
    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.minga.editor", isDirectory: true)
    }

    /// Computes a SHA-256 hash of the Metal library's function names and device name
    /// to detect when shaders change (app update) or the GPU changes.
    ///
    /// We hash function names rather than the metallib binary because `MTLLibrary`
    /// doesn't expose its raw bytes. Function names change whenever shaders are
    /// added, removed, or renamed, which is the relevant invalidation signal.
    ///
    /// `internal` visibility so `@testable import` can verify hash determinism.
    static func libraryHash(library: MTLLibrary, device: MTLDevice) -> String {
        var hasher = SHA256()
        // Include device name to invalidate across GPU changes.
        if let deviceData = device.name.data(using: .utf8) {
            hasher.update(data: deviceData)
        }
        // Include all function names (sorted for determinism).
        for name in library.functionNames.sorted() {
            if let data = name.data(using: .utf8) {
                hasher.update(data: data)
            }
        }
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the cache file URL for a given library hash.
    ///
    /// `internal` visibility so `@testable import` can verify path construction.
    static func cacheURL(hash: String, in directory: URL? = nil) -> URL {
        let dir = directory ?? cacheDirectory
        return dir.appendingPathComponent("pipelines-\(hash).metalarchive")
    }

    /// Attempts to create pipeline states from a cached binary archive.
    ///
    /// Returns `nil` if the cache doesn't exist, is corrupt, or fails to load.
    /// On success, returns both pipeline states and logs the time saved.
    ///
    /// On success, `binaryArchives` is set on both descriptors. On failure,
    /// `binaryArchives` is cleared so callers can safely fall back to runtime compilation.
    ///
    /// Pass a custom `directory` to override the default cache location (used in tests).
    static func loadCachedPipelines(
        device: MTLDevice,
        library: MTLLibrary,
        bgDescriptor: MTLRenderPipelineDescriptor,
        lineDescriptor: MTLRenderPipelineDescriptor,
        directory: URL? = nil
    ) -> (bg: MTLRenderPipelineState, line: MTLRenderPipelineState)? {
        let hash = libraryHash(library: library, device: device)
        let url = cacheURL(hash: hash, in: directory)

        guard FileManager.default.fileExists(atPath: url.path) else {
            os_log(.info, log: pipelineLog, "No pipeline cache found, will compile from shaders")
            return nil
        }

        let archiveDesc = MTLBinaryArchiveDescriptor()
        archiveDesc.url = url

        do {
            let archive = try device.makeBinaryArchive(descriptor: archiveDesc)

            // Set the archive on both descriptors so Metal looks up precompiled state.
            bgDescriptor.binaryArchives = [archive]
            lineDescriptor.binaryArchives = [archive]

            let bgPipeline = try device.makeRenderPipelineState(descriptor: bgDescriptor)
            let linePipeline = try device.makeRenderPipelineState(descriptor: lineDescriptor)

            os_log(.info, log: pipelineLog, "Loaded pipeline states from cache")
            return (bgPipeline, linePipeline)
        } catch {
            os_log(.error, log: pipelineLog, "Failed to load pipeline cache (will recompile): %{public}@",
                   error.localizedDescription)
            // Clear stale archive references so the caller's descriptors are
            // clean for runtime compilation fallback.
            bgDescriptor.binaryArchives = nil
            lineDescriptor.binaryArchives = nil
            // Clean up corrupt cache file.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// Saves compiled pipeline states to a binary archive on disk.
    ///
    /// Called after first-time shader compilation. Errors are logged but
    /// don't affect the running app (the pipelines are already compiled).
    ///
    /// Pass a custom `directory` to override the default cache location (used in tests).
    static func savePipelineCache(
        device: MTLDevice,
        library: MTLLibrary,
        bgDescriptor: MTLRenderPipelineDescriptor,
        lineDescriptor: MTLRenderPipelineDescriptor,
        directory: URL? = nil
    ) {
        let dir = directory ?? cacheDirectory
        let hash = libraryHash(library: library, device: device)
        let url = cacheURL(hash: hash, in: directory)

        do {
            // Ensure cache directory exists.
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )

            // Clean up old cache files with different hashes.
            cleanStaleCaches(currentHash: hash, in: dir)

            let archive = try device.makeBinaryArchive(descriptor: MTLBinaryArchiveDescriptor())
            try archive.addRenderPipelineFunctions(descriptor: bgDescriptor)
            try archive.addRenderPipelineFunctions(descriptor: lineDescriptor)
            try archive.serialize(to: url)

            os_log(.info, log: pipelineLog, "Saved pipeline cache to %{public}@", url.lastPathComponent)
        } catch {
            os_log(.error, log: pipelineLog, "Failed to save pipeline cache: %{public}@",
                   error.localizedDescription)
        }
    }

    /// Removes pipeline cache files that don't match the current hash.
    /// This prevents stale caches from accumulating across app updates.
    ///
    /// Pass a custom `directory` to override the default cache location (used in tests).
    static func cleanStaleCaches(currentHash: String, in directory: URL? = nil) {
        let dir = directory ?? cacheDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }

        let currentFilename = "pipelines-\(currentHash).metalarchive"
        for file in contents where file.lastPathComponent.hasPrefix("pipelines-")
            && file.lastPathComponent.hasSuffix(".metalarchive")
            && file.lastPathComponent != currentFilename {
            try? FileManager.default.removeItem(at: file)
            os_log(.info, log: pipelineLog, "Cleaned stale cache: %{public}@", file.lastPathComponent)
        }
    }
}
