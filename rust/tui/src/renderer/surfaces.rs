use super::{chrome, editor, overlays};
use super::{layout::FrameLayout, theme};
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::widgets::{Paragraph, Widget};

pub fn render_frame(state: &SemanticState, layout: &FrameLayout, buffer: &mut Buffer) {
    chrome::render(state, layout, buffer);

    if let Some(diagnostic) = state.diagnostic() {
        Paragraph::new(diagnostic.to_owned())
            .style(theme::diagnostic())
            .render(layout.body, buffer);
        return;
    }

    if let Some(file_tree) = state.file_tree().filter(|tree| tree.visible) {
        editor::render_file_tree(file_tree, layout.file_tree, buffer);
    }

    editor::render_windows(state, layout.editor, buffer);
    editor::render_breadcrumb(state, layout.editor, buffer);

    if let Some(bottom_panel) = layout.bottom_panel {
        editor::render_bottom_panel(state, bottom_panel, buffer);
    }

    editor::render_separators(state, layout.area, buffer);
    overlays::render(state, layout.editor, buffer);
}
