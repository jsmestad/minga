use crate::protocol::Command as ProtocolCommand;
use crate::semantic;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct SemanticState {
    width: u16,
    height: u16,
    windows: HashMap<u16, semantic::WindowContent>,
    window_order: Vec<u16>,
    status_bar: Option<semantic::StatusBar>,
    tab_bar: Option<semantic::TabBar>,
    file_tree: Option<semantic::FileTree>,
    line_spacing: Option<semantic::LineSpacing>,
    cursor_animation: Option<semantic::CursorAnimation>,
    config_state: Option<semantic::ConfigState>,
    agent_context: Option<semantic::AgentContext>,
    hover_action: Option<semantic::HoverAction>,
    search_state: Option<semantic::SearchState>,
    notifications: Option<semantic::Notifications>,
    diagnostic: Option<String>,
    cursor: CursorState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorState {
    pub row: u16,
    pub col: u16,
    pub shape: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateEffect {
    pub render: bool,
    pub title: Option<String>,
}

impl SemanticState {
    pub fn new(width: u16, height: u16) -> Self {
        Self {
            width,
            height,
            windows: HashMap::new(),
            window_order: Vec::new(),
            status_bar: None,
            tab_bar: None,
            file_tree: None,
            line_spacing: None,
            cursor_animation: None,
            config_state: None,
            agent_context: None,
            hover_action: None,
            search_state: None,
            notifications: None,
            diagnostic: None,
            cursor: CursorState {
                row: 0,
                col: 0,
                shape: 0,
            },
        }
    }

    pub fn resize(&mut self, width: u16, height: u16) {
        self.width = width;
        self.height = height;
    }

    pub fn apply_protocol_command(&mut self, command: ProtocolCommand) -> StateEffect {
        match command {
            ProtocolCommand::Clear => {
                self.clear();
                StateEffect::render()
            }
            ProtocolCommand::BatchEnd => StateEffect::render(),
            ProtocolCommand::SetCursor { row, col } => {
                self.cursor.row = row;
                self.cursor.col = col;
                StateEffect::render()
            }
            ProtocolCommand::SetCursorShape(shape) => {
                self.cursor.shape = shape;
                StateEffect::render()
            }
            ProtocolCommand::SetTitle(title) => StateEffect {
                render: false,
                title: Some(title),
            },
            ProtocolCommand::Semantic(command) => {
                self.apply_semantic_command(command);
                StateEffect::render()
            }
            ProtocolCommand::DrawText(_) | ProtocolCommand::DrawStyledText(_) => {
                self.diagnostic = Some(
                    "Semantic UI required: received legacy cell-grid command in Rust semantic TUI."
                        .to_owned(),
                );
                StateEffect::render()
            }
            ProtocolCommand::SetWindowBg(_)
            | ProtocolCommand::DefineRegion(_)
            | ProtocolCommand::ClearRegion(_)
            | ProtocolCommand::DestroyRegion(_)
            | ProtocolCommand::SetActiveRegion(_)
            | ProtocolCommand::ScrollRegion { .. }
            | ProtocolCommand::MeasureText { .. }
            | ProtocolCommand::Noop(_) => StateEffect {
                render: false,
                title: None,
            },
        }
    }

    pub fn width(&self) -> u16 {
        self.width
    }

    pub fn height(&self) -> u16 {
        self.height
    }

    pub fn windows(&self) -> impl Iterator<Item = &semantic::WindowContent> {
        self.window_order
            .iter()
            .filter_map(|window_id| self.windows.get(window_id))
    }

    pub fn status_bar(&self) -> Option<&semantic::StatusBar> {
        self.status_bar.as_ref()
    }

    pub fn tab_bar(&self) -> Option<&semantic::TabBar> {
        self.tab_bar.as_ref()
    }

    pub fn file_tree(&self) -> Option<&semantic::FileTree> {
        self.file_tree.as_ref()
    }

    pub fn agent_context(&self) -> Option<&semantic::AgentContext> {
        self.agent_context.as_ref()
    }

    pub fn search_state(&self) -> Option<semantic::SearchState> {
        self.search_state
    }

    pub fn notifications(&self) -> Option<semantic::Notifications> {
        self.notifications
    }

    pub fn diagnostic(&self) -> Option<&str> {
        self.diagnostic.as_deref()
    }

    pub fn cursor(&self) -> CursorState {
        self.cursor
    }

    fn clear(&mut self) {
        self.windows.clear();
        self.window_order.clear();
        self.status_bar = None;
        self.tab_bar = None;
        self.file_tree = None;
        self.line_spacing = None;
        self.cursor_animation = None;
        self.config_state = None;
        self.agent_context = None;
        self.hover_action = None;
        self.search_state = None;
        self.notifications = None;
        self.diagnostic = None;
        self.cursor = CursorState {
            row: 0,
            col: 0,
            shape: 0,
        };
    }

    fn apply_semantic_command(&mut self, command: semantic::Command) {
        self.diagnostic = None;

        match command {
            semantic::Command::WindowContent(window, _) => self.put_window(window),
            semantic::Command::WindowRowsDelta(delta, _) => self.apply_window_rows_delta(delta),
            semantic::Command::StatusBar(status_bar, _) => self.status_bar = Some(status_bar),
            semantic::Command::TabBar(tab_bar, _) => self.tab_bar = Some(tab_bar),
            semantic::Command::FileTree(file_tree, _) => self.file_tree = Some(file_tree),
            semantic::Command::FileTreeSelection(selection, _) => {
                self.apply_file_tree_selection(selection)
            }
            semantic::Command::Cursorline(cursorline, _) => self.apply_cursorline(cursorline),
            semantic::Command::LineSpacing(line_spacing, _) => {
                self.line_spacing = Some(line_spacing)
            }
            semantic::Command::CursorAnimation(cursor_animation, _) => {
                self.cursor_animation = Some(cursor_animation)
            }
            semantic::Command::ConfigState(config_state, _) => {
                self.config_state = Some(config_state)
            }
            semantic::Command::AgentContext(agent_context, _) => {
                self.agent_context = Some(agent_context)
            }
            semantic::Command::HoverAction(hover_action, _) => {
                self.hover_action = Some(hover_action)
            }
            semantic::Command::SearchState(search_state, _) => {
                self.search_state = Some(search_state)
            }
            semantic::Command::Notifications(notifications, _) => {
                self.notifications = Some(notifications)
            }
            semantic::Command::Picker(..)
            | semantic::Command::PickerPreview(..)
            | semantic::Command::Minibuffer(..)
            | semantic::Command::Breadcrumb(..)
            | semantic::Command::Completion(..)
            | semantic::Command::WhichKey(..)
            | semantic::Command::SignatureHelp(..)
            | semantic::Command::FloatPopup(..)
            | semantic::Command::HoverPopup(..)
            | semantic::Command::BottomPanel(..)
            | semantic::Command::ChangeSummary(..)
            | semantic::Command::GitStatus(..)
            | semantic::Command::Theme(..)
            | semantic::Command::Gutter(..)
            | semantic::Command::GutterSeparator(..)
            | semantic::Command::SplitSeparators(..)
            | semantic::Command::IndentGuides(..)
            | semantic::Command::WindowOverlayDelta(..)
            | semantic::Command::ClipboardWrite(..)
            | semantic::Command::Workspaces(..)
            | semantic::Command::EditTimeline(..)
            | semantic::Command::ExtensionOverlay(..)
            | semantic::Command::ExtensionPanel(..)
            | semantic::Command::Observatory(..)
            | semantic::Command::Sidebars(..)
            | semantic::Command::Board(..)
            | semantic::Command::AgentChat(..)
            | semantic::Command::ToolManager(..) => {}
        }
    }

    fn put_window(&mut self, window: semantic::WindowContent) {
        if !self.windows.contains_key(&window.window_id) {
            self.window_order.push(window.window_id);
            self.window_order.sort_unstable();
        }

        self.cursor = CursorState {
            row: window.origin_row.saturating_add(window.cursor_row),
            col: window.origin_col.saturating_add(window.cursor_col),
            shape: window.cursor_shape,
        };
        self.windows.insert(window.window_id, window);
    }

    fn apply_window_rows_delta(&mut self, delta: semantic::WindowRowsDelta) {
        let Some(window) = self.windows.get_mut(&delta.window_id) else {
            return;
        };
        if window.content_epoch != delta.content_epoch {
            return;
        }

        let retained_rows = window.rows.clone();
        let mut rows = Vec::with_capacity(delta.rows.len());

        for row in delta.rows {
            match row {
                semantic::WindowDeltaRow::Full(row) => rows.push(row),
                semantic::WindowDeltaRow::Ref {
                    row_id,
                    content_hash,
                } => {
                    if let Some(row) = retained_rows
                        .iter()
                        .find(|row| row.row_id == row_id && row.content_hash == content_hash)
                        .cloned()
                    {
                        rows.push(row);
                    } else {
                        return;
                    }
                }
            }
        }

        window.rows = rows;
        window.cursorline = delta.cursorline;
        if delta.cursor_visible {
            self.cursor = CursorState {
                row: window.origin_row.saturating_add(delta.cursor_row),
                col: window.origin_col.saturating_add(delta.cursor_col),
                shape: delta.cursor_shape,
            };
        }
    }

    fn apply_file_tree_selection(&mut self, selection: semantic::FileTreeSelection) {
        let Some(file_tree) = self.file_tree.as_mut() else {
            return;
        };
        file_tree.focused = selection.focused;
        file_tree.selected_id = selection.selected_id;
    }

    fn apply_cursorline(&mut self, cursorline: semantic::Cursorline) {
        for window in self.windows.values_mut() {
            window.cursorline = Some(cursorline);
        }
    }
}

impl StateEffect {
    fn render() -> Self {
        Self {
            render: true,
            title: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: u64, hash: u32, text: &str) -> semantic::Row {
        semantic::Row {
            row_type: 0,
            row_id: id,
            buf_line: 0,
            content_hash: hash,
            text: text.to_owned(),
            spans: Vec::new(),
        }
    }

    fn window(rows: Vec<semantic::Row>) -> semantic::WindowContent {
        semantic::WindowContent {
            window_id: 7,
            origin_row: 1,
            origin_col: 2,
            text_width: 20,
            text_height: 5,
            cursor_row: 0,
            cursor_col: 1,
            cursor_shape: 2,
            content_epoch: 42,
            rows,
            cursorline: None,
        }
    }

    #[test]
    fn retains_semantic_window_state_and_cursor() {
        let mut state = SemanticState::new(80, 24);
        let effect = state.apply_protocol_command(ProtocolCommand::Semantic(
            semantic::Command::WindowContent(window(vec![row(1, 11, "alpha")]), 0),
        ));

        assert!(effect.render);
        assert_eq!(state.windows().next().unwrap().rows[0].text, "alpha");
        assert_eq!(
            state.cursor(),
            CursorState {
                row: 1,
                col: 3,
                shape: 2
            }
        );
    }

    #[test]
    fn applies_window_rows_delta_from_retained_rows() {
        let mut state = SemanticState::new(80, 24);
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::WindowContent(
            window(vec![row(1, 11, "alpha"), row(2, 22, "beta")]),
            0,
        )));

        state.apply_protocol_command(ProtocolCommand::Semantic(
            semantic::Command::WindowRowsDelta(
                semantic::WindowRowsDelta {
                    window_id: 7,
                    content_epoch: 42,
                    cursor_visible: true,
                    cursor_row: 1,
                    cursor_col: 4,
                    cursor_shape: 1,
                    rows: vec![
                        semantic::WindowDeltaRow::Ref {
                            row_id: 1,
                            content_hash: 11,
                        },
                        semantic::WindowDeltaRow::Full(row(3, 33, "gamma")),
                    ],
                    cursorline: None,
                },
                0,
            ),
        ));

        let texts: Vec<_> = state
            .windows()
            .next()
            .unwrap()
            .rows
            .iter()
            .map(|row| row.text.as_str())
            .collect();
        assert_eq!(texts, vec!["alpha", "gamma"]);
        assert_eq!(
            state.cursor(),
            CursorState {
                row: 2,
                col: 6,
                shape: 1
            }
        );
    }

    #[test]
    fn retains_simple_semantic_parity_state() {
        let mut state = SemanticState::new(80, 24);

        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::LineSpacing(
            semantic::LineSpacing { value: 2 },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(
            semantic::Command::CursorAnimation(semantic::CursorAnimation { enabled: 1 }, 0),
        ));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::ConfigState(
            semantic::ConfigState {
                payload: vec![1, 2, 3],
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::AgentContext(
            semantic::AgentContext {
                visible: 1,
                task: "review".to_owned(),
                timestamp: 9,
                status: 2,
                can_approve: 1,
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::HoverAction(
            semantic::HoverAction {
                payload: vec![4, 5],
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::SearchState(
            semantic::SearchState {
                active: 1,
                match_count: 5,
                current_index: 2,
                flags: 0,
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::Notifications(
            semantic::Notifications {
                visible: 1,
                notification_count: 2,
            },
            0,
        )));

        assert_eq!(state.line_spacing.unwrap().value, 2);
        assert_eq!(state.cursor_animation.unwrap().enabled, 1);
        assert_eq!(state.config_state.as_ref().unwrap().payload, vec![1, 2, 3]);
        assert_eq!(state.agent_context().unwrap().task, "review");
        assert_eq!(state.hover_action.as_ref().unwrap().payload, vec![4, 5]);
        assert_eq!(state.search_state().unwrap().match_count, 5);
        assert_eq!(state.notifications().unwrap().notification_count, 2);

        state.apply_protocol_command(ProtocolCommand::Clear);

        assert!(state.line_spacing.is_none());
        assert!(state.cursor_animation.is_none());
        assert!(state.config_state.is_none());
        assert!(state.agent_context().is_none());
        assert!(state.hover_action.is_none());
        assert!(state.search_state().is_none());
        assert!(state.notifications().is_none());
    }
}
