/// Thin C wrapper around libvterm to avoid Zig cImport issues with
/// C bitfield structs (VTermScreenCellAttrs).
#ifndef VTERM_WRAPPER_H
#define VTERM_WRAPPER_H

#include <stdint.h>
#include <stddef.h>

/// Simplified cell data that Zig can directly consume.
typedef struct {
    uint32_t chars[6];  // VTERM_MAX_CHARS_PER_CELL = 6
    int8_t width;
    uint8_t bold;
    uint8_t underline;
    uint8_t italic;
    uint8_t reverse;
    uint8_t strike;
    uint8_t blink;
    uint8_t fg_red, fg_green, fg_blue;
    uint8_t bg_red, bg_green, bg_blue;
    uint8_t fg_is_rgb;
    uint8_t bg_is_rgb;
} MingaCell;

/// Opaque pointer types for Zig.
typedef void* MingaVTerm;
typedef void* MingaVTermScreen;

/// Create a new VTerm instance.
MingaVTerm minga_vterm_new(int rows, int cols);

/// Free a VTerm instance.
void minga_vterm_free(MingaVTerm vt);

/// Enable UTF-8 mode.
void minga_vterm_set_utf8(MingaVTerm vt, int is_utf8);

/// Get the screen object.
MingaVTermScreen minga_vterm_obtain_screen(MingaVTerm vt);

/// Enable alternate screen support.
void minga_vterm_screen_enable_altscreen(MingaVTermScreen screen, int enable);

/// Reset the screen.
void minga_vterm_screen_reset(MingaVTermScreen screen, int hard);

/// Write input data (from PTY) into the VTerm parser.
size_t minga_vterm_input_write(MingaVTerm vt, const char *data, size_t len);

/// Resize the terminal.
void minga_vterm_set_size(MingaVTerm vt, int rows, int cols);

/// Get a cell at the given position. Returns 1 on success, 0 on failure.
int minga_vterm_screen_get_cell(MingaVTermScreen screen, int row, int col, MingaCell *out);

/// Get the cursor position. Returns 1 if cursor is visible.
int minga_vterm_get_cursor(MingaVTermScreen screen, int *row, int *col);

#endif
