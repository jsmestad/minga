use super::geometry;
use super::theme;
use crate::semantic;
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Widget, Wrap};

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
        let lines: Vec<Line<'_>> = window.rows.iter().map(row_line).collect();
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .render(rect, buffer);
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

fn row_line(row: &semantic::Row) -> Line<'_> {
    if row.spans.is_empty() {
        return Line::from(row.text.clone());
    }

    let mut spans = Vec::new();
    let mut cursor = 0;

    for span in &row.spans {
        let start = span.start_col as usize;
        let end = span.end_col as usize;

        if start > cursor {
            spans.push(Span::raw(slice_chars(&row.text, cursor, start)));
        }

        spans.push(Span::styled(
            slice_chars(&row.text, start, end),
            theme::semantic(span.fg, span.bg, span.attrs as u16),
        ));
        cursor = cursor.max(end);
    }

    let text_len = row.text.chars().count();
    if cursor < text_len {
        spans.push(Span::raw(slice_chars(&row.text, cursor, text_len)));
    }

    Line::from(spans)
}

fn slice_chars(text: &str, start: usize, end: usize) -> String {
    text.chars()
        .skip(start)
        .take(end.saturating_sub(start))
        .collect()
}
