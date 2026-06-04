use ratatui::style::{Color, Modifier, Style};

pub fn status_bar() -> Style {
    Style::default().fg(Color::White).bg(Color::DarkGray)
}

pub fn minibuffer() -> Style {
    Style::default().fg(Color::White).bg(Color::Black)
}

pub fn overlay() -> Style {
    Style::default().fg(Color::White).bg(Color::Black)
}

pub fn muted() -> Style {
    Style::default().fg(Color::Gray)
}

pub fn gutter() -> Style {
    Style::default().fg(Color::DarkGray)
}

pub fn selected(bg: Color) -> Style {
    Style::default().fg(Color::Black).bg(bg)
}

pub fn tab(active: bool) -> Style {
    if active {
        Style::default()
            .fg(Color::Black)
            .bg(Color::Cyan)
            .add_modifier(Modifier::BOLD)
    } else {
        muted()
    }
}

pub fn binding_key() -> Style {
    Style::default()
        .fg(Color::Cyan)
        .add_modifier(Modifier::BOLD)
}

pub fn diagnostic() -> Style {
    Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)
}

pub fn semantic(fg: u32, bg: u32, attrs: u16) -> Style {
    let mut style = Style::default();
    if fg != 0 {
        style = style.fg(rgb(fg));
    }
    if bg != 0 {
        style = style.bg(rgb(bg));
    }
    if attrs & 0x01 != 0 {
        style = style.add_modifier(Modifier::BOLD);
    }
    if attrs & 0x02 != 0 {
        style = style.add_modifier(Modifier::ITALIC);
    }
    style
}

pub fn rgb(value: u32) -> Color {
    Color::Rgb(
        ((value >> 16) & 0xFF) as u8,
        ((value >> 8) & 0xFF) as u8,
        (value & 0xFF) as u8,
    )
}
