/// Minga GUI bridging header — C-ABI interface between Swift and Zig.
///
/// Swift → Zig: callback functions that Zig exports, Swift calls when
/// AppKit events occur (key press, mouse, resize, window close).
///
/// Zig → Swift: functions that Swift exports, Zig calls to bootstrap
/// and control the AppKit application lifecycle.

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

// ── Zig → Swift calls (Swift exports these) ──────────────────────────────────

/// Starts the macOS GUI application. Creates NSApplication, window, view,
/// and enters the NSRunLoop. Blocks until the application terminates.
/// @param initial_width   Initial window width in pixels
/// @param initial_height  Initial window height in pixels
void minga_gui_start(uint16_t initial_width, uint16_t initial_height);

#endif // MINGA_GUI_H
