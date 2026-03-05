/// Thin C wrapper around libvterm.
/// Translates bitfield structs into flat structs that Zig can consume.
#include "vterm_wrapper.h"
#include "vterm.h"

MingaVTerm minga_vterm_new(int rows, int cols) {
    return (MingaVTerm)vterm_new(rows, cols);
}

void minga_vterm_free(MingaVTerm vt) {
    vterm_free((VTerm *)vt);
}

void minga_vterm_set_utf8(MingaVTerm vt, int is_utf8) {
    vterm_set_utf8((VTerm *)vt, is_utf8);
}

MingaVTermScreen minga_vterm_obtain_screen(MingaVTerm vt) {
    return (MingaVTermScreen)vterm_obtain_screen((VTerm *)vt);
}

void minga_vterm_screen_enable_altscreen(MingaVTermScreen screen, int enable) {
    vterm_screen_enable_altscreen((VTermScreen *)screen, enable);
}

void minga_vterm_screen_reset(MingaVTermScreen screen, int hard) {
    vterm_screen_reset((VTermScreen *)screen, hard);
}

size_t minga_vterm_input_write(MingaVTerm vt, const char *data, size_t len) {
    return vterm_input_write((VTerm *)vt, data, len);
}

void minga_vterm_set_size(MingaVTerm vt, int rows, int cols) {
    vterm_set_size((VTerm *)vt, rows, cols);
}

int minga_vterm_screen_get_cell(MingaVTermScreen screen, int row, int col, MingaCell *out) {
    VTermScreenCell cell;
    VTermPos pos = { .row = row, .col = col };

    if (!vterm_screen_get_cell((VTermScreen *)screen, pos, &cell))
        return 0;

    for (int i = 0; i < 6; i++)
        out->chars[i] = cell.chars[i];

    out->width = cell.width;
    out->bold = cell.attrs.bold;
    out->underline = cell.attrs.underline;
    out->italic = cell.attrs.italic;
    out->reverse = cell.attrs.reverse;
    out->strike = cell.attrs.strike;
    out->blink = cell.attrs.blink;

    // Resolve all color types (default, indexed, RGB) to RGB values.
    // vterm_screen_convert_color_to_rgb handles indexed-to-RGB lookup
    // and leaves RGB colors unchanged.
    VTermColor fg = cell.fg;
    VTermColor bg = cell.bg;
    vterm_screen_convert_color_to_rgb((VTermScreen *)screen, &fg);
    vterm_screen_convert_color_to_rgb((VTermScreen *)screen, &bg);

    out->fg_is_rgb = 1;
    out->fg_red = fg.rgb.red;
    out->fg_green = fg.rgb.green;
    out->fg_blue = fg.rgb.blue;

    out->bg_is_rgb = 1;
    out->bg_red = bg.rgb.red;
    out->bg_green = bg.rgb.green;
    out->bg_blue = bg.rgb.blue;

    return 1;
}

void minga_vterm_set_default_colors(MingaVTerm vt,
    uint8_t fg_r, uint8_t fg_g, uint8_t fg_b,
    uint8_t bg_r, uint8_t bg_g, uint8_t bg_b) {
    VTermColor fg, bg;
    vterm_color_rgb(&fg, fg_r, fg_g, fg_b);
    vterm_color_rgb(&bg, bg_r, bg_g, bg_b);
    vterm_state_set_default_colors(
        vterm_obtain_state((VTerm *)vt), &fg, &bg);
}

int minga_vterm_get_cursor(MingaVTermScreen screen, int *row, int *col) {
    VTermPos pos;
    VTermState *state = vterm_obtain_state((VTerm *)screen);
    vterm_state_get_cursorpos(state, &pos);
    *row = pos.row;
    *col = pos.col;
    // Can't easily get cursor visibility from screen API, return 1
    return 1;
}
