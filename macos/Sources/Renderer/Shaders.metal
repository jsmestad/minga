/// Minga cell-grid text renderer — Metal shaders (MSL 3.1).
///
/// Renders a grid of cells using instanced drawing. Each instance is one cell.
/// The vertex shader positions a quad for each cell; the fragment shader
/// samples the glyph atlas for foreground text and draws the background color.

#include <metal_stdlib>
using namespace metal;

/// Per-cell data uploaded from the CPU. One instance per cell.
///
/// Uses float3 (16-byte aligned) for colors. The Swift-side struct uses
/// SIMD3<Float> which has the same alignment, so the layouts match.
struct CellData {
    /// Glyph UV coordinates in the atlas (normalized 0..1).
    float2 uv_origin;
    float2 uv_size;

    /// Glyph pixel dimensions (for aspect-correct rendering within the cell).
    float2 glyph_size;

    /// Bearing offsets in pixels.
    float2 glyph_offset;

    /// Foreground color (RGB, 0..1).
    float3 fg_color;

    /// Background color (RGB, 0..1).
    float3 bg_color;

    /// Grid position (column, row) — used to compute screen position.
    float2 grid_pos;

    /// 1.0 if this cell has a glyph to draw, 0.0 for background-only.
    float has_glyph;

    /// 1.0 for color emoji (sample BGRA directly), 0.0 for text (fg * alpha).
    float is_color;
};

/// Uniforms shared across all cells.
struct Uniforms {
    float2 cell_size;
    float2 viewport_size;
    /// Pixel offset for smooth scrolling. Shifts all content vertically
    /// (positive = content scrolled up, negative = scrolled down).
    float2 scroll_offset;
};

/// Vertex shader output / fragment shader input.
struct VertexOut {
    float4 position [[position]];
    float2 tex_coord;
    float3 fg_color;
    float3 bg_color;
    float  has_glyph;
    float  is_glyph_quad;
    float  is_color;
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

// ── sRGB linearization ────────────────────────────────────────────────────────

/// Convert sRGB-encoded color to linear for correct blending and output.
/// Uses the exact sRGB EOTF (piecewise: linear below 0.04045, gamma above).
inline float3 srgbToLinear(float3 c) {
    return mix(pow((c + 0.055) / 1.055, float3(2.4)),
               c / 12.92,
               step(c, float3(0.04045)));
}

// ── Background pass ───────────────────────────────────────────────────────────

vertex VertexOut bg_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant CellData* cells [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    constant CellData& cell = cells[instance_id];
    float2 pos = quadPositions[vertex_id];
    float2 pixel_pos = (cell.grid_pos + pos) * uniforms.cell_size - uniforms.scroll_offset;

    VertexOut out;
    out.position = float4(pixelToNDC(pixel_pos, uniforms.viewport_size), 0.0, 1.0);
    out.tex_coord = float2(0.0);
    out.fg_color = cell.fg_color;
    out.bg_color = cell.bg_color;
    out.has_glyph = 0.0;
    out.is_glyph_quad = 0.0;
    out.is_color = 0.0;
    return out;
}

fragment float4 bg_fragment(VertexOut in [[stage_in]]) {
    return float4(srgbToLinear(in.bg_color), 1.0);
}

// ── Glyph pass ────────────────────────────────────────────────────────────────

vertex VertexOut glyph_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant CellData* cells [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    constant CellData& cell = cells[instance_id];
    float2 pos = quadPositions[vertex_id];

    float2 cell_origin = cell.grid_pos * uniforms.cell_size - uniforms.scroll_offset;
    // Snap glyph origin to pixel boundaries to avoid sub-pixel blur
    // from bilinear interpolation on fractional offsets.
    float2 glyph_origin = round(cell_origin + cell.glyph_offset);
    float2 pixel_pos = glyph_origin + pos * cell.glyph_size;

    VertexOut out;
    out.position = float4(pixelToNDC(pixel_pos, uniforms.viewport_size), 0.0, 1.0);
    out.tex_coord = cell.uv_origin + pos * cell.uv_size;
    out.fg_color = cell.fg_color;
    out.bg_color = cell.bg_color;
    out.has_glyph = cell.has_glyph;
    out.is_glyph_quad = 1.0;
    out.is_color = cell.is_color;
    return out;
}

/// Fragment shader for glyph quads.
/// - Text glyphs: atlas stores (255,255,255, alpha) in BGRA. Use .a as
///   coverage and multiply by fg_color. Output is premultiplied.
/// - Color emoji: atlas stores full BGRA, already premultiplied by CoreText.
fragment float4 glyph_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    if (in.has_glyph < 0.5) {
        return float4(0.0);
    }

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 texel = atlas.sample(s, in.tex_coord);

    if (in.is_color > 0.5) {
        return texel.a < 0.01 ? float4(0.0) : texel;
    }

    float alpha = texel.a;
    float3 linear_fg = srgbToLinear(in.fg_color);
    return alpha < 0.01 ? float4(0.0) : float4(linear_fg * alpha, alpha);
}
