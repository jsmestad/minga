use super::geometry;
use super::theme;
use super::theme::Palette;
use crate::semantic;
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Widget, Wrap};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

#[derive(Clone, Copy)]
struct RowRenderContext<'a> {
    gutter: Option<&'a semantic::Gutter>,
    indent_guides: Option<&'a semantic::IndentGuides>,
    palette: Palette<'a>,
    theme: Option<&'a semantic::Theme>,
}

pub fn render_file_tree(
    file_tree: &semantic::FileTree,
    theme_state: Option<&semantic::Theme>,
    area: Rect,
    buffer: &mut Buffer,
) {
    let palette = Palette::new(theme_state);
    let is_dir = |row: &semantic::FileTreeRow| row.flags & 0x01 != 0;

    if !file_tree.error.is_empty() {
        let lines = vec![Line::styled(&file_tree.error, palette.muted())];
        Paragraph::new(lines)
            .style(palette.tree())
            .render(area, buffer);
        return;
    }

    if file_tree.rows.is_empty() {
        let msg = match file_tree.status {
            1 => "Loading files...",
            _ => "No files",
        };
        Paragraph::new(vec![Line::styled(msg, palette.muted())])
            .style(palette.tree())
            .render(area, buffer);
        return;
    }

    let lines = file_tree.rows.iter().map(|row| {
        let indent = "  ".repeat(row.depth as usize);
        let selected = row.id == file_tree.selected_id;
        let dir = is_dir(row);
        let expansion = if dir {
            if row.flags & 0x02 != 0 { "v " } else { "> " }
        } else {
            "  "
        };
        let marker = if selected { ">" } else { " " };
        let icon_text = if row.icon.is_empty() {
            String::new()
        } else {
            format!("{} ", row.icon)
        };
        let git_marker = match row.git_status {
            1 => " M",
            2 => " A",
            3 => " D",
            4 => " R",
            5 => " ?",
            _ => "",
        };
        let style = if selected {
            palette.tree_selection()
        } else if dir {
            palette.tree_dir()
        } else {
            palette.tree()
        };
        let mut spans = vec![Span::styled(
            format!(
                "{marker}{indent}{expansion}{icon_text}{}{git_marker}",
                row.name
            ),
            style,
        )];
        let diag_total = row.diagnostics.0 + row.diagnostics.1;
        if diag_total > 0 {
            let diag_color = if row.diagnostics.0 > 0 {
                palette.diagnostic_fg(0)
            } else {
                palette.diagnostic_fg(1)
            };
            spans.push(Span::styled(
                format!(" {diag_total}"),
                Style::default().fg(diag_color),
            ));
        }
        Line::from(spans)
    });
    Paragraph::new(lines.collect::<Vec<_>>())
        .style(palette.tree())
        .wrap(Wrap { trim: false })
        .render(area, buffer);
}

pub fn render_sidebars(
    sidebars: &semantic::Sidebars,
    theme_state: Option<&semantic::Theme>,
    area: Rect,
    buffer: &mut Buffer,
) {
    let palette = Palette::new(theme_state);
    let lines = std::iter::once(Line::from(Span::styled("Sidebars", palette.muted())))
        .chain(sidebars.visible_items().map(|sidebar| {
            let label = if sidebar.icon.is_empty() {
                sidebar.display_name.clone()
            } else {
                format!("{} {}", sidebar.icon, sidebar.display_name)
            };
            let badge = if sidebar.badge_count != u16::MAX && sidebar.badge_count > 0 {
                format!(" {}", sidebar.badge_count)
            } else {
                String::new()
            };
            let style = if sidebar.id == sidebars.active_id || sidebar.focused {
                palette.popup_selection()
            } else {
                palette.muted()
            };
            Line::from(Span::styled(format!(" {label}{badge}"), style))
        }))
        .collect::<Vec<_>>();
    Paragraph::new(lines)
        .style(palette.tree())
        .wrap(Wrap { trim: false })
        .render(area, buffer);
}

pub fn render_windows(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let palette = Palette::new(state.theme());
    for window in state.windows() {
        let rect = geometry::window_rect(window, area);
        let gutter = state.gutter(window.window_id);
        let indent_guides = state.indent_guides(window.window_id);
        let row_context = RowRenderContext {
            gutter,
            indent_guides,
            palette,
            theme: state.theme(),
        };
        let lines: Vec<Line<'_>> = (0..rect.height as usize)
            .map(|row_index| window_line(window, row_index, rect.width, row_context))
            .collect();
        Paragraph::new(lines)
            .style(palette.editor_surface())
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
    let palette = Palette::new(state.theme());
    Paragraph::new(lines)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(palette.popup_border()))
                .title(active_tab),
        )
        .style(palette.overlay())
        .wrap(Wrap { trim: false })
        .render(area, buffer);
}

fn window_line(
    window: &semantic::WindowContent,
    row_index: usize,
    width: u16,
    context: RowRenderContext<'_>,
) -> Line<'static> {
    let cursorline_bg = window
        .cursorline
        .filter(|cursorline| cursorline.row as usize == row_index)
        .and_then(|cursorline| (cursorline.bg != 0).then_some(cursorline.bg));
    let gutter_span = context
        .gutter
        .map(|gutter| render_gutter(gutter, row_index, &context.palette));
    let gutter_width = context
        .gutter
        .map(|gutter| gutter_cell_width(gutter, row_index))
        .unwrap_or(0);
    let content_width = width.saturating_sub(gutter_width);
    let mut spans = Vec::new();

    if let Some(span) = gutter_span {
        spans.push(span);
    }

    if row_index >= window.rows.len() {
        spans.extend(tilde_row(content_width, cursorline_bg, &context.palette));
    } else {
        spans.extend(row_line(
            window,
            &window.rows[row_index],
            row_index,
            window.scroll_left,
            content_width,
            cursorline_bg,
            context,
        ));
    }

    Line::from(spans)
}

fn render_gutter(
    gutter: &semantic::Gutter,
    row_index: usize,
    palette: &Palette<'_>,
) -> Span<'static> {
    Span::styled(gutter_text(gutter, row_index), palette.gutter())
}

pub(crate) fn gutter_cell_width(gutter: &semantic::Gutter, row_index: usize) -> u16 {
    gutter_text(gutter, row_index).width() as u16
}

fn gutter_text(gutter: &semantic::Gutter, row_index: usize) -> String {
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
    format!(
        "{sign:<sign_width$}{line_text:>line_number_width$} ",
        sign_width = sign_width,
        line_number_width = line_number_width
    )
}

fn tilde_row(width: u16, cursorline_bg: Option<u32>, palette: &Palette<'_>) -> Vec<Span<'static>> {
    if width == 0 {
        return Vec::new();
    }
    let mut style = palette.muted();
    if let Some(bg) = cursorline_bg {
        style = style.bg(theme::rgb(bg));
    }
    vec![Span::styled(
        format!("~{}", " ".repeat(width.saturating_sub(1) as usize)),
        style,
    )]
}

fn row_line(
    window: &semantic::WindowContent,
    row: &semantic::Row,
    row_index: usize,
    scroll_left: u16,
    width: u16,
    cursorline_bg: Option<u32>,
    context: RowRenderContext<'_>,
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

        let text = guide_text(grapheme, row_index, display_col, context.indent_guides);
        let span = span_at(&row.spans, display_col);
        let mut style = span
            .map(|span| theme::semantic(span.fg, span.bg, span.attrs as u16))
            .unwrap_or_default();
        if let Some(bg) = cursorline_bg
            && span.is_none_or(|span| span.bg == 0)
        {
            style = style.bg(theme::rgb(bg));
        }
        style = apply_window_overlays(style, window, row_index as u16, display_col, context.theme);
        spans.push(Span::styled(text, style));
        visible_width = visible_width.saturating_add(grapheme_width);
        display_col = next_col;
    }

    for annotation in annotations_for_row(window, row_index as u16) {
        let text = format!(" {}", annotation.text);
        let annotation_width = text.as_str().width() as u16;
        if annotation_width == 0 || visible_width >= width {
            continue;
        }
        spans.push(Span::styled(text, annotation_style(annotation)));
        visible_width = visible_width.saturating_add(annotation_width);
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

fn apply_window_overlays(
    mut style: Style,
    window: &semantic::WindowContent,
    row: u16,
    col: u16,
    theme_state: Option<&semantic::Theme>,
) -> Style {
    if window.selection.selection_type != 0
        && range_contains(
            window.selection.start_row,
            window.selection.start_col,
            window.selection.end_row,
            window.selection.end_col,
            row,
            col,
        )
    {
        style = style.bg(theme::selection_bg(theme_state));
    }

    for highlight in &window.document_highlights {
        if range_contains(
            highlight.start_row,
            highlight.start_col,
            highlight.end_row,
            highlight.end_col,
            row,
            col,
        ) {
            style = style.bg(theme::document_highlight_bg(theme_state, highlight.kind));
            break;
        }
    }

    for search_match in &window.search_matches {
        if search_match.row == row && col >= search_match.start_col && col < search_match.end_col {
            style = style.bg(theme::search_match_bg(
                theme_state,
                search_match.is_current != 0,
            ));
            break;
        }
    }

    for diagnostic in &window.diagnostic_ranges {
        if range_contains(
            diagnostic.start_row,
            diagnostic.start_col,
            diagnostic.end_row,
            diagnostic.end_col,
            row,
            col,
        ) {
            style = style
                .fg(theme::diagnostic_fg(theme_state, diagnostic.severity))
                .add_modifier(Modifier::UNDERLINED);
            break;
        }
    }

    style
}

fn range_contains(
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
    row: u16,
    col: u16,
) -> bool {
    if row < start_row || row > end_row {
        return false;
    }
    if row == start_row && col < start_col {
        return false;
    }
    if row == end_row && col >= end_col {
        return false;
    }
    true
}

fn annotations_for_row(
    window: &semantic::WindowContent,
    row: u16,
) -> impl Iterator<Item = &semantic::Annotation> {
    window.annotations.iter().filter(move |annotation| {
        annotation.row == row && annotation.kind != 2 && !annotation.text.is_empty()
    })
}

fn annotation_style(annotation: &semantic::Annotation) -> Style {
    let mut style = Style::default().fg(Color::Cyan);
    if annotation.fg != 0 {
        style = style.fg(theme::rgb(annotation.fg));
    }
    if annotation.bg != 0 {
        style = style.bg(theme::rgb(annotation.bg));
    }
    style
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

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::buffer::Buffer;

    #[test]
    fn file_tree_does_not_draw_an_extra_right_border() {
        let file_tree = semantic::FileTree {
            visible: true,
            focused: true,
            status: 0,
            selected_id: "row-1".to_owned(),
            root_path: String::new(),
            width: 12,
            error: String::new(),
            rows: vec![semantic::FileTreeRow {
                id: "row-1".to_owned(),
                name: "main.ex".to_owned(),
                icon: String::new(),
                depth: 0,
                flags: 0,
                git_status: 0,
                diagnostics: (0, 0, 0, 0),
                editing_text: String::new(),
            }],
        };
        let area = Rect {
            x: 0,
            y: 0,
            width: 12,
            height: 3,
        };
        let mut buffer = Buffer::empty(area);

        render_file_tree(&file_tree, None, area, &mut buffer);

        assert_ne!(buffer.cell((11, 0)).unwrap().symbol(), "│");
        assert_eq!(buffer.cell((11, 1)).unwrap().symbol(), " ");
        assert_eq!(buffer.cell((11, 2)).unwrap().symbol(), " ");
    }

    #[test]
    fn applies_window_overlay_styles_by_range_priority() {
        let mut window = window();
        window.selection = semantic::Selection {
            selection_type: 1,
            start_row: 0,
            start_col: 0,
            end_row: 0,
            end_col: 4,
        };
        assert_eq!(
            apply_window_overlays(Style::default(), &window, 0, 1, None).bg,
            Some(theme::selection_bg(None))
        );

        window.document_highlights = vec![semantic::DocumentHighlight {
            start_row: 0,
            start_col: 1,
            end_row: 0,
            end_col: 3,
            kind: 2,
        }];
        assert_eq!(
            apply_window_overlays(Style::default(), &window, 0, 1, None).bg,
            Some(theme::document_highlight_bg(None, 2))
        );

        window.search_matches = vec![semantic::SearchMatch {
            row: 0,
            start_col: 1,
            end_col: 2,
            is_current: 1,
        }];
        assert_eq!(
            apply_window_overlays(Style::default(), &window, 0, 1, None).bg,
            Some(theme::search_match_bg(None, true))
        );

        window.diagnostic_ranges = vec![semantic::DiagnosticRange {
            start_row: 0,
            start_col: 1,
            end_row: 0,
            end_col: 2,
            severity: 1,
        }];
        let style = apply_window_overlays(Style::default(), &window, 0, 1, None);
        assert_eq!(style.fg, Some(theme::diagnostic_fg(None, 1)));
        assert!(style.add_modifier.contains(Modifier::UNDERLINED));
    }

    fn window() -> semantic::WindowContent {
        semantic::WindowContent {
            window_id: 7,
            origin_row: 0,
            origin_col: 0,
            text_width: 20,
            text_height: 1,
            scroll_left: 0,
            cursor_row: 0,
            cursor_col: 0,
            cursor_shape: 1,
            content_epoch: 1,
            rows: Vec::new(),
            cursorline: None,
            selection: semantic::Selection::default(),
            search_matches: Vec::new(),
            diagnostic_ranges: Vec::new(),
            document_highlights: Vec::new(),
            annotations: Vec::new(),
        }
    }
}
