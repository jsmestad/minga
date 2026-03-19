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

// ── Underline pass ────────────────────────────────────────────────────────────

/// Per-underline instance data.
struct UnderlineData {
    float2 grid_pos;    // Column, row in grid units.
    float3 color;       // Underline color (RGB, 0..1).
    float  style;       // 0=line, 1=curl, 2=dashed, 3=dotted, 4=double.
    float  cell_span;   // Width in cells (1 for normal, 2 for wide chars).
};

struct UnderlineOut {
    float4 position [[position]];
    float3 color;
    float  style;
    float2 uv;         // Normalized position within the underline quad.
};

vertex UnderlineOut underline_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant UnderlineData* underlines [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    constant UnderlineData& ul = underlines[instance_id];
    float2 pos = quadPositions[vertex_id];

    // Underline is drawn at the bottom of the cell (last 2px at content scale).
    float underline_height = 2.0;
    float cell_width = uniforms.cell_size.x * ul.cell_span;
    float cell_height = uniforms.cell_size.y;

    // Position at bottom of cell.
    float2 cell_origin = ul.grid_pos * uniforms.cell_size - uniforms.scroll_offset;
    float2 ul_origin = float2(cell_origin.x, cell_origin.y + cell_height - underline_height);
    float2 ul_size = float2(cell_width, underline_height);
    float2 pixel_pos = ul_origin + pos * ul_size;

    UnderlineOut out;
    out.position = float4(pixelToNDC(pixel_pos, uniforms.viewport_size), 0.0, 1.0);
    out.color = ul.color;
    out.style = ul.style;
    out.uv = pos;
    return out;
}

fragment float4 underline_fragment(UnderlineOut in [[stage_in]]) {
    float3 linear_color = srgbToLinear(in.color);
    int style = int(in.style + 0.5);

    // Style 0: solid line (full coverage).
    if (style == 0) {
        return float4(linear_color, 1.0);
    }

    // Style 1: curl (sine wave).
    if (style == 1) {
        float wave = sin(in.uv.x * 3.14159 * 4.0) * 0.5 + 0.5;
        float dist = abs(in.uv.y - wave);
        float alpha = smoothstep(0.4, 0.0, dist);
        return float4(linear_color * alpha, alpha);
    }

    // Style 2: dashed (4 dashes per cell).
    if (style == 2) {
        float pattern = step(0.5, fract(in.uv.x * 4.0));
        return float4(linear_color * pattern, pattern);
    }

    // Style 3: dotted (8 dots per cell).
    if (style == 3) {
        float pattern = step(0.5, fract(in.uv.x * 8.0));
        return float4(linear_color * pattern, pattern);
    }

    // Style 4: double (two thin lines).
    if (style == 4) {
        float line1 = step(in.uv.y, 0.3);
        float line2 = step(0.7, in.uv.y);
        float alpha = max(line1, line2);
        return float4(linear_color * alpha, alpha);
    }

    // Fallback: solid.
    return float4(linear_color, 1.0);
}

// ── Blit pass (proportional text layers) ──────────────────────────────────────

/// Per-instance data for blitting a proportional text texture.
struct BlitData {
    /// Position in pixels (top-left corner).
    float2 position;
    /// Size in pixels.
    float2 size;
};

struct BlitOut {
    float4 position [[position]];
    float2 tex_coord;
};

vertex BlitOut blit_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant BlitData* blits [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    constant BlitData& b = blits[instance_id];
    float2 pos = quadPositions[vertex_id];
    float2 pixel_pos = b.position + pos * b.size;

    BlitOut out;
    out.position = float4(pixelToNDC(pixel_pos, uniforms.viewport_size), 0.0, 1.0);
    out.tex_coord = pos;
    return out;
}

/// Fragment shader for proportional text layers.
/// The texture is pre-rendered BGRA from CoreGraphics, already in sRGB.
/// Since the framebuffer is bgra8Unorm_srgb, the GPU handles the
/// sRGB-to-linear conversion automatically on texture read and the
/// linear-to-sRGB conversion on framebuffer write.
fragment float4 blit_fragment(
    BlitOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 texel = tex.sample(s, in.tex_coord);
    return texel;
}
