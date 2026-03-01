/// Minga GUI bridging header — C-ABI interface between Swift and Zig.
///
/// Swift → Zig: callback functions that Zig exports, Swift calls when
/// AppKit events occur (key press, mouse, resize, window close).
///
/// Zig → Swift: functions that Swift exports, Zig calls to bootstrap
/// and control the AppKit application lifecycle and Metal rendering.

#ifndef MINGA_GUI_H
#define MINGA_GUI_H

#include <stdint.h>

// ── Swift → Zig callbacks (Zig exports these) ────────────────────────────────

/// Called by Swift when a key event occurs in the MingaView.
/// @param codepoint  Unicode codepoint of the key pressed
/// @param modifiers  Bitmask: 0x01=shift, 0x02=ctrl, 0x04=alt, 0x08=super
void minga_on_key_event(uint32_t codepoint, uint8_t modifiers);

/// Called by Swift when a mouse event occurs in the MingaView.
/// @param row         Cell row (top-left origin)
/// @param col         Cell column
/// @param button      Button: 0=left, 1=middle, 2=right, 3=none,
///                    0x40=wheel_up, 0x41=wheel_down
/// @param modifiers   Bitmask: same as key events
/// @param event_type  0=press, 1=release, 2=motion, 3=drag
void minga_on_mouse_event(int16_t row, int16_t col, uint8_t button,
                          uint8_t modifiers, uint8_t event_type);

/// Called by Swift when the window is resized.
/// @param width_cells   New width in cell columns
/// @param height_cells  New height in cell rows
void minga_on_resize(uint16_t width_cells, uint16_t height_cells);

/// Called by Swift when the window is about to close.
void minga_on_window_close(void);

/// Returns a pointer to the embedded Metal shader source (null-terminated).
const char* minga_get_shader_source(void);

// ── Zig → Swift calls (Swift exports these) ──────────────────────────────────

/// Starts the macOS GUI application. Creates NSApplication, window, view,
/// and enters the NSRunLoop. Blocks until the application terminates.
/// @param initial_width   Initial window width in pixels
/// @param initial_height  Initial window height in pixels
void minga_gui_start(uint16_t initial_width, uint16_t initial_height);

/// Stops the macOS GUI application. Dispatches NSApp.terminate() on the
/// main thread. Safe to call from any thread (e.g., the stdin thread).
void minga_gui_stop(void);

/// Returns the backing scale factor (1.0 for non-Retina, 2.0 for Retina).
/// Must be called after minga_gui_start has initialized the window.
float minga_get_scale_factor(void);

/// Per-cell GPU data. Must match the Metal shader's CellData struct layout.
struct MingaCellGPU {
    float uv_origin[2];
    float uv_size[2];
    float glyph_size[2];
    float glyph_offset[2];
    float fg_color[3];
    float bg_color[3];
    float grid_pos[2];
    float has_glyph;
    float is_color;  /* 1.0 for color emoji, 0.0 for text glyphs */
};

/// Upload the glyph atlas texture to the GPU.
/// @param data        Raw pixel data (BGRA, 4 bytes per pixel)
/// @param width       Atlas width in pixels
/// @param height      Atlas height in pixels
void minga_upload_atlas(const uint8_t* data, uint32_t width, uint32_t height);

/// Render a frame with the given cell data.
/// @param cells       Array of MingaCellGPU structs
/// @param cell_count  Number of cells
/// @param cell_width  Cell width in pixels
/// @param cell_height Cell height in pixels
/// @param grid_width  Grid width in columns (for cursor index calculation)
/// @param cursor_col  Cursor column position
/// @param cursor_row  Cursor row position
/// @param cursor_visible  1 if cursor should be drawn, 0 otherwise
void minga_render_frame(const struct MingaCellGPU* cells, uint32_t cell_count,
                        float cell_width, float cell_height,
                        uint16_t grid_width,
                        uint16_t cursor_col, uint16_t cursor_row,
                        uint8_t cursor_visible);

#endif // MINGA_GUI_H
