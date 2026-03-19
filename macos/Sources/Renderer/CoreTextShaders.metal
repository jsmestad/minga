/// Minga CoreText line renderer — Metal shaders (MSL 3.1).
///
/// Renders pre-rasterized line textures as textured quads. Each instance
/// is one screen line (or background rect or cursor overlay). Much simpler
/// than the cell-grid shaders since CoreText handles all glyph layout.
///
/// Three passes:
/// 1. Background fill: solid color quads (one per line or background run)
/// 2. Line texture blit: textured quads sampling pre-rendered CTLine textures
/// 3. Cursor overlay: solid color quad (block/beam/underline)

#include <metal_stdlib>
using namespace metal;

// ── Shared types ──────────────────────────────────────────────────────────────

/// Per-quad instance data for background and cursor passes.
struct QuadInstance {
    /// Position in pixels (top-left corner).
    float2 position;
    /// Size in pixels (width, height).
    float2 size;
    /// Fill color (RGB, 0..1).
    float3 color;
    /// Alpha (1.0 for opaque fills, < 1.0 for blended overlays).
    float alpha;
};

/// Per-line instance data for the texture blit pass.
struct LineInstance {
    /// Position in pixels (top-left corner of the line).
    float2 position;
    /// Size in pixels (texture width, texture height).
    float2 size;
    /// UV origin and size (for partial texture sampling).
    float2 uv_origin;
    float2 uv_size;
};

/// Uniforms shared across all passes.
struct CTUniforms {
    float2 viewport_size;
    /// Pixel offset for smooth scrolling.
    float2 scroll_offset;
};

/// Unit quad vertices: 2 triangles forming a rectangle (CCW winding).
constant float2 quadPositions[6] = {
    float2(0, 0), float2(1, 0), float2(0, 1),
    float2(1, 0), float2(1, 1), float2(0, 1)
};

/// Convert pixel coordinates to NDC with top-left origin.
inline float2 pixelToNDC(float2 pixel, float2 viewport) {
    return float2(
        (pixel.x / viewport.x) * 2.0 - 1.0,
        1.0 - (pixel.y / viewport.y) * 2.0
    );
}

/// Convert sRGB-encoded color to linear for correct blending.
inline float3 srgbToLinear(float3 c) {
    return mix(pow((c + 0.055) / 1.055, float3(2.4)),
               c / 12.92,
               step(c, float3(0.04045)));
}

// ── Background fill pass ──────────────────────────────────────────────────────

struct BgVertexOut {
    float4 position [[position]];
    float3 color;
    float alpha;
};

vertex BgVertexOut ct_bg_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant QuadInstance* quads [[buffer(0)]],
    constant CTUniforms& uniforms [[buffer(1)]]
) {
    constant QuadInstance& quad = quads[instance_id];
    float2 pos = quadPositions[vertex_id];
    float2 pixel_pos = quad.position + pos * quad.size - uniforms.scroll_offset;

    BgVertexOut out;
    out.position = float4(pixelToNDC(pixel_pos, uniforms.viewport_size), 0.0, 1.0);
    out.color = quad.color;
    out.alpha = quad.alpha;
    return out;
}

fragment float4 ct_bg_fragment(BgVertexOut in [[stage_in]]) {
    return float4(srgbToLinear(in.color) * in.alpha, in.alpha);
}

// ── Line texture blit pass ────────────────────────────────────────────────────

struct LineVertexOut {
    float4 position [[position]];
    float2 tex_coord;
};

vertex LineVertexOut ct_line_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant LineInstance* lines [[buffer(0)]],
    constant CTUniforms& uniforms [[buffer(1)]]
) {
    constant LineInstance& line = lines[instance_id];
    float2 pos = quadPositions[vertex_id];
    float2 pixel_pos = line.position + pos * line.size - uniforms.scroll_offset;

    LineVertexOut out;
    out.position = float4(pixelToNDC(pixel_pos, uniforms.viewport_size), 0.0, 1.0);
    out.tex_coord = line.uv_origin + pos * line.uv_size;
    return out;
}

/// Fragment shader for line texture blitting.
/// The line texture is premultiplied BGRA with transparent background.
/// Alpha blending composites it over the background quads.
fragment float4 ct_line_fragment(
    LineVertexOut in [[stage_in]],
    texture2d<float> line_texture [[texture(0)]]
) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);
    float4 texel = line_texture.sample(s, in.tex_coord);
    // Already premultiplied; pass through directly.
    return texel.a < 0.005 ? float4(0.0) : texel;
}

// ── Cursor overlay pass ───────────────────────────────────────────────────────
// Reuses the background pass shaders (ct_bg_vertex / ct_bg_fragment).
// The cursor is just a colored quad drawn after the text.
