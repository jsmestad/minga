/// Tests for PipelineCache: Metal binary archive caching for pipeline states.
///
/// Suite 1 (Stale Cleanup): Pure filesystem logic, no GPU needed.
/// Suite 2 (Cache Key): Requires a real MTLDevice + MTLLibrary.
/// Suite 3 (Round Trip): Full save/load cycle with a real GPU.

import Testing
import Foundation
import Metal

@testable import Minga

// MARK: - Stale Cache Cleanup (no GPU needed)

@Suite("PipelineCache — Stale Cleanup")
struct PipelineCacheCleanupTests {

    /// Creates a temporary directory for test isolation.
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Removes a temporary directory after the test.
    private func removeTempDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Removes cache files with non-matching hashes")
    func removesStaleFiles() throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        // Create three cache files: one current, two stale.
        let current = dir.appendingPathComponent("pipelines-aaa11111.metalarchive")
        let stale1 = dir.appendingPathComponent("pipelines-bbb22222.metalarchive")
        let stale2 = dir.appendingPathComponent("pipelines-ccc33333.metalarchive")
        for url in [current, stale1, stale2] {
            try Data("test".utf8).write(to: url)
        }

        PipelineCache.cleanStaleCaches(currentHash: "aaa11111", in: dir)

        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(!FileManager.default.fileExists(atPath: stale1.path))
        #expect(!FileManager.default.fileExists(atPath: stale2.path))
    }

    @Test("Leaves non-pipeline files untouched")
    func leavesOtherFiles() throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let other = dir.appendingPathComponent("something-else.txt")
        let stale = dir.appendingPathComponent("pipelines-old00000.metalarchive")
        try Data("keep me".utf8).write(to: other)
        try Data("stale".utf8).write(to: stale)

        PipelineCache.cleanStaleCaches(currentHash: "new11111", in: dir)

        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("No crash when directory is empty")
    func emptyDirectory() throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        // Should not throw or crash.
        PipelineCache.cleanStaleCaches(currentHash: "abc12345", in: dir)
    }

    @Test("No crash when directory does not exist")
    func missingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)", isDirectory: true)

        // Should not throw or crash (directory enumeration fails gracefully).
        PipelineCache.cleanStaleCaches(currentHash: "abc12345", in: dir)
    }
}

// MARK: - Cache URL Construction

@Suite("PipelineCache — Cache URL")
struct PipelineCacheURLTests {

    @Test("Cache URL uses correct filename format")
    func filenameFormat() {
        let dir = URL(fileURLWithPath: "/tmp/test-cache")
        let url = PipelineCache.cacheURL(hash: "abcd1234", in: dir)

        #expect(url.lastPathComponent == "pipelines-abcd1234.metalarchive")
        #expect(url.deletingLastPathComponent().path == "/tmp/test-cache")
    }

    @Test("Default directory points to ~/Library/Caches/com.minga.editor")
    func defaultDirectory() {
        let dir = PipelineCache.cacheDirectory
        #expect(dir.lastPathComponent == "com.minga.editor")
        #expect(dir.pathComponents.contains("Caches"))
    }
}

// MARK: - Cache Key (requires GPU)

@Suite("PipelineCache — Cache Key")
struct PipelineCacheKeyTests {

    /// Loads the Metal device and library, returning nil if unavailable.
    @MainActor
    private func loadMetal() -> (MTLDevice, MTLLibrary)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        if let lib = try? device.makeDefaultLibrary(bundle: Bundle.main) {
            return (device, lib)
        }
        let executableURL = Bundle.main.executableURL!
        let metallibURL = executableURL.deletingLastPathComponent()
            .appendingPathComponent("default.metallib")
        guard let lib = try? device.makeLibrary(URL: metallibURL) else { return nil }
        return (device, lib)
    }

    @Test("Same library and device produce deterministic hash")
    @MainActor func deterministicHash() throws {
        guard let (device, library) = loadMetal() else {
            // No GPU available (headless CI), skip.
            return
        }

        let hash1 = PipelineCache.libraryHash(library: library, device: device)
        let hash2 = PipelineCache.libraryHash(library: library, device: device)

        #expect(hash1 == hash2)
        #expect(hash1.count == 16, "Expected 8 bytes as 16 hex chars, got \(hash1.count)")
    }

    @Test("Hash is a valid hex string")
    @MainActor func validHex() throws {
        guard let (device, library) = loadMetal() else { return }

        let hash = PipelineCache.libraryHash(library: library, device: device)
        let hexCharSet = CharacterSet(charactersIn: "0123456789abcdef")

        #expect(hash.unicodeScalars.allSatisfy { hexCharSet.contains($0) },
                "Hash contains non-hex characters: \(hash)")
    }
}

// MARK: - Round Trip (requires GPU)

@Suite("PipelineCache — Round Trip")
struct PipelineCacheRoundTripTests {

    /// Creates a temporary directory for test isolation.
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-cache-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func removeTempDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Loads Metal device and library, builds pipeline descriptors matching CoreTextMetalRenderer.
    @MainActor
    private func setupMetal() -> (MTLDevice, MTLLibrary, MTLRenderPipelineDescriptor, MTLRenderPipelineDescriptor)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        let library: MTLLibrary
        if let lib = try? device.makeDefaultLibrary(bundle: Bundle.main) {
            library = lib
        } else {
            let executableURL = Bundle.main.executableURL!
            let metallibURL = executableURL.deletingLastPathComponent()
                .appendingPathComponent("default.metallib")
            guard let lib = try? device.makeLibrary(URL: metallibURL) else { return nil }
            library = lib
        }

        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = library.makeFunction(name: "ct_bg_vertex")
        bgDesc.fragmentFunction = library.makeFunction(name: "ct_bg_fragment")
        bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        bgDesc.colorAttachments[0].isBlendingEnabled = true
        bgDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        bgDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        bgDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        bgDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let lineDesc = MTLRenderPipelineDescriptor()
        lineDesc.vertexFunction = library.makeFunction(name: "ct_line_vertex")
        lineDesc.fragmentFunction = library.makeFunction(name: "ct_line_fragment")
        lineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        lineDesc.colorAttachments[0].isBlendingEnabled = true
        lineDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        lineDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        lineDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        lineDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return (device, library, bgDesc, lineDesc)
    }

    @Test("Save then load produces valid pipeline states")
    @MainActor func saveAndLoad() throws {
        guard let (device, library, bgDesc, lineDesc) = setupMetal() else { return }
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        // Save the compiled pipelines.
        PipelineCache.savePipelineCache(
            device: device, library: library,
            bgDescriptor: bgDesc, lineDescriptor: lineDesc,
            directory: dir
        )

        // Verify cache file was created.
        let hash = PipelineCache.libraryHash(library: library, device: device)
        let cacheFile = PipelineCache.cacheURL(hash: hash, in: dir)
        #expect(FileManager.default.fileExists(atPath: cacheFile.path),
                "Cache file should exist after save")

        // Load from cache.
        let result = PipelineCache.loadCachedPipelines(
            device: device, library: library,
            bgDescriptor: bgDesc, lineDescriptor: lineDesc,
            directory: dir
        )

        #expect(result != nil, "Should load cached pipelines successfully")
    }

    @Test("Load returns nil when no cache exists")
    @MainActor func loadMissingCache() throws {
        guard let (device, library, bgDesc, lineDesc) = setupMetal() else { return }
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        let result = PipelineCache.loadCachedPipelines(
            device: device, library: library,
            bgDescriptor: bgDesc, lineDescriptor: lineDesc,
            directory: dir
        )

        #expect(result == nil, "Should return nil when no cache file exists")
    }

    @Test("Corrupt cache returns nil and deletes the file")
    @MainActor func corruptCacheRecovery() throws {
        guard let (device, library, bgDesc, lineDesc) = setupMetal() else { return }
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        // Write garbage bytes to the expected cache path.
        let hash = PipelineCache.libraryHash(library: library, device: device)
        let cacheFile = PipelineCache.cacheURL(hash: hash, in: dir)
        try Data("this is not a valid metalarchive".utf8).write(to: cacheFile)
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))

        // Load should fail gracefully.
        let result = PipelineCache.loadCachedPipelines(
            device: device, library: library,
            bgDescriptor: bgDesc, lineDescriptor: lineDesc,
            directory: dir
        )

        #expect(result == nil, "Should return nil for corrupt cache")
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path),
                "Should delete corrupt cache file")
    }

    @Test("Descriptors are clean after failed cache load")
    @MainActor func descriptorsCleanAfterFailure() throws {
        guard let (device, library, bgDesc, lineDesc) = setupMetal() else { return }
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }

        // Write garbage to trigger a load failure.
        let hash = PipelineCache.libraryHash(library: library, device: device)
        let cacheFile = PipelineCache.cacheURL(hash: hash, in: dir)
        try Data("corrupt".utf8).write(to: cacheFile)

        _ = PipelineCache.loadCachedPipelines(
            device: device, library: library,
            bgDescriptor: bgDesc, lineDescriptor: lineDesc,
            directory: dir
        )

        // After a failed load, binaryArchives should be cleared so the
        // caller can safely fall back to runtime compilation.
        #expect(bgDesc.binaryArchives == nil || bgDesc.binaryArchives!.isEmpty,
                "bgDescriptor.binaryArchives should be nil after failed load")
        #expect(lineDesc.binaryArchives == nil || lineDesc.binaryArchives!.isEmpty,
                "lineDescriptor.binaryArchives should be nil after failed load")
    }
}
