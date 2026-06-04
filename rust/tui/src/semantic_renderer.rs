use crate::semantic;
use crate::semantic_state::SemanticState;
use crate::terminal::Terminal;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Widget, Wrap};
use std::io;

#[derive(Debug, Default)]
pub struct SemanticRenderer;

impl SemanticRenderer {
    pub fn new() -> Self {
        Self
    }

    pub fn render(&mut self, state: &SemanticState, terminal: &mut Terminal) -> io::Result<()> {
        terminal.set_cursor_style(state.cursor().shape, state.cursor_animation_enabled())?;
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
                Constraint::Length(if visible_minibuffer(state).is_some() {
                    1
                } else {
                    0
                }),
                Constraint::Length(if state.status_bar().is_some() { 1 } else { 0 }),
            ])
            .split(area);

        if let Some(tab_bar) = state.tab_bar() {
            Self::render_tab_bar(tab_bar, vertical[0], buffer);
        }

        if let Some(status_bar) = state.status_bar() {
            Self::render_status_bar(state, status_bar, vertical[3], buffer);
        }

        if let Some(minibuffer) = visible_minibuffer(state) {
            Self::render_minibuffer(minibuffer, vertical[2], buffer);
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

        let editor_area = Self::render_bottom_panel(state, horizontal[1], buffer);
        Self::render_windows(state, editor_area, buffer);
        Self::render_breadcrumb(state, editor_area, buffer);
        Self::render_completion(state, editor_area, buffer);
        Self::render_signature_help(state, editor_area, buffer);
        Self::render_hover_popup(state, editor_area, buffer);
        Self::render_float_popup(state, editor_area, buffer);
        Self::render_change_summary(state, editor_area, buffer);
        Self::render_which_key(state, editor_area, buffer);
        Self::render_picker(state, editor_area, buffer);
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

        if let Some(workspaces) = state
            .workspaces()
            .filter(|workspaces| workspaces.visible != 0 && workspaces.workspace_count > 0)
        {
            parts.push(format!(
                "ws {}/{}",
                workspaces.active_workspace_id, workspaces.workspace_count
            ));
        }

        if let Some(edit_timeline) = state
            .edit_timeline()
            .filter(|edit_timeline| edit_timeline.visible != 0 && edit_timeline.entry_count > 0)
        {
            parts.push(format!(
                "edits {}/{}",
                edit_timeline.viewing_index.saturating_add(1),
                edit_timeline.entry_count
            ));
        }

        if let Some(sidebars) = state
            .sidebars()
            .filter(|sidebars| sidebars.visible != 0 && sidebars.sidebar_count > 0)
        {
            parts.push(format!("sidebars {}", sidebars.sidebar_count));
        }

        if let Some(extension_overlay) = state
            .extension_overlay()
            .filter(|extension_overlay| extension_overlay.entry_count > 0)
        {
            parts.push(format!("ext overlay {}", extension_overlay.entry_count));
        }

        if let Some(extension_panel) = state
            .extension_panel()
            .filter(|extension_panel| extension_panel.panel_count > 0)
        {
            parts.push(format!("ext panels {}", extension_panel.panel_count));
        }

        if state
            .observatory()
            .is_some_and(|observatory| observatory.visible)
        {
            parts.push("observatory".to_owned());
        }

        if let Some(agent_chat) = state
            .agent_chat()
            .filter(|agent_chat| agent_chat.visible != 0 && agent_chat.message_count > 0)
        {
            parts.push(format!("chat {}", agent_chat.message_count));
        }

        if state
            .tool_manager()
            .is_some_and(|tool_manager| tool_manager.visible != 0)
        {
            parts.push("tools".to_owned());
        }

        if let Some(agent_context) = state
            .agent_context()
            .filter(|agent_context| agent_context.visible != 0 && !agent_context.task.is_empty())
        {
            parts.push(format!("agent {}", agent_context.task));
        }

        if let Some(git_status) = state.git_status() {
            if git_status.ahead > 0 || git_status.behind > 0 {
                parts.push(format!("git +{}/-{}", git_status.ahead, git_status.behind));
            }
            if git_status.syncing {
                parts.push("syncing".to_owned());
            }
            if git_status.stash_count > 0 {
                parts.push(format!("stash {}", git_status.stash_count));
            }
        }

        parts.push(format!("{}:{}", status_bar.line, status_bar.col));
        parts.join("  ")
    }

    fn render_minibuffer(
        minibuffer: &semantic::Minibuffer,
        area: Rect,
        buffer: &mut ratatui::buffer::Buffer,
    ) {
        let mut text = format!("{}{}", minibuffer.prompt, minibuffer.input);
        if !minibuffer.context.is_empty() {
            text.push_str("  ");
            text.push_str(&minibuffer.context);
        }
        if minibuffer.total_candidates > 0 {
            text.push_str(&format!(
                "  {}/{}",
                minibuffer.selected_index.saturating_add(1),
                minibuffer.total_candidates
            ));
        }
        Paragraph::new(text)
            .style(Style::default().fg(Color::White).bg(Color::Black))
            .render(area, buffer);
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

    fn render_breadcrumb(state: &SemanticState, area: Rect, buffer: &mut ratatui::buffer::Buffer) {
        let Some(breadcrumb) = state
            .breadcrumb()
            .filter(|breadcrumb| !breadcrumb.segments.is_empty())
        else {
            return;
        };
        let text = breadcrumb.segments.join(" / ");
        Paragraph::new(text)
            .style(Style::default().fg(Color::Gray))
            .render(Rect { height: 1, ..area }, buffer);
    }

    fn render_bottom_panel(
        state: &SemanticState,
        area: Rect,
        buffer: &mut ratatui::buffer::Buffer,
    ) -> Rect {
        let Some(panel) = state
            .bottom_panel()
            .filter(|panel| panel.visible && !panel.entries.is_empty())
        else {
            return area;
        };
        let percent = panel.height_percent.clamp(10, 60) as u16;
        let requested_height = area.height.saturating_mul(percent) / 100;
        let panel_height = bounded_dimension(requested_height, 3, area.height);
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(1), Constraint::Length(panel_height)])
            .split(area);
        let active_tab = panel
            .tabs
            .get(panel.active_tab_index as usize)
            .map(|tab| tab.name.as_str())
            .unwrap_or("Panel");
        let lines: Vec<Line<'_>> = panel
            .entries
            .iter()
            .take(chunks[1].height.saturating_sub(2) as usize)
            .map(|entry| Line::from(format!("{}  {}", entry.file_path, entry.text)))
            .collect();
        Paragraph::new(lines)
            .block(Block::default().borders(Borders::ALL).title(active_tab))
            .style(Style::default().fg(Color::White).bg(Color::Black))
            .wrap(Wrap { trim: false })
            .render(chunks[1], buffer);
        chunks[0]
    }

    fn render_completion(state: &SemanticState, area: Rect, buffer: &mut ratatui::buffer::Buffer) {
        let Some(completion) = state
            .completion()
            .filter(|completion| completion.visible && !completion.items.is_empty())
        else {
            return;
        };
        let width = completion
            .items
            .iter()
            .map(|item| {
                item.label
                    .len()
                    .saturating_add(item.detail.len())
                    .saturating_add(3)
            })
            .max()
            .unwrap_or(20)
            .min(area.width as usize)
            .max(20.min(area.width as usize)) as u16;
        let height = (completion.items.len() as u16).saturating_add(2).min(10);
        let rect = anchored_rect(
            area,
            completion.anchor_col,
            completion.anchor_row.saturating_add(1),
            width,
            height,
        );
        Clear.render(rect, buffer);
        let lines = completion.items.iter().enumerate().map(|(index, item)| {
            let style = if index == completion.selected_index as usize {
                Style::default().fg(Color::Black).bg(Color::Cyan)
            } else {
                Style::default().fg(Color::White).bg(Color::Black)
            };
            Line::styled(format!("{}  {}", item.label, item.detail), style)
        });
        Paragraph::new(lines.collect::<Vec<_>>())
            .block(Block::default().borders(Borders::ALL).title("Complete"))
            .render(rect, buffer);
    }

    fn render_signature_help(
        state: &SemanticState,
        area: Rect,
        buffer: &mut ratatui::buffer::Buffer,
    ) {
        let Some(help) = state
            .signature_help()
            .filter(|help| help.visible && !help.signatures.is_empty())
        else {
            return;
        };
        let signature = help
            .signatures
            .get(help.active_signature as usize)
            .unwrap_or(&help.signatures[0]);
        let rect = anchored_rect(
            area,
            help.anchor_col,
            help.anchor_row.saturating_add(2),
            area.width.min(48),
            4,
        );
        Clear.render(rect, buffer);
        Paragraph::new(vec![
            Line::styled(signature.label.clone(), Style::default().fg(Color::Yellow)),
            Line::from(signature.documentation.clone()),
        ])
        .block(Block::default().borders(Borders::ALL).title("Signature"))
        .style(Style::default().fg(Color::White).bg(Color::Black))
        .wrap(Wrap { trim: true })
        .render(rect, buffer);
    }

    fn render_hover_popup(state: &SemanticState, area: Rect, buffer: &mut ratatui::buffer::Buffer) {
        let Some(hover) = state
            .hover_popup()
            .filter(|hover| hover.visible && !hover.lines.is_empty())
        else {
            return;
        };
        let height = (hover.lines.len() as u16).saturating_add(2).min(8);
        let rect = anchored_rect(
            area,
            hover.anchor_col,
            hover.anchor_row.saturating_add(1),
            area.width.min(52),
            height,
        );
        Clear.render(rect, buffer);
        let lines = hover.lines.iter().map(|line| {
            let spans = line
                .segments
                .iter()
                .map(|segment| {
                    Span::styled(
                        segment.text.clone(),
                        style_from_semantic(segment.fg, 0, segment.flags as u16),
                    )
                })
                .collect::<Vec<_>>();
            Line::from(spans)
        });
        Paragraph::new(lines.collect::<Vec<_>>())
            .block(Block::default().borders(Borders::ALL).title("Hover"))
            .style(Style::default().fg(Color::White).bg(Color::Black))
            .wrap(Wrap { trim: true })
            .render(rect, buffer);
    }

    fn render_float_popup(state: &SemanticState, area: Rect, buffer: &mut ratatui::buffer::Buffer) {
        let Some(popup) = state
            .float_popup()
            .filter(|popup| popup.visible && !popup.lines.is_empty())
        else {
            return;
        };
        let width = bounded_dimension(popup.width, 20, area.width);
        let height = bounded_dimension(popup.height, 3, area.height);
        let rect = centered_rect(area, width, height);
        Clear.render(rect, buffer);
        Paragraph::new(popup.lines.join("\n"))
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .title(popup.title.as_str()),
            )
            .style(Style::default().fg(Color::White).bg(Color::Black))
            .wrap(Wrap { trim: false })
            .render(rect, buffer);
    }

    fn render_change_summary(
        state: &SemanticState,
        area: Rect,
        buffer: &mut ratatui::buffer::Buffer,
    ) {
        let Some(summary) = state
            .change_summary()
            .filter(|summary| summary.visible && !summary.entries.is_empty())
        else {
            return;
        };
        let rect = Rect {
            x: area
                .x
                .saturating_add(area.width.saturating_sub(area.width.min(44))),
            y: area.y,
            width: area.width.min(44),
            height: area.height.min(12),
        };
        Clear.render(rect, buffer);
        let lines = summary.entries.iter().enumerate().map(|(index, entry)| {
            let style = if index == summary.selected_index as usize {
                Style::default().fg(Color::Black).bg(Color::Green)
            } else {
                Style::default().fg(Color::White).bg(Color::Black)
            };
            Line::styled(
                format!(
                    "{} +{} -{}",
                    entry.path, entry.lines_added, entry.lines_removed
                ),
                style,
            )
        });
        Paragraph::new(lines.collect::<Vec<_>>())
            .block(Block::default().borders(Borders::ALL).title("Changes"))
            .render(rect, buffer);
    }

    fn render_which_key(state: &SemanticState, area: Rect, buffer: &mut ratatui::buffer::Buffer) {
        let Some(which_key) = state
            .which_key()
            .filter(|which_key| which_key.visible && !which_key.bindings.is_empty())
        else {
            return;
        };
        let height = (which_key.bindings.len() as u16)
            .saturating_add(2)
            .min(area.height.min(10));
        let rect = Rect {
            x: area.x,
            y: area.y.saturating_add(area.height.saturating_sub(height)),
            width: area.width,
            height,
        };
        Clear.render(rect, buffer);
        let lines = which_key
            .bindings
            .iter()
            .take(height.saturating_sub(2) as usize)
            .map(|binding| {
                Line::from(vec![
                    Span::styled(
                        format!("{} ", binding.key),
                        Style::default()
                            .fg(Color::Cyan)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::raw(binding.description.clone()),
                ])
            });
        Paragraph::new(lines.collect::<Vec<_>>())
            .block(Block::default().borders(Borders::ALL).title(format!(
                "{} {}/{}",
                which_key.prefix,
                which_key.page.saturating_add(1),
                which_key.page_count.max(1)
            )))
            .style(Style::default().fg(Color::White).bg(Color::Black))
            .render(rect, buffer);
    }

    fn render_picker(state: &SemanticState, area: Rect, buffer: &mut ratatui::buffer::Buffer) {
        let Some(picker) = state.picker().filter(|picker| picker.visible) else {
            return;
        };
        let width = area.width.saturating_mul(3) / 4;
        let height = area.height.saturating_mul(3) / 4;
        let rect = centered_rect(
            area,
            width.max(30).min(area.width),
            height.max(8).min(area.height),
        );
        Clear.render(rect, buffer);
        let chunks =
            if picker.has_preview && visible_picker_preview(state).is_some() && rect.width >= 60 {
                Layout::default()
                    .direction(Direction::Horizontal)
                    .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
                    .split(rect)
            } else {
                Layout::default()
                    .direction(Direction::Horizontal)
                    .constraints([Constraint::Percentage(100)])
                    .split(rect)
            };
        Self::render_picker_list(picker, chunks[0], buffer);
        if chunks.len() > 1
            && let Some(preview) = visible_picker_preview(state)
        {
            Self::render_picker_preview(preview, chunks[1], buffer);
        }
    }

    fn render_picker_list(
        picker: &semantic::Picker,
        area: Rect,
        buffer: &mut ratatui::buffer::Buffer,
    ) {
        let title = if picker.query.is_empty() {
            format!(
                "{} {}/{}",
                picker.title, picker.filtered_count, picker.total_count
            )
        } else {
            format!(
                "{}: {} {}/{}",
                picker.title, picker.query, picker.filtered_count, picker.total_count
            )
        };
        let lines = picker
            .items
            .iter()
            .enumerate()
            .take(area.height.saturating_sub(2) as usize)
            .map(|(index, item)| {
                let style = if index == picker.selected_index as usize {
                    Style::default().fg(Color::Black).bg(Color::Cyan)
                } else {
                    Style::default().fg(Color::White).bg(Color::Black)
                };
                let marker = if item.marked { "*" } else { " " };
                Line::styled(
                    format!(
                        "{marker} {}  {} {}",
                        item.label, item.description, item.annotation
                    ),
                    style,
                )
            });
        Paragraph::new(lines.collect::<Vec<_>>())
            .block(Block::default().borders(Borders::ALL).title(title))
            .render(area, buffer);
    }

    fn render_picker_preview(
        preview: &semantic::PickerPreview,
        area: Rect,
        buffer: &mut ratatui::buffer::Buffer,
    ) {
        let lines = preview
            .lines
            .iter()
            .take(area.height.saturating_sub(2) as usize)
            .map(|line| {
                let spans = line
                    .iter()
                    .map(|segment| {
                        let mut style = Style::default();
                        if segment.fg != 0 {
                            style = style.fg(rgb(segment.fg));
                        }
                        if segment.bold {
                            style = style.add_modifier(Modifier::BOLD);
                        }
                        Span::styled(segment.text.clone(), style)
                    })
                    .collect::<Vec<_>>();
                Line::from(spans)
            });
        Paragraph::new(lines.collect::<Vec<_>>())
            .block(Block::default().borders(Borders::ALL).title("Preview"))
            .style(Style::default().fg(Color::White).bg(Color::Black))
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

fn visible_minibuffer(state: &SemanticState) -> Option<&semantic::Minibuffer> {
    state.minibuffer().filter(|minibuffer| minibuffer.visible)
}

fn visible_picker_preview(state: &SemanticState) -> Option<&semantic::PickerPreview> {
    state
        .picker_preview()
        .filter(|preview| preview.visible && !preview.lines.is_empty())
}

fn centered_rect(area: Rect, width: u16, height: u16) -> Rect {
    let width = width.min(area.width);
    let height = height.min(area.height);
    Rect {
        x: area.x.saturating_add(area.width.saturating_sub(width) / 2),
        y: area
            .y
            .saturating_add(area.height.saturating_sub(height) / 2),
        width,
        height,
    }
}

fn anchored_rect(area: Rect, col: u16, row: u16, width: u16, height: u16) -> Rect {
    let width = width.min(area.width);
    let height = height.min(area.height);
    let max_x = area.x.saturating_add(area.width.saturating_sub(width));
    let max_y = area.y.saturating_add(area.height.saturating_sub(height));
    Rect {
        x: area.x.saturating_add(col).min(max_x),
        y: area.y.saturating_add(row).min(max_y),
        width,
        height,
    }
}

fn bounded_dimension(requested: u16, min: u16, max: u16) -> u16 {
    if max == 0 {
        0
    } else {
        requested.max(min.min(max)).min(max)
    }
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
        let mut state = SemanticState::new(220, 6);
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
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Workspaces(
                semantic::Workspaces {
                    visible: 1,
                    active_workspace_id: 2,
                    mode: 0,
                    flags: 0,
                    workspace_count: 4,
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::EditTimeline(
                semantic::EditTimeline {
                    visible: 1,
                    viewing_index: 1,
                    entry_count: 3,
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Sidebars(
                semantic::Sidebars {
                    visible: 1,
                    sidebar_count: 2,
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::ExtensionOverlay(semantic::ExtensionOverlay { entry_count: 1 }, 0),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::ExtensionPanel(semantic::ExtensionPanel { panel_count: 2 }, 0),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Observatory(
                semantic::Observatory {
                    visible: true,
                    payload: vec![1],
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Board(
                semantic::Board {
                    visible: 1,
                    focused_card_id: 1,
                    card_count: 3,
                    filter_mode: 0,
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::AgentChat(
                semantic::AgentChat {
                    visible: 1,
                    flags: 0,
                    message_count: 4,
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::ToolManager(semantic::ToolManager { visible: 1 }, 0),
        ));

        let mut terminal = Terminal::memory(220, 6);
        SemanticRenderer::new()
            .render(&state, &mut terminal)
            .unwrap();

        let snapshot = terminal.buffer_text();
        assert!(snapshot.contains("hello semantic tui"));
        assert!(snapshot.contains("main.ex"));
        assert!(snapshot.contains("search 3/5"));
        assert!(snapshot.contains("notify 2"));
        assert!(snapshot.contains("ws 2/4"));
        assert!(snapshot.contains("edits 2/3"));
        assert!(snapshot.contains("sidebars 2"));
        assert!(snapshot.contains("ext overlay 1"));
        assert!(snapshot.contains("ext panels 2"));
        assert!(snapshot.contains("observatory"));
        assert!(snapshot.contains("chat 4"));
        assert!(snapshot.contains("tools"));
        assert!(snapshot.contains("agent review"));
        assert!(snapshot.contains("12:3"));
    }

    #[test]
    fn renders_common_semantic_surfaces() {
        let mut state = SemanticState::new(100, 28);
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::WindowContent(
                semantic::WindowContent {
                    window_id: 1,
                    origin_row: 0,
                    origin_col: 0,
                    text_width: 80,
                    text_height: 20,
                    cursor_row: 0,
                    cursor_col: 4,
                    cursor_shape: 1,
                    content_epoch: 1,
                    rows: vec![row("workspace content")],
                    cursorline: None,
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Minibuffer(
                semantic::Minibuffer {
                    visible: true,
                    prompt: ":".to_owned(),
                    input: "write".to_owned(),
                    context: "command".to_owned(),
                    selected_index: 0,
                    total_candidates: 2,
                    ..semantic::Minibuffer::default()
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::BottomPanel(
                semantic::BottomPanel {
                    visible: true,
                    active_tab_index: 0,
                    height_percent: 25,
                    tabs: vec![semantic::BottomPanelTab {
                        tab_type: 0,
                        name: "Problems".to_owned(),
                    }],
                    entries: vec![semantic::BottomPanelEntry {
                        id: 1,
                        level: 1,
                        subsystem: 0,
                        timestamp_secs: 0,
                        file_path: "lib/minga.ex".to_owned(),
                        text: "warning text".to_owned(),
                    }],
                    ..semantic::BottomPanel::default()
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Completion(
                semantic::Completion {
                    visible: true,
                    anchor_row: 1,
                    anchor_col: 2,
                    selected_index: 0,
                    items: vec![semantic::CompletionItem {
                        kind: 0,
                        label: "Enum.map".to_owned(),
                        detail: "fn".to_owned(),
                    }],
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::WhichKey(
                semantic::WhichKey {
                    visible: true,
                    prefix: "SPC".to_owned(),
                    page: 0,
                    page_count: 1,
                    bindings: vec![semantic::WhichKeyBinding {
                        kind: 0,
                        key: "f".to_owned(),
                        description: "find file".to_owned(),
                        icon: String::new(),
                    }],
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::FloatPopup(
                semantic::FloatPopup {
                    visible: true,
                    width: 24,
                    height: 5,
                    title: "Info".to_owned(),
                    lines: vec!["float detail".to_owned()],
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Picker(
                semantic::Picker {
                    visible: true,
                    selected_index: 0,
                    filtered_count: 1,
                    total_count: 3,
                    title: "Files".to_owned(),
                    query: "minga".to_owned(),
                    items: vec![semantic::PickerItem {
                        label: "mix.exs".to_owned(),
                        description: "root".to_owned(),
                        annotation: "modified".to_owned(),
                        icon_color: 0,
                        marked: true,
                    }],
                    ..semantic::Picker::default()
                },
                0,
            ),
        ));

        let mut terminal = Terminal::memory(100, 28);
        SemanticRenderer::new()
            .render(&state, &mut terminal)
            .unwrap();

        let snapshot = terminal.buffer_text();
        assert!(snapshot.contains(":write  command  1/2"));
        assert!(snapshot.contains("Problems"));
        assert!(snapshot.contains("warning text"));
        assert!(snapshot.contains("Enum.map"));
        assert!(snapshot.contains("find file"));
        assert!(snapshot.contains("Files: minga 1/3"));
        assert!(snapshot.contains("mix.exs"));
    }
}
