use crate::semantic;
use crate::semantic_state::SemanticState;
use crate::terminal::Terminal;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph, Widget, Wrap};
use std::io;

#[derive(Debug, Default)]
pub struct SemanticRenderer;

impl SemanticRenderer {
    pub fn new() -> Self {
        Self
    }

    pub fn render(&mut self, state: &SemanticState, terminal: &mut Terminal) -> io::Result<()> {
        terminal.set_cursor_shape(state.cursor().shape)?;
        terminal.draw(|frame| {
            let area = frame.area();
            let content_area = Rect {
                x: 0,
                y: 0,
                width: area.width.min(state.width()),
                height: area.height.min(state.height()),
            };
            Self::render_frame(state, content_area, frame.buffer_mut());
            frame.set_cursor_position((state.cursor().col, state.cursor().row));
        })?;
        terminal.flush()
    }

    fn render_frame(state: &SemanticState, area: Rect, buffer: &mut ratatui::buffer::Buffer) {
        let vertical = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(if state.tab_bar().is_some() { 1 } else { 0 }),
                Constraint::Min(1),
                Constraint::Length(if state.status_bar().is_some() { 1 } else { 0 }),
            ])
            .split(area);

        if let Some(tab_bar) = state.tab_bar() {
            Self::render_tab_bar(tab_bar, vertical[0], buffer);
        }

        if let Some(status_bar) = state.status_bar() {
            Self::render_status_bar(state, status_bar, vertical[2], buffer);
        }

        if let Some(diagnostic) = state.diagnostic() {
            Paragraph::new(diagnostic.to_owned())
                .style(Style::default().fg(Color::Red).add_modifier(Modifier::BOLD))
                .render(vertical[1], buffer);
            return;
        }

        let body = vertical[1];
        let horizontal = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Length(Self::file_tree_width(state.file_tree())),
                Constraint::Min(1),
            ])
            .split(body);

        if let Some(file_tree) = state.file_tree().filter(|tree| tree.visible) {
            Self::render_file_tree(file_tree, horizontal[0], buffer);
        }

        Self::render_windows(state, horizontal[1], buffer);
    }

    fn render_tab_bar(
        tab_bar: &semantic::TabBar,
        area: Rect,
        buffer: &mut ratatui::buffer::Buffer,
    ) {
        let spans: Vec<Span<'_>> = tab_bar
            .tabs
            .iter()
            .map(|tab| {
                let label = if tab.dirty {
                    format!(" {} * ", tab.label)
                } else {
                    format!(" {} ", tab.label)
                };
                let style = if tab.active {
                    Style::default()
                        .fg(Color::Black)
                        .bg(Color::Cyan)
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(Color::Gray)
                };
                Span::styled(label, style)
            })
            .collect();
        Paragraph::new(Line::from(spans)).render(area, buffer);
    }

    fn render_status_bar(
        state: &SemanticState,
        status_bar: &semantic::StatusBar,
        area: Rect,
        buffer: &mut ratatui::buffer::Buffer,
    ) {
        let mut left = if status_bar.filename.is_empty() {
            status_bar.message.clone()
        } else {
            status_bar.filename.clone()
        };
        if !status_bar.branch.is_empty() {
            left.push_str("  ");
            left.push_str(&status_bar.branch);
        }
        let right = Self::status_right_text(state, status_bar);
        let width = area.width as usize;
        let padding = width.saturating_sub(left.len().saturating_add(right.len()));
        let text = format!("{left}{}{right}", " ".repeat(padding));
        Paragraph::new(text)
            .style(Style::default().fg(Color::White).bg(Color::DarkGray))
            .render(area, buffer);
    }

    fn status_right_text(state: &SemanticState, status_bar: &semantic::StatusBar) -> String {
        let mut parts = Vec::new();

        if let Some(search) = state.search_state().filter(|search| search.active != 0) {
            let current = if search.match_count == 0 {
                0
            } else {
                search.current_index.saturating_add(1)
            };
            parts.push(format!("search {current}/{}", search.match_count));
        }

        if let Some(notifications) = state.notifications().filter(|notifications| {
            notifications.visible != 0 && notifications.notification_count > 0
        }) {
            parts.push(format!("notify {}", notifications.notification_count));
        }

        if let Some(agent_context) = state
            .agent_context()
            .filter(|agent_context| agent_context.visible != 0 && !agent_context.task.is_empty())
        {
            parts.push(format!("agent {}", agent_context.task));
        }

        parts.push(format!("{}:{}", status_bar.line, status_bar.col));
        parts.join("  ")
    }

    fn render_file_tree(
        file_tree: &semantic::FileTree,
        area: Rect,
        buffer: &mut ratatui::buffer::Buffer,
    ) {
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

    fn render_windows(state: &SemanticState, area: Rect, buffer: &mut ratatui::buffer::Buffer) {
        for window in state.windows() {
            let rect = Self::window_rect(window, area);
            let lines: Vec<Line<'_>> = window.rows.iter().map(|row| Self::row_line(row)).collect();
            Paragraph::new(lines)
                .wrap(Wrap { trim: false })
                .render(rect, buffer);
        }
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
                style_from_semantic(span.fg, span.bg, span.attrs as u16),
            ));
            cursor = cursor.max(end);
        }

        let text_len = row.text.chars().count();
        if cursor < text_len {
            spans.push(Span::raw(slice_chars(&row.text, cursor, text_len)));
        }

        Line::from(spans)
    }

    fn window_rect(window: &semantic::WindowContent, body: Rect) -> Rect {
        let x = body.x.saturating_add(window.origin_col);
        let y = body.y.saturating_add(window.origin_row);
        let max_width = body.x.saturating_add(body.width).saturating_sub(x);
        let max_height = body.y.saturating_add(body.height).saturating_sub(y);
        let requested_width = if window.text_width == 0 {
            max_width
        } else {
            window.text_width
        };
        let requested_height = if window.text_height == 0 {
            window.rows.len().min(u16::MAX as usize) as u16
        } else {
            window.text_height
        };
        Rect {
            x,
            y,
            width: requested_width.min(max_width),
            height: requested_height.min(max_height),
        }
    }

    fn file_tree_width(file_tree: Option<&semantic::FileTree>) -> u16 {
        file_tree
            .filter(|tree| tree.visible)
            .map(|tree| tree.width)
            .unwrap_or(0)
    }
}

fn style_from_semantic(fg: u32, bg: u32, attrs: u16) -> Style {
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

fn rgb(value: u32) -> Color {
    Color::Rgb(
        ((value >> 16) & 0xFF) as u8,
        ((value >> 8) & 0xFF) as u8,
        (value & 0xFF) as u8,
    )
}

fn slice_chars(text: &str, start: usize, end: usize) -> String {
    text.chars()
        .skip(start)
        .take(end.saturating_sub(start))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::semantic_state::SemanticState;

    fn row(text: &str) -> semantic::Row {
        semantic::Row {
            row_type: 0,
            row_id: 1,
            buf_line: 0,
            content_hash: 1,
            text: text.to_owned(),
            spans: Vec::new(),
        }
    }

    #[test]
    fn renders_retained_semantic_window_and_status_bar() {
        let mut state = SemanticState::new(80, 6);
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::WindowContent(
                semantic::WindowContent {
                    window_id: 1,
                    origin_row: 0,
                    origin_col: 0,
                    text_width: 40,
                    text_height: 4,
                    cursor_row: 0,
                    cursor_col: 5,
                    cursor_shape: 1,
                    content_epoch: 1,
                    rows: vec![row("hello semantic tui")],
                    cursorline: None,
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::StatusBar(
                semantic::StatusBar {
                    filename: "main.ex".to_owned(),
                    line: 12,
                    col: 3,
                    ..semantic::StatusBar::default()
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::SearchState(
                semantic::SearchState {
                    active: 1,
                    match_count: 5,
                    current_index: 2,
                    flags: 0,
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Notifications(
                semantic::Notifications {
                    visible: 1,
                    notification_count: 2,
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::AgentContext(
                semantic::AgentContext {
                    visible: 1,
                    task: "review".to_owned(),
                    timestamp: 0,
                    status: 1,
                    can_approve: 0,
                },
                0,
            ),
        ));

        let mut terminal = Terminal::memory(80, 6);
        SemanticRenderer::new()
            .render(&state, &mut terminal)
            .unwrap();

        let snapshot = terminal.buffer_text();
        assert!(snapshot.contains("hello semantic tui"));
        assert!(snapshot.contains("main.ex"));
        assert!(snapshot.contains("search 3/5"));
        assert!(snapshot.contains("notify 2"));
        assert!(snapshot.contains("agent review"));
        assert!(snapshot.contains("12:3"));
    }
}
