#[path = "renderer/chrome.rs"]
mod chrome;
#[path = "renderer/components.rs"]
mod components;
#[path = "renderer/editor.rs"]
mod editor;
#[path = "renderer/geometry.rs"]
mod geometry;
#[path = "renderer/layout.rs"]
mod layout;
#[path = "renderer/overlays.rs"]
mod overlays;
#[path = "renderer/surfaces.rs"]
mod surfaces;
#[path = "renderer/theme.rs"]
mod theme;

use crate::semantic_state::SemanticState;
use crate::terminal::Terminal;
use crate::{input, protocol};
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget};
use std::io;
use std::time::Instant;
use unicode_width::UnicodeWidthStr;

#[derive(Debug, Default)]
pub struct SemanticRenderer;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderMetrics {
    pub cursor_style_us: u128,
    pub draw_us: u128,
    pub flush_us: u128,
    pub total_us: u128,
    pub surfaces: surfaces::SurfaceRenderMetrics,
}

impl SemanticRenderer {
    pub fn new() -> Self {
        Self
    }

    pub fn render_startup(terminal: &mut Terminal, message: &str) -> io::Result<()> {
        terminal.draw(|frame| {
            let area = frame.area();
            let buffer = frame.buffer_mut();
            buffer.set_style(area, Style::default().bg(Color::Rgb(40, 44, 52)));

            let tab_area = Rect {
                x: area.x,
                y: area.y,
                width: area.width,
                height: area.height.min(1),
            };
            Paragraph::new(Line::from(vec![Span::styled(
                " starting ",
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            )]))
            .render(tab_area, buffer);

            if area.height > 2 {
                let status_area = Rect {
                    x: area.x,
                    y: area.y + area.height - 1,
                    width: area.width,
                    height: 1,
                };
                let text = pad_to_width(message, area.width as usize);
                Paragraph::new(text)
                    .style(Style::default().fg(Color::White).bg(Color::DarkGray))
                    .render(status_area, buffer);
            }
        })?;
        terminal.flush()
    }

    #[cfg(test)]
    pub fn render(&mut self, state: &SemanticState, terminal: &mut Terminal) -> io::Result<()> {
        self.render_with_metrics(state, terminal).map(|_| ())
    }

    pub fn render_with_metrics(
        &mut self,
        state: &SemanticState,
        terminal: &mut Terminal,
    ) -> io::Result<RenderMetrics> {
        let total_started = Instant::now();
        let cursor_style_started = Instant::now();
        terminal.set_cursor_style(state.cursor().shape, state.cursor_animation_enabled())?;
        let cursor_style_us = cursor_style_started.elapsed().as_micros();

        let draw_started = Instant::now();
        let mut surface_metrics = surfaces::SurfaceRenderMetrics::default();
        terminal.draw(|frame| {
            let content_area = content_area(frame.area(), state);
            let layout = layout::FrameLayout::compute(state, content_area);
            surface_metrics = surfaces::render_frame(state, &layout, frame.buffer_mut());
            if let Some((col, row)) = rendered_cursor_position(state, &layout) {
                frame.set_cursor_position((col, row));
            }
        })?;
        let draw_us = draw_started.elapsed().as_micros();

        let flush_started = Instant::now();
        terminal.flush().map(|_| RenderMetrics {
            cursor_style_us,
            draw_us,
            flush_us: flush_started.elapsed().as_micros(),
            total_us: total_started.elapsed().as_micros(),
            surfaces: surface_metrics,
        })
    }

    pub fn semantic_mouse_packet(
        &self,
        state: &SemanticState,
        event: &input::Event,
    ) -> Option<Vec<u8>> {
        let input::Event::Mouse {
            row,
            col,
            button,
            event_type,
            ..
        } = event
        else {
            return None;
        };
        if *button != 0 || *event_type != 0 || *row < 0 || *col < 0 {
            return None;
        }

        let area = Rect {
            x: 0,
            y: 0,
            width: state.width(),
            height: state.height(),
        };
        let layout = layout::FrameLayout::compute(state, content_area(area, state));

        if let Some(packet) =
            file_tree_mouse_packet(state, layout.file_tree, *row as u16, *col as u16)
        {
            return Some(packet);
        }
        if let Some(packet) =
            status_bar_mouse_packet(state, layout.status_bar, *row as u16, *col as u16)
        {
            return Some(packet);
        }

        None
    }
}

fn file_tree_mouse_packet(
    state: &SemanticState,
    area: Rect,
    row: u16,
    col: u16,
) -> Option<Vec<u8>> {
    let file_tree = layout::visible_file_tree(state)?;
    if !rect_contains(area, row, col) {
        return None;
    }

    let row_index = row.saturating_sub(area.y) as usize;
    if row_index >= file_tree.rows.len() || row_index > u16::MAX as usize {
        return None;
    }

    Some(protocol::encode_gui_file_tree_click(row_index as u16).to_vec())
}

fn status_bar_mouse_packet(
    state: &SemanticState,
    area: Rect,
    row: u16,
    col: u16,
) -> Option<Vec<u8>> {
    let status_bar = state.status_bar()?;
    if !rect_contains(area, row, col) {
        return None;
    }

    let left_width = status_bar
        .left_segments
        .iter()
        .map(|segment| segment.text.as_str().width())
        .sum::<usize>() as u16;
    if let Some(command) = segment_command_at(&status_bar.left_segments, area.x, col) {
        return Some(protocol::encode_gui_execute_command(command));
    }

    let right_width = status_bar
        .right_segments
        .iter()
        .map(|segment| segment.text.as_str().width())
        .sum::<usize>() as u16;
    let right_start = area
        .x
        .saturating_add(area.width.saturating_sub(right_width));
    if col >= area.x.saturating_add(left_width)
        && let Some(command) = segment_command_at(&status_bar.right_segments, right_start, col)
    {
        return Some(protocol::encode_gui_execute_command(command));
    }

    None
}

fn segment_command_at(
    segments: &[crate::semantic::StatusSegment],
    start_col: u16,
    col: u16,
) -> Option<&str> {
    let mut x = start_col;
    for segment in segments {
        let width = segment.text.as_str().width() as u16;
        let next_x = x.saturating_add(width);
        if col >= x && col < next_x && !segment.command.is_empty() {
            return Some(&segment.command);
        }
        x = next_x;
    }
    None
}

fn rect_contains(rect: Rect, row: u16, col: u16) -> bool {
    row >= rect.y
        && row < rect.y.saturating_add(rect.height)
        && col >= rect.x
        && col < rect.x.saturating_add(rect.width)
}

fn rendered_cursor_position(
    state: &SemanticState,
    layout: &layout::FrameLayout,
) -> Option<(u16, u16)> {
    let window_id = state.cursor_window_id()?;
    let window = state.window(window_id)?;
    let rect = geometry::window_rect(window, layout.area);
    if rect.width == 0 || rect.height == 0 || window.cursor_row >= rect.height {
        return None;
    }

    let gutter_width = state
        .gutter(window_id)
        .map(|gutter| editor::gutter_cell_width(gutter, window.cursor_row as usize))
        .unwrap_or(0);
    let visible_col = window.cursor_col.saturating_sub(window.scroll_left);
    let col = rect
        .x
        .saturating_add(gutter_width)
        .saturating_add(visible_col);
    if col >= rect.x.saturating_add(rect.width) {
        return None;
    }

    Some((col, rect.y.saturating_add(window.cursor_row)))
}

fn pad_to_width(text: &str, width: usize) -> String {
    let mut padded = text.chars().take(width).collect::<String>();
    let padding = width.saturating_sub(padded.len());
    padded.push_str(&" ".repeat(padding));
    padded
}

fn content_area(area: Rect, state: &SemanticState) -> Rect {
    Rect {
        x: 0,
        y: 0,
        width: area.width.min(state.width()),
        height: area.height.min(state.height()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::semantic;

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
    fn content_area_honors_terminal_and_state_bounds() {
        let state = SemanticState::new(40, 10);

        assert_eq!(
            content_area(
                Rect {
                    x: 0,
                    y: 0,
                    width: 80,
                    height: 24
                },
                &state
            ),
            Rect {
                x: 0,
                y: 0,
                width: 40,
                height: 10
            }
        );
    }

    #[test]
    fn rendered_cursor_position_accounts_for_window_gutter() {
        let mut state = SemanticState::new(80, 20);
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::WindowContent(
                semantic::WindowContent {
                    window_id: 7,
                    origin_row: 1,
                    origin_col: 2,
                    text_width: 40,
                    text_height: 4,
                    scroll_left: 0,
                    cursor_row: 0,
                    cursor_col: 0,
                    cursor_shape: 1,
                    content_epoch: 1,
                    rows: vec![row("")],
                    cursorline: None,
                    selection: semantic::Selection::default(),
                    search_matches: Vec::new(),
                    diagnostic_ranges: Vec::new(),
                    document_highlights: Vec::new(),
                    annotations: Vec::new(),
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Gutter(
                semantic::Gutter {
                    window_id: 7,
                    content_height: 4,
                    line_number_width: 3,
                    sign_col_width: 1,
                    entries: vec![semantic::GutterEntry {
                        buf_line: 0,
                        display_type: 0,
                        sign_type: 0,
                        fold_end_line: 0,
                        sign_fg: 0,
                        sign_text: String::new(),
                    }],
                    ..semantic::Gutter::default()
                },
                0,
            ),
        ));
        let layout = layout::FrameLayout::compute(
            &state,
            Rect {
                x: 0,
                y: 0,
                width: 80,
                height: 20,
            },
        );

        assert_eq!(rendered_cursor_position(&state, &layout), Some((7, 1)));
    }

    #[test]
    fn renders_startup_frame_before_backend_packets() {
        let mut terminal = Terminal::memory(40, 6);

        SemanticRenderer::render_startup(&mut terminal, "Starting Minga").unwrap();

        let snapshot = terminal.buffer_text();
        assert!(snapshot.contains("starting"));
        assert!(snapshot.contains("Starting Minga"));
    }

    #[test]
    fn resolves_file_tree_left_click_to_gui_action() {
        let mut state = SemanticState::new(100, 20);
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::FileTree(
                semantic::FileTree {
                    visible: true,
                    focused: true,
                    status: 0,
                    selected_id: "b".to_owned(),
                    root_path: String::new(),
                    width: 20,
                    error: String::new(),
                    rows: vec![
                        semantic::FileTreeRow {
                            id: "a".to_owned(),
                            name: "a.ex".to_owned(),
                            icon: String::new(),
                            icon_color: 0,
                            depth: 0,
                            flags: 0,
                            git_status: 0,
                            diagnostics: (0, 0, 0, 0),
                            editing_text: String::new(),
                        },
                        semantic::FileTreeRow {
                            id: "b".to_owned(),
                            name: "b.ex".to_owned(),
                            icon: String::new(),
                            icon_color: 0,
                            depth: 0,
                            flags: 0,
                            git_status: 0,
                            diagnostics: (0, 0, 0, 0),
                            editing_text: String::new(),
                        },
                    ],
                },
                0,
            ),
        ));
        let renderer = SemanticRenderer::new();

        let packet = renderer.semantic_mouse_packet(
            &state,
            &input::Event::Mouse {
                row: 1,
                col: 2,
                button: 0,
                modifiers: 0,
                event_type: 0,
                click_count: 1,
            },
        );

        assert_eq!(
            packet,
            Some(crate::protocol::encode_gui_file_tree_click(1).to_vec())
        );
    }

    #[test]
    fn ignores_non_semantic_mouse_clicks() {
        let state = SemanticState::new(100, 20);
        let renderer = SemanticRenderer::new();

        assert_eq!(
            renderer.semantic_mouse_packet(
                &state,
                &input::Event::Mouse {
                    row: 1,
                    col: 2,
                    button: 0,
                    modifiers: 0,
                    event_type: 0,
                    click_count: 1,
                },
            ),
            None
        );
    }

    #[test]
    fn resolves_status_bar_segment_click_to_execute_command() {
        let mut state = SemanticState::new(80, 20);
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::StatusBar(
                semantic::StatusBar {
                    left_segments: vec![semantic::StatusSegment {
                        name: "save".to_owned(),
                        text: " SAVE ".to_owned(),
                        command: "save".to_owned(),
                        fg: 0xFFFFFF,
                        bg: 0,
                        attrs: 0,
                    }],
                    ..semantic::StatusBar::default()
                },
                0,
            ),
        ));
        let renderer = SemanticRenderer::new();

        let packet = renderer.semantic_mouse_packet(
            &state,
            &input::Event::Mouse {
                row: 19,
                col: 2,
                button: 0,
                modifiers: 0,
                event_type: 0,
                click_count: 1,
            },
        );

        assert_eq!(
            packet,
            Some(crate::protocol::encode_gui_execute_command("save"))
        );
    }

    #[test]
    fn renders_retained_semantic_window_and_status_bar() {
        let mut state = SemanticState::new(220, 8);
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::WindowContent(
                semantic::WindowContent {
                    window_id: 1,
                    origin_row: 1,
                    origin_col: 0,
                    text_width: 40,
                    text_height: 4,
                    scroll_left: 0,
                    cursor_row: 0,
                    cursor_col: 5,
                    cursor_shape: 1,
                    content_epoch: 1,
                    rows: vec![row("hello semantic tui")],
                    cursorline: None,
                    selection: semantic::Selection::default(),
                    search_matches: Vec::new(),
                    diagnostic_ranges: Vec::new(),
                    document_highlights: Vec::new(),
                    annotations: Vec::new(),
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
                    items: Vec::new(),
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
                    spaces: Vec::new(),
                    tabs: Vec::new(),
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
                    entries: Vec::new(),
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Sidebars(
                semantic::Sidebars {
                    visible: 1,
                    active_id: "files".to_owned(),
                    items: vec![
                        semantic::Sidebar {
                            id: "files".to_owned(),
                            display_name: "Files".to_owned(),
                            semantic_kind: "file_tree".to_owned(),
                            icon: "F".to_owned(),
                            order: 0,
                            flags: 0x01,
                            preferred_width: 18,
                            badge_count: 0,
                            visible: true,
                            focused: false,
                        },
                        semantic::Sidebar {
                            id: "symbols".to_owned(),
                            display_name: "Symbols".to_owned(),
                            semantic_kind: "symbols".to_owned(),
                            icon: "S".to_owned(),
                            order: 1,
                            flags: 0x01,
                            preferred_width: 18,
                            badge_count: 0,
                            visible: true,
                            focused: false,
                        },
                    ],
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
                    count: 0,
                    nodes: Vec::new(),
                    payload: vec![1],
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::AgentChat(
                semantic::AgentChat {
                    visible: 1,
                    status: 1,
                    model_name: String::new(),
                    prompt: String::new(),
                    pending: String::new(),
                    thinking_level: String::new(),
                    messages: Vec::new(),
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::ToolManager(
                semantic::ToolManager {
                    visible: 1,
                    selected: 0,
                    tools: Vec::new(),
                },
                0,
            ),
        ));

        let mut terminal = Terminal::memory(220, 8);
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
        assert!(snapshot.contains("chat thinking"));
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
                    scroll_left: 0,
                    cursor_row: 0,
                    cursor_col: 4,
                    cursor_shape: 1,
                    content_epoch: 1,
                    rows: vec![row("workspace content")],
                    cursorline: None,
                    selection: semantic::Selection::default(),
                    search_matches: Vec::new(),
                    diagnostic_ranges: Vec::new(),
                    document_highlights: Vec::new(),
                    annotations: Vec::new(),
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
        assert!(snapshot.contains("Files  minga"));
        assert!(snapshot.contains("mix.exs"));
    }

    #[test]
    fn renders_editor_gutters_scroll_left_indent_guides_and_separators() {
        let mut state = SemanticState::new(48, 8);
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::WindowContent(
                semantic::WindowContent {
                    window_id: 7,
                    origin_row: 0,
                    origin_col: 0,
                    text_width: 24,
                    text_height: 4,
                    scroll_left: 2,
                    cursor_row: 0,
                    cursor_col: 0,
                    cursor_shape: 1,
                    content_epoch: 1,
                    rows: vec![row("    x")],
                    cursorline: Some(semantic::Cursorline {
                        row: 0,
                        bg: 0x333333,
                    }),
                    selection: semantic::Selection::default(),
                    search_matches: Vec::new(),
                    diagnostic_ranges: Vec::new(),
                    document_highlights: Vec::new(),
                    annotations: Vec::new(),
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Gutter(
                semantic::Gutter {
                    window_id: 7,
                    content_height: 4,
                    line_number_width: 3,
                    sign_col_width: 1,
                    entries: vec![
                        semantic::GutterEntry {
                            buf_line: 0,
                            display_type: 0,
                            sign_type: 0,
                            fold_end_line: 0,
                            sign_fg: 0,
                            sign_text: String::new(),
                        },
                        semantic::GutterEntry {
                            buf_line: 1,
                            display_type: 5,
                            sign_type: 0,
                            fold_end_line: 0,
                            sign_fg: 0,
                            sign_text: String::new(),
                        },
                    ],
                    ..semantic::Gutter::default()
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::IndentGuides(
                semantic::IndentGuides {
                    window_id: 7,
                    tab_width: 2,
                    active_guide_col: 2,
                    guide_cols: vec![2],
                    line_indent_levels: vec![2],
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::SplitSeparators(
                semantic::SplitSeparators {
                    color: 0,
                    verticals: vec![semantic::VerticalSeparator {
                        col: 24,
                        start_row: 0,
                        end_row: 1,
                    }],
                    horizontals: vec![semantic::HorizontalSeparator {
                        row: 2,
                        col: 0,
                        width: 16,
                        filename: "main.ex".to_owned(),
                    }],
                },
                0,
            ),
        ));

        let mut terminal = Terminal::memory(48, 8);
        SemanticRenderer::new()
            .render(&state, &mut terminal)
            .unwrap();

        let snapshot = terminal.buffer_text();
        assert!(snapshot.contains("1 │ x"));
        assert!(snapshot.contains("~"));
        assert!(snapshot.contains("│"));
        assert!(snapshot.contains("main.ex"));
    }

    #[test]
    fn renders_editor_line_annotations() {
        let mut state = SemanticState::new(40, 4);
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::WindowContent(
                semantic::WindowContent {
                    window_id: 7,
                    origin_row: 0,
                    origin_col: 0,
                    text_width: 40,
                    text_height: 1,
                    scroll_left: 0,
                    cursor_row: 0,
                    cursor_col: 0,
                    cursor_shape: 1,
                    content_epoch: 1,
                    rows: vec![row("let value = 1")],
                    cursorline: None,
                    selection: semantic::Selection::default(),
                    search_matches: Vec::new(),
                    diagnostic_ranges: Vec::new(),
                    document_highlights: Vec::new(),
                    annotations: vec![semantic::Annotation {
                        row: 0,
                        kind: 1,
                        fg: 0,
                        bg: 0,
                        text: "inferred integer".to_owned(),
                    }],
                },
                0,
            ),
        ));

        let mut terminal = Terminal::memory(40, 4);
        SemanticRenderer::new()
            .render(&state, &mut terminal)
            .unwrap();

        let snapshot = terminal.buffer_text();
        assert!(snapshot.contains("let value = 1 inferred integer"));
    }

    #[test]
    fn renders_go_parity_workspace_header_above_tabs() {
        let mut state = SemanticState::new(80, 8);
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::Workspaces(
                semantic::Workspaces {
                    visible: 1,
                    active_workspace_id: 2,
                    mode: 0,
                    flags: 0,
                    workspace_count: 4,
                    spaces: Vec::new(),
                    tabs: Vec::new(),
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::TabBar(
                semantic::TabBar {
                    active_index: 0,
                    tabs: vec![semantic::Tab {
                        active: true,
                        dirty: false,
                        attention: false,
                        icon: String::new(),
                        label: "RUST_TUI.md".to_owned(),
                        tint: 0,
                    }],
                },
                0,
            ),
        ));
        state.apply_protocol_command(crate::protocol::Command::Semantic(
            semantic::Command::StatusBar(
                semantic::StatusBar {
                    filename: "RUST_TUI.md".to_owned(),
                    line: 1,
                    col: 1,
                    ..semantic::StatusBar::default()
                },
                0,
            ),
        ));

        let mut terminal = Terminal::memory(80, 8);
        SemanticRenderer::new()
            .render(&state, &mut terminal)
            .unwrap();

        let lines: Vec<String> = terminal.buffer_text().lines().map(str::to_owned).collect();
        assert!(lines[0].contains("Spaces"));
        assert!(lines[0].contains("2/4"));
        assert!(lines[1].contains("RUST_TUI.md"));
        assert!(lines[7].contains("RUST_TUI.md"));
    }
}
