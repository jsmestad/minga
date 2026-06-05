use super::theme::Palette;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Widget, Wrap};
use unicode_width::UnicodeWidthStr;

pub fn popup_frame<'a>(
    title: impl Into<String>,
    lines: Vec<Line<'a>>,
    rect: Rect,
    palette: &Palette<'_>,
    buffer: &mut Buffer,
) {
    Clear.render(rect, buffer);
    let border_style = Style::default().fg(palette.popup_border());
    Paragraph::new(lines)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(border_style)
                .title(title.into()),
        )
        .style(palette.overlay())
        .render(rect, buffer);
}

pub fn popup_frame_wrapped<'a>(
    title: impl Into<String>,
    lines: Vec<Line<'a>>,
    rect: Rect,
    palette: &Palette<'_>,
    buffer: &mut Buffer,
) {
    Clear.render(rect, buffer);
    let border_style = Style::default().fg(palette.popup_border());
    Paragraph::new(lines)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(border_style)
                .title(title.into()),
        )
        .style(palette.overlay())
        .wrap(Wrap { trim: true })
        .render(rect, buffer);
}

pub fn styled_bar(
    left: Vec<Span<'_>>,
    right: Vec<Span<'_>>,
    area: Rect,
    fill_style: Style,
    buffer: &mut Buffer,
) {
    let left_width: usize = left.iter().map(|s| s.content.as_ref().width()).sum();
    let right_width: usize = right.iter().map(|s| s.content.as_ref().width()).sum();
    let padding = (area.width as usize).saturating_sub(left_width.saturating_add(right_width));
    let mut spans = left;
    spans.push(Span::styled(" ".repeat(padding), fill_style));
    spans.extend(right);
    Paragraph::new(Line::from(spans)).render(area, buffer);
}

pub fn full_width_bar(text: &str, area: Rect, style: Style, buffer: &mut Buffer) {
    let text_width = text.width();
    let padded = if text_width >= area.width as usize {
        text.to_owned()
    } else {
        format!("{}{}", text, " ".repeat(area.width as usize - text_width))
    };
    Paragraph::new(Line::from(vec![Span::styled(padded, style)])).render(area, buffer);
}

pub fn list_item_line<'a>(
    text: impl Into<String>,
    selected: bool,
    palette: &Palette<'_>,
) -> Line<'a> {
    let style = if selected {
        palette.popup_selection()
    } else {
        palette.overlay()
    };
    Line::styled(text.into(), style)
}

pub fn tab_strip<'a>(tabs: &[super::super::semantic::Tab], palette: &Palette<'_>) -> Line<'a> {
    let mut spans: Vec<Span<'a>> = Vec::new();
    for tab in tabs {
        let active_style = palette.tab_active();
        let inactive_style = palette.tab_inactive();
        let base_style = if tab.active {
            active_style
        } else if tab.tint != 0 {
            inactive_style.fg(super::theme::rgb(tab.tint))
        } else {
            inactive_style
        };

        if tab.active {
            spans.push(Span::styled(
                "▌",
                Style::default()
                    .fg(palette.accent())
                    .bg(active_style.bg.unwrap_or(ratatui::style::Color::Reset)),
            ));
            spans.push(Span::styled(" ", base_style));
        } else {
            spans.push(Span::styled(" ", base_style));
        }

        if !tab.icon.is_empty() {
            spans.push(Span::styled(format!("{} ", tab.icon), base_style));
        }

        spans.push(Span::styled(tab.label.clone(), base_style));

        if tab.dirty {
            let dirty_style = if tab.active {
                Style::default()
                    .fg(palette.tab_dirty())
                    .bg(active_style.bg.unwrap_or(ratatui::style::Color::Reset))
            } else {
                Style::default()
                    .fg(palette.tab_dirty())
                    .bg(inactive_style.bg.unwrap_or(ratatui::style::Color::Reset))
            };
            spans.push(Span::styled(" *", dirty_style));
        }

        if tab.attention {
            let attn_style = Style::default()
                .fg(palette.tab_attention())
                .bg(inactive_style.bg.unwrap_or(ratatui::style::Color::Reset));
            spans.push(Span::styled(" !", attn_style));
        }

        spans.push(Span::styled(" ", base_style));
    }
    Line::from(spans)
}
