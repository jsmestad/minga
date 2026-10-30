import Foundation
import Metal
@testable import MingaUI

/// Production Metal resources, with shader lookup extended to the test bundle.
@MainActor
func offscreenNativeTestFactories() -> NativeRenderFactories {
    var factories = NativeRenderFactories.production
    factories.makeLibrary = { device in
        Bundle.allBundles.lazy.compactMap { try? device.makeDefaultLibrary(bundle: $0) }.first
    }
    return factories
}

/// Constructs the same production renderer for temporal and corpus pixel tests.
@MainActor
func makeOffscreenRenderer(device: MTLDevice? = MTLCreateSystemDefaultDevice(),
                           factories: NativeRenderFactories,
                           fontManager: FontManager) -> CoreTextMetalRenderer? {
    guard let renderer = CoreTextMetalRenderer(device: device, factories: factories) else { return nil }
    renderer.setupRenderers(fontManager: fontManager)
    return renderer
}
