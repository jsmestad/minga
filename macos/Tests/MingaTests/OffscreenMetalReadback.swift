import Foundation
import Metal
import QuartzCore
@testable import MingaUI

/// Test-only offscreen Metal readback harness for the temporal renderer
/// acceptance tests.
///
/// The production renderer draws into a private target and then blits into a
/// `CAMetalDrawable`. To assert on real GPU-rendered, drawable-copy-completed
/// pixels without blocking the main actor, each fake drawable owns a uniquely
/// allocated `bgra8Unorm_srgb` texture. After `onPresented` fires, we read that texture through a
/// dedicated test queue blit into a `storageModeShared` buffer whose
/// `bytesPerRow` is rounded up to 256. Completion is awaited asynchronously via
/// `addCompletedHandler` bridged to a continuation, never `waitUntilCompleted`,
/// never a semaphore/sleep/run-loop spin, and never blocking the main actor.

/// A `CAMetalDrawable` that owns its own texture so out-of-order A/B frames
/// cannot alias one shared surface.
final class ReadbackDrawable: NSObject, CAMetalDrawable {
    let texture: MTLTexture
    let layer = CAMetalLayer()
    let drawableID: Int
    let presentedTime: CFTimeInterval = 0
    private(set) var presentCount = 0

    init(texture: MTLTexture, drawableID: Int = 1) {
        self.texture = texture
        self.drawableID = drawableID
    }

    func present() { presentCount += 1 }
    func present(at presentationTime: CFTimeInterval) { presentCount += 1; _ = presentationTime }
    func present(afterMinimumDuration duration: CFTimeInterval) { presentCount += 1; _ = duration }
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) { _ = block }
}

/// A single normalized (0...1) BGRA pixel color sample.
struct PixelColor: Equatable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    /// Squared Euclidean RGB distance to another color; cheap classifier metric.
    func rgbDistanceSquared(to other: PixelColor) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return dr * dr + dg * dg + db * db
    }
}

/// A CPU-side snapshot of a presented drawable texture.
struct ReadbackImage {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    /// Sample the pixel at (x, y). Texture bytes are BGRA8 (sRGB-encoded).
    func pixel(x: Int, y: Int) -> PixelColor {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel out of bounds")
        let offset = y * bytesPerRow + x * 4
        let b = Double(bytes[offset + 0]) / 255.0
        let g = Double(bytes[offset + 1]) / 255.0
        let r = Double(bytes[offset + 2]) / 255.0
        let a = Double(bytes[offset + 3]) / 255.0
        return PixelColor(r: r, g: g, b: b, a: a)
    }

    /// Count pixels inside a rectangle whose RGB distance to `reference`
    /// exceeds `threshold` (squared). Used to prove occupancy while tolerating
    /// antialiasing at glyph edges.
    func occupancy(x0: Int, y0: Int, x1: Int, y1: Int,
                   differingFrom reference: PixelColor, thresholdSquared: Double) -> Int {
        var count = 0
        let lox = max(0, x0), loy = max(0, y0)
        let hix = min(width, x1), hiy = min(height, y1)
        var y = loy
        while y < hiy {
            var x = lox
            while x < hix {
                if pixel(x: x, y: y).rgbDistanceSquared(to: reference) > thresholdSquared {
                    count += 1
                }
                x += 1
            }
            y += 1
        }
        return count
    }

    /// Count pixels whose RGB distance from `reference` is within `thresholdSquared`.
    func matching(x0: Int, y0: Int, x1: Int, y1: Int,
                  reference: PixelColor, thresholdSquared: Double) -> Int {
        var count = 0
        let lox = max(0, x0), loy = max(0, y0)
        let hix = min(width, x1), hiy = min(height, y1)
        var y = loy
        while y < hiy {
            var x = lox
            while x < hix {
                if pixel(x: x, y: y).rgbDistanceSquared(to: reference) <= thresholdSquared {
                    count += 1
                }
                x += 1
            }
            y += 1
        }
        return count
    }

    /// Classify every pixel in a rectangle as nearer to `a` or `b`.
    /// Returns (aCount, bCount, ambiguousCount) where ambiguous pixels are
    /// within `ambiguousBand` (squared) of the midpoint distance — i.e. edge
    /// antialiasing that belongs to neither region.
    func classifyAB(x0: Int, y0: Int, x1: Int, y1: Int,
                    a: PixelColor, b: PixelColor,
                    ambiguousBand: Double) -> (a: Int, b: Int, ambiguous: Int) {
        var aCount = 0, bCount = 0, ambiguous = 0
        let lox = max(0, x0), loy = max(0, y0)
        let hix = min(width, x1), hiy = min(height, y1)
        var y = loy
        while y < hiy {
            var x = lox
            while x < hix {
                let p = pixel(x: x, y: y)
                let da = p.rgbDistanceSquared(to: a)
                let db = p.rgbDistanceSquared(to: b)
                if abs(da - db) <= ambiguousBand {
                    ambiguous += 1
                } else if da < db {
                    aCount += 1
                } else {
                    bCount += 1
                }
                x += 1
            }
            y += 1
        }
        return (aCount, bCount, ambiguous)
    }
}

enum OffscreenReadback {
    /// Round `value` up to the nearest multiple of `alignment`.
    static func alignUp(_ value: Int, to alignment: Int) -> Int {
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }

    /// Allocate a fresh, uniquely owned `bgra8Unorm_srgb` texture usable both as
    /// the renderer's blit destination and as a blit source for readback.
    static func makeDrawableTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Read `texture` back into a CPU image via a test-queue blit to a
    /// `storageModeShared` buffer, awaiting GPU completion asynchronously.
    @MainActor
    static func read(texture: MTLTexture, queue: MTLCommandQueue) async -> ReadbackImage? {
        guard texture.device.registryID == queue.device.registryID else { return nil }
        let device = texture.device
        let width = texture.width
        let height = texture.height
        let bytesPerRow = alignUp(width * 4, to: 256)
        let byteCount = bytesPerRow * height
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return nil }

        blit.copy(
            from: texture,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: byteCount
        )
        blit.endEncoding()

        let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            cmd.addCompletedHandler { @Sendable completed in
                continuation.resume(returning: completed.status == .completed)
            }
            cmd.commit()
        }
        guard completed else { return nil }

        let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: byteCount)
        let bytes = Array(UnsafeBufferPointer(start: pointer, count: byteCount))
        return ReadbackImage(width: width, height: height, bytesPerRow: bytesPerRow, bytes: bytes)
    }
}

/// Terminal outcome of one production render: exactly one of these fires for a
/// frame that is neither superseded nor discarded.
enum PresentationOutcome {
    case presented(CommittedEditorSnapshot)
    case failed(NativePresentationFailure)
}

/// Bridges the renderer's asynchronous, production-style `onPresented` /
/// `reportFailure` callbacks to a single `await`. Resumes on the first terminal
/// event, so success and failure paths both make progress without any timeout,
/// sleep, or main-actor block.
@MainActor
final class PresentationWaiter {
    private enum State {
        case idle
        case awaiting(CheckedContinuation<PresentationOutcome, Never>)
    }

    private var state = State.idle

    func succeed(_ snapshot: CommittedEditorSnapshot) { finish(.presented(snapshot)) }
    func fail(_ failure: NativePresentationFailure) { finish(.failed(failure)) }

    private func finish(_ outcome: PresentationOutcome) {
        guard case .awaiting(let continuation) = state else { return }
        state = .idle
        continuation.resume(returning: outcome)
    }

    /// Verifies the previous frame completed before this waiter is reused.
    func reset() {
        guard case .idle = state else {
            preconditionFailure("cannot reset while awaiting a presentation outcome")
        }
    }

    /// Runs `body` (which starts the render) and awaits the first terminal event.
    func awaitOutcome(running body: @MainActor () -> Void) async -> PresentationOutcome {
        await withCheckedContinuation { continuation in
            guard case .idle = state else {
                preconditionFailure("cannot await two presentation outcomes concurrently")
            }
            state = .awaiting(continuation)
            body()
        }
    }
}

/// Deterministically re-orders production `addCompletedHandler` completions
/// without faking their success/status. GPU work still runs for real (so pixels
/// are real); only the main-actor *delivery* of each completion is queued so a
/// test can promote frames out of submission order.
@MainActor
final class QueuedCompletionCoordinator {
    private var pending: [() -> Void] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    /// The production-style observeCompletion seam: real `addCompletedHandler`
    /// plus `Task { @MainActor }`, but the completion closure is enqueued for
    /// deterministic draining instead of being invoked immediately.
    func observeCompletion(_ commandBuffer: MTLCommandBuffer,
                           _ completion: @escaping @MainActor @Sendable (Bool, Int) -> Void) {
        commandBuffer.addCompletedHandler { @Sendable completed in
            let succeeded = completed.status == .completed
            let status = Int(completed.status.rawValue)
            Task { @MainActor in
                self.enqueue { completion(succeeded, status) }
            }
        }
    }

    private func enqueue(_ work: @escaping () -> Void) {
        pending.append(work)
        resumeSatisfiedWaiters()
    }

    private func resumeSatisfiedWaiters() {
        waiters.removeAll { count, cont in
            if pending.count >= count {
                cont.resume()
                return true
            }
            return false
        }
    }

    /// Suspend until at least `count` completions have been enqueued.
    func waitForPending(_ count: Int) async {
        if pending.count >= count { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append((count, cont))
        }
    }

    /// Invoke and remove the first pending completion. Invoking a completion may
    /// enqueue a follow-on completion (the presentation-copy stage).
    func flushFirst() {
        guard !pending.isEmpty else { return }
        let work = pending.removeFirst()
        work()
    }

    /// Invoke the most recently enqueued completion so tests can deliver a newer serially submitted frame before an older one.
    func flushLast() {
        guard let work = pending.popLast() else { return }
        work()
    }

    var pendingCount: Int { pending.count }
}
