use super::geometry;
use super::layout;
use super::theme;
use crate::semantic;
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Widget, Wrap};

pub fn render(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    render_completion(state, area, buffer);
    render_signature_help(state, area, buffer);
    render_hover_popup(state, area, buffer);
    render_float_popup(state, area, buffer);
    render_change_summary(state, area, buffer);
    render_which_key(state, area, buffer);
    render_picker(state, area, buffer);
}

fn render_completion(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
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
    let rect = geometry::anchored_rect(
        area,
        completion.anchor_col,
        completion.anchor_row.saturating_add(1),
        width,
        height,
    );
    Clear.render(rect, buffer);
    let lines = completion.items.iter().enumerate().map(|(index, item)| {
        let style = if index == completion.selected_index as usize {
            theme::selected(Color::Cyan)
        } else {
            theme::overlay()
        };
        Line::styled(format!("{}  {}", item.label, item.detail), style)
    });
    Paragraph::new(lines.collect::<Vec<_>>())
        .block(Block::default().borders(Borders::ALL).title("Complete"))
        .render(rect, buffer);
}

fn render_signature_help(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
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
    let rect = geometry::anchored_rect(
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
    .style(theme::overlay())
    .wrap(Wrap { trim: true })
    .render(rect, buffer);
}

fn render_hover_popup(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(hover) = state
        .hover_popup()
        .filter(|hover| hover.visible && !hover.lines.is_empty())
    else {
        return;
    };
    let height = (hover.lines.len() as u16).saturating_add(2).min(8);
    let rect = geometry::anchored_rect(
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
                    theme::semantic(segment.fg, 0, segment.flags as u16),
                )
            })
            .collect::<Vec<_>>();
        Line::from(spans)
    });
    Paragraph::new(lines.collect::<Vec<_>>())
        .block(Block::default().borders(Borders::ALL).title("Hover"))
        .style(theme::overlay())
        .wrap(Wrap { trim: true })
        .render(rect, buffer);
}

fn render_float_popup(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(popup) = state
        .float_popup()
        .filter(|popup| popup.visible && !popup.lines.is_empty())
    else {
        return;
    };
    let width = geometry::bounded_dimension(popup.width, 20, area.width);
    let height = geometry::bounded_dimension(popup.height, 3, area.height);
    let rect = geometry::centered_rect(area, width, height);
    Clear.render(rect, buffer);
    Paragraph::new(popup.lines.join("\n"))
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(popup.title.as_str()),
        )
        .style(theme::overlay())
        .wrap(Wrap { trim: false })
        .render(rect, buffer);
}

fn render_change_summary(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
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
            theme::selected(Color::Green)
        } else {
            theme::overlay()
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

fn render_which_key(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
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
                Span::styled(format!("{} ", binding.key), theme::binding_key()),
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
        .style(theme::overlay())
        .render(rect, buffer);
}

fn render_picker(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(picker) = state.picker().filter(|picker| picker.visible) else {
        return;
    };
    let width = area.width.saturating_mul(3) / 4;
    let height = area.height.saturating_mul(3) / 4;
    let rect = geometry::centered_rect(
        area,
        width.max(30).min(area.width),
        height.max(8).min(area.height),
    );
    Clear.render(rect, buffer);
    let chunks = if picker.has_preview
        && layout::visible_picker_preview(state).is_some()
        && rect.width >= 60
    {
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
    render_picker_list(picker, chunks[0], buffer);
    if chunks.len() > 1
        && let Some(preview) = layout::visible_picker_preview(state)
    {
        render_picker_preview(preview, chunks[1], buffer);
    }
}

fn render_picker_list(picker: &semantic::Picker, area: Rect, buffer: &mut Buffer) {
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
                theme::selected(Color::Cyan)
            } else {
                theme::overlay()
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

fn render_picker_preview(preview: &semantic::PickerPreview, area: Rect, buffer: &mut Buffer) {
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
                        style = style.fg(theme::rgb(segment.fg));
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
        .style(theme::overlay())
        .wrap(Wrap { trim: false })
        .render(area, buffer);
}
