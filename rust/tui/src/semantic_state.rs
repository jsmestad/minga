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
    picker: Option<semantic::Picker>,
    picker_preview: Option<semantic::PickerPreview>,
    minibuffer: Option<semantic::Minibuffer>,
    breadcrumb: Option<semantic::Breadcrumb>,
    completion: Option<semantic::Completion>,
    which_key: Option<semantic::WhichKey>,
    signature_help: Option<semantic::SignatureHelp>,
    float_popup: Option<semantic::FloatPopup>,
    hover_popup: Option<semantic::HoverPopup>,
    bottom_panel: Option<semantic::BottomPanel>,
    change_summary: Option<semantic::ChangeSummary>,
    git_status: Option<semantic::GitStatus>,
    line_spacing: Option<semantic::LineSpacing>,
    cursor_animation: Option<semantic::CursorAnimation>,
    config_state: Option<semantic::ConfigState>,
    agent_context: Option<semantic::AgentContext>,
    hover_action: Option<semantic::HoverAction>,
    search_state: Option<semantic::SearchState>,
    notifications: Option<semantic::Notifications>,
    workspaces: Option<semantic::Workspaces>,
    edit_timeline: Option<semantic::EditTimeline>,
    extension_overlay: Option<semantic::ExtensionOverlay>,
    extension_panel: Option<semantic::ExtensionPanel>,
    observatory: Option<semantic::Observatory>,
    sidebars: Option<semantic::Sidebars>,
    board: Option<semantic::Board>,
    agent_chat: Option<semantic::AgentChat>,
    tool_manager: Option<semantic::ToolManager>,
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
    pub clipboard: Option<semantic::ClipboardWrite>,
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
            picker: None,
            picker_preview: None,
            minibuffer: None,
            breadcrumb: None,
            completion: None,
            which_key: None,
            signature_help: None,
            float_popup: None,
            hover_popup: None,
            bottom_panel: None,
            change_summary: None,
            git_status: None,
            line_spacing: None,
            cursor_animation: None,
            config_state: None,
            agent_context: None,
            hover_action: None,
            search_state: None,
            notifications: None,
            workspaces: None,
            edit_timeline: None,
            extension_overlay: None,
            extension_panel: None,
            observatory: None,
            sidebars: None,
            board: None,
            agent_chat: None,
            tool_manager: None,
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
                clipboard: None,
            },
            ProtocolCommand::Semantic(command) => self.apply_semantic_command(command),
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
                clipboard: None,
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

    pub fn picker(&self) -> Option<&semantic::Picker> {
        self.picker.as_ref()
    }

    pub fn picker_preview(&self) -> Option<&semantic::PickerPreview> {
        self.picker_preview.as_ref()
    }

    pub fn minibuffer(&self) -> Option<&semantic::Minibuffer> {
        self.minibuffer.as_ref()
    }

    pub fn breadcrumb(&self) -> Option<&semantic::Breadcrumb> {
        self.breadcrumb.as_ref()
    }

    pub fn completion(&self) -> Option<&semantic::Completion> {
        self.completion.as_ref()
    }

    pub fn which_key(&self) -> Option<&semantic::WhichKey> {
        self.which_key.as_ref()
    }

    pub fn signature_help(&self) -> Option<&semantic::SignatureHelp> {
        self.signature_help.as_ref()
    }

    pub fn float_popup(&self) -> Option<&semantic::FloatPopup> {
        self.float_popup.as_ref()
    }

    pub fn hover_popup(&self) -> Option<&semantic::HoverPopup> {
        self.hover_popup.as_ref()
    }

    pub fn bottom_panel(&self) -> Option<&semantic::BottomPanel> {
        self.bottom_panel.as_ref()
    }

    pub fn change_summary(&self) -> Option<&semantic::ChangeSummary> {
        self.change_summary.as_ref()
    }

    pub fn git_status(&self) -> Option<&semantic::GitStatus> {
        self.git_status.as_ref()
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

    pub fn workspaces(&self) -> Option<semantic::Workspaces> {
        self.workspaces
    }

    pub fn edit_timeline(&self) -> Option<semantic::EditTimeline> {
        self.edit_timeline
    }

    pub fn extension_overlay(&self) -> Option<semantic::ExtensionOverlay> {
        self.extension_overlay
    }

    pub fn extension_panel(&self) -> Option<semantic::ExtensionPanel> {
        self.extension_panel
    }

    pub fn observatory(&self) -> Option<&semantic::Observatory> {
        self.observatory.as_ref()
    }

    pub fn sidebars(&self) -> Option<&semantic::Sidebars> {
        self.sidebars.as_ref()
    }

    pub fn agent_chat(&self) -> Option<semantic::AgentChat> {
        self.agent_chat
    }

    pub fn tool_manager(&self) -> Option<semantic::ToolManager> {
        self.tool_manager
    }

    pub fn diagnostic(&self) -> Option<&str> {
        self.diagnostic.as_deref()
    }

    pub fn cursor(&self) -> CursorState {
        self.cursor
    }

    pub fn cursor_animation_enabled(&self) -> bool {
        self.cursor_animation
            .is_none_or(|cursor_animation| cursor_animation.enabled != 0)
    }

    fn clear(&mut self) {
        self.windows.clear();
        self.window_order.clear();
        self.status_bar = None;
        self.tab_bar = None;
        self.file_tree = None;
        self.picker = None;
        self.picker_preview = None;
        self.minibuffer = None;
        self.breadcrumb = None;
        self.completion = None;
        self.which_key = None;
        self.signature_help = None;
        self.float_popup = None;
        self.hover_popup = None;
        self.bottom_panel = None;
        self.change_summary = None;
        self.git_status = None;
        self.line_spacing = None;
        self.cursor_animation = None;
        self.config_state = None;
        self.agent_context = None;
        self.hover_action = None;
        self.search_state = None;
        self.notifications = None;
        self.workspaces = None;
        self.edit_timeline = None;
        self.extension_overlay = None;
        self.extension_panel = None;
        self.observatory = None;
        self.sidebars = None;
        self.board = None;
        self.agent_chat = None;
        self.tool_manager = None;
        self.diagnostic = None;
        self.cursor = CursorState {
            row: 0,
            col: 0,
            shape: 0,
        };
    }

    fn apply_semantic_command(&mut self, command: semantic::Command) -> StateEffect {
        self.diagnostic = None;

        match command {
            semantic::Command::WindowContent(window, _) => {
                self.put_window(window);
                StateEffect::render()
            }
            semantic::Command::WindowRowsDelta(delta, _) => {
                self.apply_window_rows_delta(delta);
                StateEffect::render()
            }
            semantic::Command::StatusBar(status_bar, _) => {
                self.status_bar = Some(status_bar);
                StateEffect::render()
            }
            semantic::Command::TabBar(tab_bar, _) => {
                self.tab_bar = Some(tab_bar);
                StateEffect::render()
            }
            semantic::Command::FileTree(file_tree, _) => {
                self.file_tree = Some(file_tree);
                StateEffect::render()
            }
            semantic::Command::FileTreeSelection(selection, _) => {
                self.apply_file_tree_selection(selection);
                StateEffect::render()
            }
            semantic::Command::Picker(picker, _) => {
                self.picker = Some(picker);
                StateEffect::render()
            }
            semantic::Command::PickerPreview(preview, _) => {
                self.picker_preview = Some(preview);
                StateEffect::render()
            }
            semantic::Command::Minibuffer(minibuffer, _) => {
                self.minibuffer = Some(minibuffer);
                StateEffect::render()
            }
            semantic::Command::Breadcrumb(breadcrumb, _) => {
                self.breadcrumb = Some(breadcrumb);
                StateEffect::render()
            }
            semantic::Command::Completion(completion, _) => {
                self.completion = Some(completion);
                StateEffect::render()
            }
            semantic::Command::WhichKey(which_key, _) => {
                self.which_key = Some(which_key);
                StateEffect::render()
            }
            semantic::Command::SignatureHelp(signature_help, _) => {
                self.signature_help = Some(signature_help);
                StateEffect::render()
            }
            semantic::Command::FloatPopup(float_popup, _) => {
                self.float_popup = Some(float_popup);
                StateEffect::render()
            }
            semantic::Command::HoverPopup(hover_popup, _) => {
                self.hover_popup = Some(hover_popup);
                StateEffect::render()
            }
            semantic::Command::BottomPanel(bottom_panel, _) => {
                self.bottom_panel = Some(bottom_panel);
                StateEffect::render()
            }
            semantic::Command::ChangeSummary(change_summary, _) => {
                self.change_summary = Some(change_summary);
                StateEffect::render()
            }
            semantic::Command::GitStatus(git_status, _) => {
                self.git_status = Some(git_status);
                StateEffect::render()
            }
            semantic::Command::Cursorline(cursorline, _) => {
                self.apply_cursorline(cursorline);
                StateEffect::render()
            }
            semantic::Command::LineSpacing(line_spacing, _) => {
                self.line_spacing = Some(line_spacing);
                StateEffect::render()
            }
            semantic::Command::CursorAnimation(cursor_animation, _) => {
                self.cursor_animation = Some(cursor_animation);
                StateEffect::render()
            }
            semantic::Command::ConfigState(config_state, _) => {
                self.config_state = Some(config_state);
                StateEffect::render()
            }
            semantic::Command::AgentContext(agent_context, _) => {
                self.agent_context = Some(agent_context);
                StateEffect::render()
            }
            semantic::Command::HoverAction(hover_action, _) => {
                self.hover_action = Some(hover_action);
                StateEffect::render()
            }
            semantic::Command::SearchState(search_state, _) => {
                self.search_state = Some(search_state);
                StateEffect::render()
            }
            semantic::Command::Notifications(notifications, _) => {
                self.notifications = Some(notifications);
                StateEffect::render()
            }
            semantic::Command::ClipboardWrite(clipboard, _) => StateEffect {
                render: false,
                title: None,
                clipboard: Some(clipboard),
            },
            semantic::Command::Workspaces(workspaces, _) => {
                self.workspaces = Some(workspaces);
                StateEffect::render()
            }
            semantic::Command::EditTimeline(edit_timeline, _) => {
                self.edit_timeline = Some(edit_timeline);
                StateEffect::render()
            }
            semantic::Command::ExtensionOverlay(extension_overlay, _) => {
                self.extension_overlay = Some(extension_overlay);
                StateEffect::render()
            }
            semantic::Command::ExtensionPanel(extension_panel, _) => {
                self.extension_panel = Some(extension_panel);
                StateEffect::render()
            }
            semantic::Command::Observatory(observatory, _) => {
                self.observatory = Some(observatory);
                StateEffect::render()
            }
            semantic::Command::Sidebars(sidebars, _) => {
                self.sidebars = Some(sidebars);
                StateEffect::render()
            }
            semantic::Command::Board(board, _) => {
                self.board = Some(board);
                StateEffect::render()
            }
            semantic::Command::AgentChat(agent_chat, _) => {
                self.agent_chat = Some(agent_chat);
                StateEffect::render()
            }
            semantic::Command::ToolManager(tool_manager, _) => {
                self.tool_manager = Some(tool_manager);
                StateEffect::render()
            }
            semantic::Command::Theme(..)
            | semantic::Command::Gutter(..)
            | semantic::Command::GutterSeparator(..)
            | semantic::Command::SplitSeparators(..)
            | semantic::Command::IndentGuides(..)
            | semantic::Command::WindowOverlayDelta(..) => StateEffect::render(),
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
            clipboard: None,
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
    fn emits_clipboard_side_effect_without_rendering() {
        let mut state = SemanticState::new(80, 24);
        let effect = state.apply_protocol_command(ProtocolCommand::Semantic(
            semantic::Command::ClipboardWrite(
                semantic::ClipboardWrite {
                    target: 0,
                    text: "copied".to_owned(),
                },
                0,
            ),
        ));

        assert!(!effect.render);
        assert!(effect.title.is_none());
        assert_eq!(effect.clipboard.unwrap().text, "copied");
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
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::Workspaces(
            semantic::Workspaces {
                visible: 1,
                active_workspace_id: 7,
                mode: 0,
                flags: 0,
                workspace_count: 3,
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::EditTimeline(
            semantic::EditTimeline {
                visible: 1,
                viewing_index: 1,
                entry_count: 4,
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(
            semantic::Command::ExtensionOverlay(semantic::ExtensionOverlay { entry_count: 5 }, 0),
        ));
        state.apply_protocol_command(ProtocolCommand::Semantic(
            semantic::Command::ExtensionPanel(semantic::ExtensionPanel { panel_count: 6 }, 0),
        ));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::Observatory(
            semantic::Observatory {
                visible: true,
                payload: vec![6, 7],
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::Sidebars(
            semantic::Sidebars {
                visible: 1,
                sidebar_count: 8,
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::Board(
            semantic::Board {
                visible: 1,
                focused_card_id: 9,
                card_count: 10,
                filter_mode: 0,
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::AgentChat(
            semantic::AgentChat {
                visible: 1,
                flags: 0,
                message_count: 11,
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::ToolManager(
            semantic::ToolManager { visible: 1 },
            0,
        )));

        assert_eq!(state.line_spacing.unwrap().value, 2);
        assert_eq!(state.cursor_animation.unwrap().enabled, 1);
        assert!(state.cursor_animation_enabled());
        assert_eq!(state.config_state.as_ref().unwrap().payload, vec![1, 2, 3]);
        assert_eq!(state.agent_context().unwrap().task, "review");
        assert_eq!(state.hover_action.as_ref().unwrap().payload, vec![4, 5]);
        assert_eq!(state.search_state().unwrap().match_count, 5);
        assert_eq!(state.notifications().unwrap().notification_count, 2);
        assert_eq!(state.workspaces().unwrap().active_workspace_id, 7);
        assert_eq!(state.edit_timeline().unwrap().entry_count, 4);
        assert_eq!(state.extension_overlay().unwrap().entry_count, 5);
        assert_eq!(state.extension_panel().unwrap().panel_count, 6);
        assert_eq!(state.observatory().unwrap().payload, vec![6, 7]);
        assert_eq!(state.sidebars().unwrap().sidebar_count, 8);
        assert_eq!(state.board.unwrap().card_count, 10);
        assert_eq!(state.agent_chat().unwrap().message_count, 11);
        assert_eq!(state.tool_manager().unwrap().visible, 1);

        state.apply_protocol_command(ProtocolCommand::Clear);

        assert!(state.line_spacing.is_none());
        assert!(state.cursor_animation.is_none());
        assert!(state.cursor_animation_enabled());
        assert!(state.config_state.is_none());
        assert!(state.agent_context().is_none());
        assert!(state.hover_action.is_none());
        assert!(state.search_state().is_none());
        assert!(state.notifications().is_none());
        assert!(state.workspaces().is_none());
        assert!(state.edit_timeline().is_none());
        assert!(state.extension_overlay().is_none());
        assert!(state.extension_panel().is_none());
        assert!(state.observatory().is_none());
        assert!(state.sidebars().is_none());
        assert!(state.board.is_none());
        assert!(state.agent_chat().is_none());
        assert!(state.tool_manager().is_none());
    }

    #[test]
    fn cursor_animation_zero_disables_terminal_blinking() {
        let mut state = SemanticState::new(80, 24);

        state.apply_protocol_command(ProtocolCommand::Semantic(
            semantic::Command::CursorAnimation(semantic::CursorAnimation { enabled: 0 }, 0),
        ));

        assert!(!state.cursor_animation_enabled());
    }
}
