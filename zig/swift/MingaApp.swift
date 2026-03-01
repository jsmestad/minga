/// MingaApp.swift — AppKit window, Metal rendering, and event handling.
///
/// This file is compiled by swiftc into a .o that Zig links against.
/// Communication with Zig is via C-ABI functions declared in minga_gui.h.

import AppKit
import Metal
import QuartzCore

// ── Constants ─────────────────────────────────────────────────────────────────

/// Background color for the editor (dark gray).
private let bgColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)

// ── Modifier mapping ──────────────────────────────────────────────────────────

private func modifierBits(from flags: NSEvent.ModifierFlags) -> UInt8 {
    var mods: UInt8 = 0
    if flags.contains(.shift)   { mods |= 0x01 }
    if flags.contains(.control) { mods |= 0x02 }
    if flags.contains(.option)  { mods |= 0x04 }
    if flags.contains(.command) { mods |= 0x08 }
    return mods
}

// ── Special key mapping ───────────────────────────────────────────────────────

private func mapKeyCode(_ event: NSEvent) -> UInt32? {
    switch event.keyCode {
    case 36:  return 13    // Return
    case 48:  return 9     // Tab
    case 51:  return 127   // Backspace / Delete
    case 53:  return 27    // Escape
    // Arrow keys — Kitty keyboard protocol codepoints (must match Elixir modes)
    case 123: return 57350 // Left arrow
    case 124: return 57351 // Right arrow
    case 125: return 57353 // Down arrow
    case 126: return 57352 // Up arrow
    // Navigation keys — Kitty protocol
    case 115: return 57360 // Home
    case 119: return 57367 // End
    case 116: return 57365 // Page Up
    case 121: return 57366 // Page Down
    case 117: return 57376 // Forward Delete
    // Function keys — Kitty protocol
    case 122: return 57364 // F1
    case 120: return 57365 // F2
    case 99:  return 57366 // F3
    case 118: return 57367 // F4
    case 96:  return 57368 // F5
    case 97:  return 57369 // F6
    case 98:  return 57370 // F7
    case 100: return 57371 // F8
    case 101: return 57372 // F9
    case 109: return 57373 // F10
    case 103: return 57374 // F11
    case 111: return 57375 // F12
    default:  return nil
    }
}

// ── Metal state (module-level so C callbacks can access) ──────────────────────

private var metalDevice: MTLDevice?
private var metalCommandQueue: MTLCommandQueue?
private var metalLayer: CAMetalLayer?
private var bgPipelineState: MTLRenderPipelineState?
private var glyphPipelineState: MTLRenderPipelineState?
private var atlasTexture: MTLTexture?
private var currentCellWidth: Float = 8.0
private var currentCellHeight: Float = 16.0
private var currentView: MingaView?

/// Reusable Metal buffer for cell data (avoids setVertexBytes 4KB limit).
private var cellBuffer: MTLBuffer?
private var cellBufferCapacity: Int = 0

// ── MingaView ─────────────────────────────────────────────────────────────────

class MingaView: NSView {
    var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = metalDevice
        layer.pixelFormat = .bgra8Unorm
        layer.contentsScale = self.window?.backingScaleFactor ?? 2.0
        layer.framebufferOnly = true
        metalLayer = layer
        return layer
    }

    override func updateLayer() {
        // Metal rendering is triggered by Zig via minga_render_frame.
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            metalLayer?.contentsScale = window.backingScaleFactor
        }
        updateTrackingArea()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalLayer?.drawableSize = convertToBacking(bounds.size)
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = modifierBits(from: event.modifierFlags)

        // Special keys (arrows, Enter, Escape, etc.) — send with full modifiers.
        if let codepoint = mapKeyCode(event) {
            minga_on_key_event(codepoint, mods)
            return
        }

        // For text characters, use event.characters which already reflects
        // Shift (e.g., Shift+; → ":"). Strip the Shift bit since the
        // codepoint already encodes it — the editor matches on codepoint
        // alone (e.g., `?:` with mods=0, not mods=shift).
        // Keep Ctrl/Alt/Super since those modify behavior, not the character.
        let textMods = mods & ~0x01  // Clear shift bit

        let chars: String?
        if event.modifierFlags.contains(.control) {
            chars = event.charactersIgnoringModifiers
        } else {
            chars = event.characters
        }

        guard let characters = chars, !characters.isEmpty else { return }

        for scalar in characters.unicodeScalars {
            minga_on_key_event(scalar.value, textMods)
        }
    }

    override func flagsChanged(with event: NSEvent) {}

    // MARK: - Mouse helpers

    private func cellPosition(from point: NSPoint) -> (row: Int16, col: Int16) {
        let col = Int16(point.x / CGFloat(currentCellWidth))
        let row = Int16(point.y / CGFloat(currentCellHeight))
        return (row, col)
    }

    // MARK: - Mouse clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        minga_on_mouse_event(row, col, 0x00, modifierBits(from: event.modifierFlags), 0x00)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        minga_on_mouse_event(row, col, 0x00, modifierBits(from: event.modifierFlags), 0x01)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        minga_on_mouse_event(row, col, 0x02, modifierBits(from: event.modifierFlags), 0x00)
    }

    override func rightMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        minga_on_mouse_event(row, col, 0x02, modifierBits(from: event.modifierFlags), 0x01)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        minga_on_mouse_event(row, col, 0x00, modifierBits(from: event.modifierFlags), 0x03)
    }

    // Track last reported cell position to avoid flooding the Port
    // with redundant mouse move events.
    private static var lastMoveRow: Int16 = -1
    private static var lastMoveCol: Int16 = -1

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        // Only send if the cell position actually changed.
        guard row != MingaView.lastMoveRow || col != MingaView.lastMoveCol else { return }
        MingaView.lastMoveRow = row
        MingaView.lastMoveCol = col
        minga_on_mouse_event(row, col, 0x03, modifierBits(from: event.modifierFlags), 0x02)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = cellPosition(from: point)
        let mods = modifierBits(from: event.modifierFlags)
        if event.scrollingDeltaY > 0 {
            minga_on_mouse_event(row, col, 0x40, mods, 0x00)
        } else if event.scrollingDeltaY < 0 {
            minga_on_mouse_event(row, col, 0x41, mods, 0x00)
        }
    }
}

// ── MingaWindowDelegate ───────────────────────────────────────────────────────

class MingaWindowDelegate: NSObject, NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let size = window.contentView?.bounds.size ?? window.frame.size
        let cols = UInt16(size.width / CGFloat(currentCellWidth))
        let rows = UInt16(size.height / CGFloat(currentCellHeight))
        if cols > 0 && rows > 0 {
            minga_on_resize(cols, rows)
        }
    }

    func windowWillClose(_ notification: Notification) {
        minga_on_window_close()
        NSApp.terminate(nil)
    }
}

// ── App termination (called from Zig) ─────────────────────────────────────────

@_cdecl("minga_gui_stop")
public func mingaGuiStop() {
    DispatchQueue.main.async {
        NSApp.terminate(nil)
    }
}

/// Backing scale factor — set during window setup, read from background threads.
private var backingScaleFactor: Float = 2.0

@_cdecl("minga_get_scale_factor")
public func mingaGetScaleFactor() -> Float {
    return backingScaleFactor
}

// ── Metal setup ───────────────────────────────────────────────────────────────

private func setupMetal() -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else {
        NSLog("Metal is not supported on this device")
        return false
    }
    metalDevice = device
    metalCommandQueue = device.makeCommandQueue()

    // Compile shaders from source embedded in Zig binary.
    let shaderSource = String(cString: minga_get_shader_source())
    do {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        return setupPipelines(device: device, library: library)
    } catch {
        NSLog("Failed to compile Metal shaders: \(error)")
        return false
    }
}

private func setupPipelines(device: MTLDevice, library: MTLLibrary) -> Bool {
    // Background pipeline
    let bgDesc = MTLRenderPipelineDescriptor()
    bgDesc.vertexFunction = library.makeFunction(name: "bg_vertex")
    bgDesc.fragmentFunction = library.makeFunction(name: "bg_fragment")
    bgDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

    // Glyph pipeline (alpha blending)
    let glyphDesc = MTLRenderPipelineDescriptor()
    glyphDesc.vertexFunction = library.makeFunction(name: "glyph_vertex")
    glyphDesc.fragmentFunction = library.makeFunction(name: "glyph_fragment")
    glyphDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
    // Premultiplied alpha blending — the fragment shader outputs
    // rgb = fg_color * alpha (premultiplied), so use .one for source RGB.
    // Using .sourceAlpha would double-multiply → alpha² → thin text.
    glyphDesc.colorAttachments[0].isBlendingEnabled = true
    glyphDesc.colorAttachments[0].sourceRGBBlendFactor = .one
    glyphDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    glyphDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
    glyphDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

    do {
        bgPipelineState = try device.makeRenderPipelineState(descriptor: bgDesc)
        glyphPipelineState = try device.makeRenderPipelineState(descriptor: glyphDesc)
        return true
    } catch {
        NSLog("Failed to create Metal pipeline: \(error)")
        return false
    }
}

// ── C-ABI exports for Zig ─────────────────────────────────────────────────────

private var windowDelegate: MingaWindowDelegate?

@_cdecl("minga_gui_start")
public func mingaGuiStart(_ initialWidth: UInt16, _ initialHeight: UInt16) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    if !setupMetal() {
        NSLog("Failed to initialize Metal")
        return
    }

    let contentRect = NSRect(
        x: 0, y: 0,
        width: CGFloat(initialWidth),
        height: CGFloat(initialHeight)
    )
    let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
    let window = NSWindow(
        contentRect: contentRect,
        styleMask: styleMask,
        backing: .buffered,
        defer: false
    )
    window.title = "Minga"
    window.minSize = NSSize(width: 160, height: 80)
    window.center()

    let view = MingaView(frame: contentRect)
    view.wantsLayer = true
    window.contentView = view
    window.acceptsMouseMovedEvents = true
    currentView = view

    let delegate = MingaWindowDelegate()
    windowDelegate = delegate
    window.delegate = delegate

    window.makeKeyAndOrderFront(nil)
    backingScaleFactor = Float(window.backingScaleFactor)
    app.activate(ignoringOtherApps: true)
    app.run()
}

@_cdecl("minga_upload_atlas")
public func mingaUploadAtlas(_ data: UnsafePointer<UInt8>, _ width: UInt32, _ height: UInt32) {
    // Copy the atlas data so it survives the dispatch to the main thread.
    let byteCount = Int(width) * Int(height)
    let dataCopy = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
    dataCopy.initialize(from: data, count: byteCount)

    DispatchQueue.main.async {
        defer { dataCopy.deallocate() }
        guard let device = metalDevice else { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else { return }

        texture.replace(
            region: MTLRegionMake2D(0, 0, Int(width), Int(height)),
            mipmapLevel: 0,
            withBytes: dataCopy,
            bytesPerRow: Int(width)
        )

        atlasTexture = texture
    }
}

/// Uniforms buffer matching the Metal shader.
private struct Uniforms {
    var cellSize: SIMD2<Float>
    var viewportSize: SIMD2<Float>
}

@_cdecl("minga_render_frame")
public func mingaRenderFrame(
    _ cells: UnsafePointer<MingaCellGPU>,
    _ cellCount: UInt32,
    _ cellWidth: Float,
    _ cellHeight: Float,
    _ gridWidth: UInt16,
    _ cursorCol: UInt16,
    _ cursorRow: UInt16,
    _ cursorVisible: UInt8
) {
    // Copy cell data so it survives the dispatch to the main thread.
    // The Zig caller's buffer may be reused immediately after this returns.
    let count = Int(cellCount)
    let cellsCopy = UnsafeMutablePointer<MingaCellGPU>.allocate(capacity: max(count, 1))
    cellsCopy.initialize(from: cells, count: count)

    DispatchQueue.main.async {
        defer { cellsCopy.deallocate() }

        guard let device = metalDevice,
              let layer = metalLayer,
              let commandQueue = metalCommandQueue,
              let bgPipeline = bgPipelineState,
              let glyphPipeline = glyphPipelineState,
              let drawable = layer.nextDrawable() else {
            return
        }

        currentCellWidth = cellWidth
        currentCellHeight = cellHeight

        let renderDesc = MTLRenderPassDescriptor()
        renderDesc.colorAttachments[0].texture = drawable.texture
        renderDesc.colorAttachments[0].loadAction = .clear
        renderDesc.colorAttachments[0].storeAction = .store
        renderDesc.colorAttachments[0].clearColor = bgColor

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDesc) else {
            return
        }

        if count > 0 {
            let drawableSize = layer.drawableSize
            var uniforms = Uniforms(
                cellSize: SIMD2<Float>(cellWidth * Float(layer.contentsScale),
                                       cellHeight * Float(layer.contentsScale)),
                viewportSize: SIMD2<Float>(Float(drawableSize.width),
                                           Float(drawableSize.height))
            )

            let cellDataSize = count * MemoryLayout<MingaCellGPU>.stride

            // Ensure the reusable Metal buffer is large enough.
            if cellBuffer == nil || cellBufferCapacity < cellDataSize {
                let newCapacity = max(cellDataSize, 65536)  // At least 64KB
                cellBuffer = device.makeBuffer(length: newCapacity, options: .storageModeShared)
                cellBufferCapacity = newCapacity
            }

            guard let buffer = cellBuffer else { return }

            // Copy cell data into the Metal buffer.
            buffer.contents().copyMemory(from: cellsCopy, byteCount: cellDataSize)

            // Background pass
            encoder.setRenderPipelineState(bgPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: count)

            // Glyph pass (only if we have an atlas)
            if let atlas = atlasTexture {
                encoder.setRenderPipelineState(glyphPipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                       instanceCount: count)
            }

            // Cursor overlay
            if cursorVisible != 0 {
                let cursorIdx = Int(cursorRow) * Int(gridWidth) + Int(cursorCol)
                if cursorIdx >= 0 && cursorIdx < count {
                    var cursorCell = cellsCopy[cursorIdx]
                    cursorCell.fg_color = (1.0, 1.0, 1.0)
                    cursorCell.bg_color = (0.8, 0.8, 0.8)
                    cursorCell.has_glyph = 0.0

                    encoder.setRenderPipelineState(bgPipeline)
                    encoder.setVertexBytes(&cursorCell, length: MemoryLayout<MingaCellGPU>.stride, index: 0)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                           instanceCount: 1)
                }
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
