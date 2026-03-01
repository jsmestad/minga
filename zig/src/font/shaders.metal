/// Minga cell-grid text renderer — Metal shaders.
///
/// Renders a grid of cells using instanced drawing. Each instance is one cell.
/// The vertex shader positions a quad for each cell; the fragment shader
/// samples the glyph atlas for foreground text and draws the background color.

#include <metal_stdlib>
using namespace metal;

/// Per-cell data uploaded from the CPU. One instance per cell.
///
/// Uses packed_float3 for color fields to match the C/Zig struct layout
/// (12 bytes, no padding). MSL's float3 is 16-byte aligned and would
/// cause a layout mismatch with the 68-byte CPU-side struct.
struct CellData {
    /// Glyph UV coordinates in the atlas (normalized 0..1).
    float2 uv_origin;  // top-left corner
    float2 uv_size;    // width, height in UV space

    /// Glyph pixel dimensions (for aspect-correct rendering within the cell).
    float2 glyph_size;

    /// Bearing offsets in pixels.
    float2 glyph_offset;

    /// Foreground color (RGB, 0..1).
    packed_float3 fg_color;

    /// Background color (RGB, 0..1).
    packed_float3 bg_color;

    /// Grid position (column, row) — used to compute screen position.
    float2 grid_pos;

    /// 1.0 if this cell has a glyph to draw, 0.0 for background-only.
    float has_glyph;

    /// Padding to align stride to 72 bytes (float2 requires 8-byte alignment).
    float _padding;
};

/// Uniforms shared across all cells.
struct Uniforms {
    /// Cell dimensions in pixels.
    float2 cell_size;

    /// Viewport size in pixels.
    float2 viewport_size;
};

/// Vertex shader output / fragment shader input.
struct VertexOut {
    float4 position [[position]];
    float2 tex_coord;
    float3 fg_color;
    float3 bg_color;
    float  has_glyph;
    float  is_glyph_quad;  // 1.0 for glyph quad pass, 0.0 for bg pass
};

// ── Background pass ───────────────────────────────────────────────────────────

/// Vertex shader for background quads. Each cell gets a screen-filling quad
/// with its background color.
vertex VertexOut bg_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant CellData* cells [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    constant CellData& cell = cells[instance_id];

    // Unit quad: 2 triangles forming a rectangle.
    float2 positions[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    float2 pos = positions[vertex_id];

    // Cell position in pixels.
    float2 pixel_pos = (cell.grid_pos + pos) * uniforms.cell_size;

    // Convert to NDC (-1..1, y-flipped for top-left origin).
    float2 ndc;
    ndc.x = (pixel_pos.x / uniforms.viewport_size.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pixel_pos.y / uniforms.viewport_size.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.tex_coord = float2(0, 0);
    out.fg_color = cell.fg_color;
    out.bg_color = cell.bg_color;
    out.has_glyph = 0.0;
    out.is_glyph_quad = 0.0;
    return out;
}

/// Fragment shader for background quads.
fragment float4 bg_fragment(VertexOut in [[stage_in]]) {
    return float4(in.bg_color, 1.0);
}

// ── Glyph pass ────────────────────────────────────────────────────────────────

/// Vertex shader for glyph quads. Positions a quad sized to the glyph bitmap
/// within the cell, applying bearing offsets.
vertex VertexOut glyph_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant CellData* cells [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    constant CellData& cell = cells[instance_id];

    float2 positions[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    float2 uv_offsets[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    float2 pos = positions[vertex_id];

    // Glyph quad position: cell origin + bearing offset, sized to glyph.
    float2 cell_origin = cell.grid_pos * uniforms.cell_size;
    float2 glyph_origin = cell_origin + cell.glyph_offset;
    float2 pixel_pos = glyph_origin + pos * cell.glyph_size;

    float2 ndc;
    ndc.x = (pixel_pos.x / uniforms.viewport_size.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pixel_pos.y / uniforms.viewport_size.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.tex_coord = cell.uv_origin + uv_offsets[vertex_id] * cell.uv_size;
    out.fg_color = cell.fg_color;
    out.bg_color = cell.bg_color;
    out.has_glyph = cell.has_glyph;
    out.is_glyph_quad = 1.0;
    return out;
}

/// Fragment shader for glyph quads. Samples the atlas texture and applies
/// the foreground color, using the atlas value as alpha.
fragment float4 glyph_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    if (in.has_glyph < 0.5) {
        discard_fragment();
    }

    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float alpha = atlas.sample(s, in.tex_coord).r;

    if (alpha < 0.01) {
        discard_fragment();
    }

    return float4(in.fg_color * alpha, alpha);
}
