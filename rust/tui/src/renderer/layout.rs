use crate::semantic;
use crate::semantic_state::SemanticState;
use ratatui::layout::{Constraint, Direction, Layout, Rect};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameLayout {
    pub area: Rect,
    pub tab_bar: Rect,
    pub body: Rect,
    pub file_tree: Rect,
    pub editor: Rect,
    pub bottom_panel: Option<Rect>,
    pub minibuffer: Rect,
    pub status_bar: Rect,
}

impl FrameLayout {
    pub fn compute(state: &SemanticState, area: Rect) -> Self {
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

        let horizontal = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Length(file_tree_width(state.file_tree())),
                Constraint::Min(1),
            ])
            .split(vertical[1]);

        let (editor, bottom_panel) = bottom_panel_split(state.bottom_panel(), horizontal[1]);

        Self {
            area,
            tab_bar: vertical[0],
            body: vertical[1],
            file_tree: horizontal[0],
            editor,
            bottom_panel,
            minibuffer: vertical[2],
            status_bar: vertical[3],
        }
    }
}

pub fn visible_minibuffer(state: &SemanticState) -> Option<&semantic::Minibuffer> {
    state.minibuffer().filter(|minibuffer| minibuffer.visible)
}

pub fn visible_picker_preview(state: &SemanticState) -> Option<&semantic::PickerPreview> {
    state
        .picker_preview()
        .filter(|preview| preview.visible && !preview.lines.is_empty())
}

fn file_tree_width(file_tree: Option<&semantic::FileTree>) -> u16 {
    file_tree
        .filter(|tree| tree.visible)
        .map(|tree| tree.width)
        .unwrap_or(0)
}

fn bottom_panel_split(panel: Option<&semantic::BottomPanel>, area: Rect) -> (Rect, Option<Rect>) {
    let Some(panel) = panel.filter(|panel| panel.visible && !panel.entries.is_empty()) else {
        return (area, None);
    };

    let percent = panel.height_percent.clamp(10, 60) as u16;
    let requested_height = area.height.saturating_mul(percent) / 100;
    let panel_height = super::geometry::bounded_dimension(requested_height, 3, area.height);
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(panel_height)])
        .split(area);
    (chunks[0], Some(chunks[1]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::Command as ProtocolCommand;

    #[test]
    fn reserves_chrome_and_bottom_panel_regions() {
        let mut state = SemanticState::new(100, 30);
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::TabBar(
            semantic::TabBar {
                active_index: 0,
                tabs: Vec::new(),
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::StatusBar(
            semantic::StatusBar::default(),
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::Minibuffer(
            semantic::Minibuffer {
                visible: true,
                ..semantic::Minibuffer::default()
            },
            0,
        )));
        state.apply_protocol_command(ProtocolCommand::Semantic(semantic::Command::BottomPanel(
            semantic::BottomPanel {
                visible: true,
                height_percent: 25,
                entries: vec![semantic::BottomPanelEntry {
                    id: 1,
                    level: 0,
                    subsystem: 0,
                    timestamp_secs: 0,
                    file_path: String::new(),
                    text: "entry".to_owned(),
                }],
                ..semantic::BottomPanel::default()
            },
            0,
        )));

        let layout = FrameLayout::compute(
            &state,
            Rect {
                x: 0,
                y: 0,
                width: 100,
                height: 30,
            },
        );

        assert_eq!(layout.tab_bar.height, 1);
        assert_eq!(layout.minibuffer.height, 1);
        assert_eq!(layout.status_bar.height, 1);
        assert_eq!(layout.bottom_panel.unwrap().height, 6);
        assert_eq!(layout.editor.height, 21);
    }

    #[test]
    fn omits_hidden_optional_regions() {
        let state = SemanticState::new(80, 10);
        let layout = FrameLayout::compute(
            &state,
            Rect {
                x: 0,
                y: 0,
                width: 80,
                height: 10,
            },
        );

        assert_eq!(layout.tab_bar.height, 0);
        assert_eq!(layout.minibuffer.height, 0);
        assert_eq!(layout.status_bar.height, 0);
        assert!(layout.bottom_panel.is_none());
        assert_eq!(layout.editor.height, 10);
    }
}
