#[path = "renderer/chrome.rs"]
mod chrome;
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
use ratatui::layout::Rect;
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
            let content_area = content_area(frame.area(), state);
            let layout = layout::FrameLayout::compute(state, content_area);
            surfaces::render_frame(state, &layout, frame.buffer_mut());
            frame.set_cursor_position((state.cursor().col, state.cursor().row));
        })?;
        terminal.flush()
    }
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
