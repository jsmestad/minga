use super::geometry;
use super::theme;
use crate::semantic;
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Widget, Wrap};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

pub fn render_file_tree(file_tree: &semantic::FileTree, area: Rect, buffer: &mut Buffer) {
    let lines = file_tree.rows.iter().map(|row| {
        let indent = "  ".repeat(row.depth as usize);
        let marker = if row.id == file_tree.selected_id {
            ">"
        } else {
            " "
        };
        Line::from(format!("{marker}{indent}{} {}", row.icon, row.name))
    });
    Paragraph::new(lines.collect::<Vec<_>>())
        .block(Block::default().borders(Borders::RIGHT))
        .wrap(Wrap { trim: false })
        .render(area, buffer);
}

pub fn render_windows(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    for window in state.windows() {
        let rect = geometry::window_rect(window, area);
        let gutter = state.gutter(window.window_id);
        let indent_guides = state.indent_guides(window.window_id);
        let lines: Vec<Line<'_>> = (0..rect.height as usize)
            .map(|row_index| window_line(window, row_index, rect.width, gutter, indent_guides))
            .collect();
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .render(rect, buffer);
    }
}

pub fn render_separators(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    if let Some(split_separators) = state.split_separators() {
        let style = separator_style(split_separators.color);
        for vertical in &split_separators.verticals {
            let x = area.x.saturating_add(vertical.col);
            if x >= area.x.saturating_add(area.width) {
                continue;
            }
            let start = area.y.saturating_add(vertical.start_row);
            let end = area.y.saturating_add(vertical.end_row);
            for y in start..=end.min(area.y.saturating_add(area.height.saturating_sub(1))) {
                buffer.set_string(x, y, "│", style);
            }
        }

        for horizontal in &split_separators.horizontals {
            let y = area.y.saturating_add(horizontal.row);
            if y >= area.y.saturating_add(area.height) {
                continue;
            }
            let x = area.x.saturating_add(horizontal.col);
            if x >= area.x.saturating_add(area.width) {
                continue;
            }
            let width = horizontal
                .width
                .min(area.x.saturating_add(area.width).saturating_sub(x));
            buffer.set_string(
                x,
                y,
                horizontal_separator_text(width, &horizontal.filename),
                style,
            );
        }
    }

    if let Some(separator) = state.gutter_separator() {
        let x = area.x.saturating_add(separator.col);
        if x < area.x.saturating_add(area.width) {
            let style = separator_style(separator.color);
            for y in area.y..area.y.saturating_add(area.height) {
                buffer.set_string(x, y, "│", style);
            }
        }
    }
}

pub fn render_breadcrumb(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(breadcrumb) = state
        .breadcrumb()
        .filter(|breadcrumb| !breadcrumb.segments.is_empty())
    else {
        return;
    };
    let text = breadcrumb.segments.join(" / ");
    Paragraph::new(text)
        .style(theme::muted())
        .render(Rect { height: 1, ..area }, buffer);
}

pub fn render_bottom_panel(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(panel) = state
        .bottom_panel()
        .filter(|panel| panel.visible && !panel.entries.is_empty())
    else {
        return;
    };
    let active_tab = panel
        .tabs
        .get(panel.active_tab_index as usize)
        .map(|tab| tab.name.as_str())
        .unwrap_or("Panel");
    let lines: Vec<Line<'_>> = panel
        .entries
        .iter()
        .take(area.height.saturating_sub(2) as usize)
        .map(|entry| Line::from(format!("{}  {}", entry.file_path, entry.text)))
        .collect();
    Paragraph::new(lines)
        .block(Block::default().borders(Borders::ALL).title(active_tab))
        .style(theme::overlay())
        .wrap(Wrap { trim: false })
        .render(area, buffer);
}

fn window_line(
    window: &semantic::WindowContent,
    row_index: usize,
    width: u16,
    gutter: Option<&semantic::Gutter>,
    indent_guides: Option<&semantic::IndentGuides>,
) -> Line<'static> {
    let cursorline_bg = window
        .cursorline
        .filter(|cursorline| cursorline.row as usize == row_index)
        .and_then(|cursorline| (cursorline.bg != 0).then_some(cursorline.bg));
    let gutter_span = gutter.map(|gutter| render_gutter(gutter, row_index));
    let gutter_width = gutter_span
        .as_ref()
        .map(|span| span.content.as_ref().width() as u16)
        .unwrap_or(0);
    let content_width = width.saturating_sub(gutter_width);
    let mut spans = Vec::new();

    if let Some(span) = gutter_span {
        spans.push(span);
    }

    if row_index >= window.rows.len() {
        spans.extend(tilde_row(content_width, cursorline_bg));
    } else {
        spans.extend(row_line(
            &window.rows[row_index],
            row_index,
            window.scroll_left,
            content_width,
            cursorline_bg,
            indent_guides,
        ));
    }

    Line::from(spans)
}

fn render_gutter(gutter: &semantic::Gutter, row_index: usize) -> Span<'static> {
    let line_number_width = gutter.line_number_width.max(1) as usize;
    let sign_width = gutter.sign_col_width as usize;
    let entry = gutter.entries.get(row_index);
    let line_text = if entry.is_some_and(|entry| entry.display_type == 5) {
        "~".to_owned()
    } else if let Some(entry) = entry {
        format!("{}", entry.buf_line.saturating_add(1))
    } else {
        String::new()
    };
    let sign = entry
        .and_then(|entry| (!entry.sign_text.is_empty()).then_some(entry.sign_text.as_str()))
        .unwrap_or("");
    let text = format!(
        "{sign:<sign_width$}{line_text:>line_number_width$} ",
        sign_width = sign_width,
        line_number_width = line_number_width
    );
    Span::styled(text, theme::gutter())
}

fn tilde_row(width: u16, cursorline_bg: Option<u32>) -> Vec<Span<'static>> {
    if width == 0 {
        return Vec::new();
    }
    let mut style = theme::muted();
    if let Some(bg) = cursorline_bg {
        style = style.bg(theme::rgb(bg));
    }
    vec![Span::styled(
        format!("~{}", " ".repeat(width.saturating_sub(1) as usize)),
        style,
    )]
}

fn row_line(
    row: &semantic::Row,
    row_index: usize,
    scroll_left: u16,
    width: u16,
    cursorline_bg: Option<u32>,
    indent_guides: Option<&semantic::IndentGuides>,
) -> Vec<Span<'static>> {
    let mut spans = Vec::new();
    let mut visible_width = 0;
    let mut display_col = 0u16;

    for grapheme in row.text.graphemes(true) {
        let grapheme_width = grapheme.width().max(1) as u16;
        let next_col = display_col.saturating_add(grapheme_width);
        if next_col <= scroll_left {
            display_col = next_col;
            continue;
        }
        if visible_width >= width {
            break;
        }

        let text = guide_text(grapheme, row_index, display_col, indent_guides);
        let span = span_at(&row.spans, display_col);
        let mut style = span
            .map(|span| theme::semantic(span.fg, span.bg, span.attrs as u16))
            .unwrap_or_default();
        if let Some(bg) = cursorline_bg
            && span.is_none_or(|span| span.bg == 0)
        {
            style = style.bg(theme::rgb(bg));
        }
        spans.push(Span::styled(text, style));
        visible_width = visible_width.saturating_add(grapheme_width);
        display_col = next_col;
    }

    if visible_width < width {
        let mut style = Style::default();
        if let Some(bg) = cursorline_bg {
            style = style.bg(theme::rgb(bg));
        }
        spans.push(Span::styled(
            " ".repeat(width.saturating_sub(visible_width) as usize),
            style,
        ));
    }

    spans
}

fn span_at(spans: &[semantic::Span], col: u16) -> Option<&semantic::Span> {
    spans
        .iter()
        .find(|span| col >= span.start_col && col < span.end_col)
}

fn guide_text(
    grapheme: &str,
    row_index: usize,
    display_col: u16,
    indent_guides: Option<&semantic::IndentGuides>,
) -> String {
    let Some(guides) = indent_guides else {
        return grapheme.to_owned();
    };
    let level = guides
        .line_indent_levels
        .get(row_index)
        .copied()
        .unwrap_or_default();
    if grapheme == " "
        && guides.guide_cols.contains(&display_col)
        && display_col / guides.tab_width.max(1) as u16 <= level as u16
    {
        "│".to_owned()
    } else {
        grapheme.to_owned()
    }
}

fn separator_style(color: u32) -> Style {
    let mut style = Style::default().fg(Color::Gray);
    if color != 0 {
        style = style.fg(theme::rgb(color));
    }
    style
}

fn horizontal_separator_text(width: u16, filename: &str) -> String {
    if width == 0 {
        return String::new();
    }
    let label = filename.trim();
    if label.is_empty() || width < 4 {
        return "─".repeat(width as usize);
    }
    let label = format!(" {label} ");
    let label_width = label.width();
    if label_width >= width as usize {
        return "─".repeat(width as usize);
    }
    format!("{label}{}", "─".repeat(width as usize - label_width))
}
