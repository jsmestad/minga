use super::layout::FrameLayout;
use super::theme::Palette;
use super::{chrome, editor, overlays};
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::widgets::{Paragraph, Widget};
use std::time::Instant;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SurfaceRenderMetrics {
    pub clear_us: u128,
    pub tree_us: u128,
    pub windows_us: u128,
    pub separators_us: u128,
    pub overlays_us: u128,
    pub bottom_panel_us: u128,
    pub chrome_us: u128,
}

pub fn render_frame(
    state: &SemanticState,
    layout: &FrameLayout,
    buffer: &mut Buffer,
) -> SurfaceRenderMetrics {
    let mut metrics = SurfaceRenderMetrics::default();

    let palette = Palette::new(state.theme());

    let started = Instant::now();
    buffer.set_style(layout.area, palette.editor_surface());
    metrics.clear_us = started.elapsed().as_micros();

    if let Some(diagnostic) = state.diagnostic() {
        let started = Instant::now();
        Paragraph::new(diagnostic.to_owned())
            .style(palette.diagnostic_style())
            .render(layout.body, buffer);
        metrics.windows_us = started.elapsed().as_micros();

        let started = Instant::now();
        chrome::render(state, layout, buffer);
        metrics.chrome_us = started.elapsed().as_micros();
        return metrics;
    }

    let started = Instant::now();
    if let Some(file_tree) = super::layout::visible_file_tree(state) {
        editor::render_file_tree(file_tree, state.theme(), layout.file_tree, buffer);
    } else if let Some(sidebars) = super::layout::visible_sidebars(state) {
        editor::render_sidebars(sidebars, state.theme(), layout.file_tree, buffer);
    }
    metrics.tree_us = started.elapsed().as_micros();

    let started = Instant::now();
    editor::render_windows(state, layout.area, buffer);
    metrics.windows_us = started.elapsed().as_micros();

    let started = Instant::now();
    editor::render_separators(state, layout.area, buffer);
    metrics.separators_us = started.elapsed().as_micros();

    let started = Instant::now();
    overlays::render(state, overlay_area(layout), buffer);
    metrics.overlays_us = started.elapsed().as_micros();

    let started = Instant::now();
    if let Some(bottom_panel) = layout.bottom_panel {
        editor::render_bottom_panel(state, bottom_panel, buffer);
    }
    metrics.bottom_panel_us = started.elapsed().as_micros();

    let started = Instant::now();
    chrome::render(state, layout, buffer);
    metrics.chrome_us = started.elapsed().as_micros();

    metrics
}

fn overlay_area(layout: &FrameLayout) -> Rect {
    let height = layout
        .bottom_panel
        .map(|panel| panel.y.saturating_sub(layout.area.y))
        .unwrap_or(layout.area.height);

    Rect {
        x: layout.area.x,
        y: layout.area.y,
        width: layout.area.width,
        height,
    }
}
