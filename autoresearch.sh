#!/usr/bin/env bash
set -euo pipefail
mkdir -p _build/autoresearch
swiftc -O \
  macos/Sources/Protocol/ProtocolConstants.swift \
  macos/Sources/Protocol/ProtocolTypes.swift \
  macos/Sources/Protocol/ProtocolEncoder.swift \
  macos/Sources/Protocol/PortLogger.swift \
  macos/Sources/Font/FontFace.swift \
  macos/Sources/Font/FontManager.swift \
  macos/Sources/Renderer/SlotAllocator.swift \
  macos/Sources/Renderer/CachedLineTexture.swift \
  macos/Sources/Renderer/LineTextureAtlas.swift \
  macos/Sources/Renderer/BitmapRasterizer.swift \
  macos/Sources/Renderer/WindowContent.swift \
  macos/Sources/Renderer/WindowContentRenderer.swift \
  bench/swift_render_bench.swift \
  -o _build/autoresearch/swift-render-bench
_build/autoresearch/swift-render-bench
