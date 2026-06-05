use super::components;
use super::geometry;
use super::layout;
use super::theme;
use super::theme::Palette;
use crate::semantic;
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph, Widget, Wrap};

pub fn render(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    render_completion(state, area, buffer);
    render_signature_help(state, area, buffer);
    render_hover_popup(state, area, buffer);
    render_float_popup(state, area, buffer);
    render_change_summary(state, area, buffer);
    render_agent_context(state, area, buffer);
    render_agent_chat(state, area, buffer);
    render_tool_manager(state, area, buffer);
    render_board(state, area, buffer);
    render_notifications(state, area, buffer);
    render_edit_timeline(state, area, buffer);
    render_observatory(state, area, buffer);
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
    let palette = Palette::new(state.theme());
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
    let lines = completion
        .items
        .iter()
        .enumerate()
        .map(|(index, item)| {
            components::list_item_line(
                format!("{}  {}", item.label, item.detail),
                index == completion.selected_index as usize,
                &palette,
            )
        })
        .collect();
    components::popup_frame("Complete", lines, rect, &palette, buffer);
}

fn render_signature_help(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(help) = state
        .signature_help()
        .filter(|help| help.visible && !help.signatures.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
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
    let lines = vec![
        Line::styled(
            signature.label.clone(),
            Style::default().fg(palette.accent()),
        ),
        Line::from(signature.documentation.clone()),
    ];
    components::popup_frame_wrapped("Signature", lines, rect, &palette, buffer);
}

fn render_hover_popup(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(hover) = state
        .hover_popup()
        .filter(|hover| hover.visible && !hover.lines.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let height = (hover.lines.len() as u16).saturating_add(2).min(8);
    let rect = geometry::anchored_rect(
        area,
        hover.anchor_col,
        hover.anchor_row.saturating_add(1),
        area.width.min(52),
        height,
    );
    let lines = hover
        .lines
        .iter()
        .map(|line| {
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
        })
        .collect();
    components::popup_frame_wrapped("Hover", lines, rect, &palette, buffer);
}

fn render_float_popup(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(popup) = state
        .float_popup()
        .filter(|popup| popup.visible && !popup.lines.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let width = geometry::bounded_dimension(popup.width, 20, area.width);
    let height = geometry::bounded_dimension(popup.height, 3, area.height);
    let rect = geometry::centered_rect(area, width, height);
    Clear.render(rect, buffer);
    let border_style = Style::default().fg(palette.popup_border());
    Paragraph::new(popup.lines.join("\n"))
        .block(
            ratatui::widgets::Block::default()
                .borders(ratatui::widgets::Borders::ALL)
                .border_style(border_style)
                .title(popup.title.as_str()),
        )
        .style(palette.overlay())
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
    let palette = Palette::new(state.theme());
    let rect = Rect {
        x: area
            .x
            .saturating_add(area.width.saturating_sub(area.width.min(44))),
        y: area.y,
        width: area.width.min(44),
        height: area.height.min(12),
    };
    let lines = summary
        .entries
        .iter()
        .enumerate()
        .map(|(index, entry)| {
            components::list_item_line(
                format!(
                    "{} +{} -{}",
                    entry.path, entry.lines_added, entry.lines_removed
                ),
                index == summary.selected_index as usize,
                &palette,
            )
        })
        .collect();
    components::popup_frame("Changes", lines, rect, &palette, buffer);
}

fn render_agent_context(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(context) = state
        .agent_context()
        .filter(|ctx| ctx.visible != 0 && !ctx.task.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let status_label = match context.status {
        1 => "thinking",
        2 => "tools",
        3 => "error",
        _ => "idle",
    };
    let mut lines = vec![
        components::list_item_line(
            format!("{}  {}", status_label, context.task),
            false,
            &palette,
        ),
    ];
    if context.can_approve != 0 {
        lines.push(components::list_item_line(
            "approval  approve or request changes",
            false,
            &palette,
        ));
    }
    let height = (lines.len() as u16).saturating_add(2).min(6);
    let width = area.width.min(60);
    let rect = geometry::centered_rect(area, width, height);
    components::popup_frame("Agent context", lines, rect, &palette, buffer);
}

fn render_tool_manager(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(tools) = state
        .tool_manager()
        .filter(|t| t.visible != 0 && !t.tools.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let lines = tools
        .tools
        .iter()
        .enumerate()
        .map(|(index, tool)| {
            let status = match tool.status {
                1 => "installed",
                2 => "installing",
                3 => "update available",
                4 => "failed",
                _ => "not installed",
            };
            components::list_item_line(
                format!("{}  {} {}", tool.label, tool.name, status),
                index == tools.selected as usize,
                &palette,
            )
        })
        .collect();
    let height = (tools.tools.len() as u16).saturating_add(2).min(area.height);
    let rect = geometry::centered_rect(area, area.width.min(60), height);
    components::popup_frame("Tool manager", lines, rect, &palette, buffer);
}

fn render_board(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(board) = state
        .board()
        .filter(|b| b.visible != 0 && !b.cards.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let lines = board
        .cards
        .iter()
        .map(|card| {
            let marker = if card.id == board.focused_card_id || card.flags & 0x02 != 0 {
                ">"
            } else {
                " "
            };
            let status = status_name(card.status);
            components::list_item_line(
                format!("{marker} {status}  {}", card.task),
                card.id == board.focused_card_id,
                &palette,
            )
        })
        .collect();
    let title = format!("Board  {} cards", board.cards.len());
    let height = (board.cards.len() as u16).saturating_add(2).min(area.height);
    let rect = geometry::centered_rect(area, area.width.min(70), height);
    components::popup_frame(&title, lines, rect, &palette, buffer);
}

fn render_notifications(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(notes) = state
        .notifications()
        .filter(|n| n.visible != 0 && !n.items.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let lines = notes
        .items
        .iter()
        .map(|note| {
            let desc = if note.source.is_empty() {
                note.body.clone()
            } else {
                format!("{} {}", note.source, note.body)
            };
            components::list_item_line(
                format!("{}  {}", note.title, desc.trim()),
                false,
                &palette,
            )
        })
        .collect();
    let height = (notes.items.len() as u16).saturating_add(2).min(area.height);
    let rect = geometry::centered_rect(area, area.width.min(60), height);
    components::popup_frame("Notifications", lines, rect, &palette, buffer);
}

fn render_edit_timeline(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(timeline) = state
        .edit_timeline()
        .filter(|t| t.visible != 0 && !t.entries.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let lines = timeline
        .entries
        .iter()
        .map(|entry| {
            let selected = entry.index as u16 == timeline.viewing_index;
            components::list_item_line(
                format!("{}  {}  {}s", entry.index, entry.tool_name, entry.timestamp_delta),
                selected,
                &palette,
            )
        })
        .collect();
    let height = (timeline.entries.len() as u16).saturating_add(2).min(area.height);
    let rect = geometry::centered_rect(area, area.width.min(50), height);
    components::popup_frame("Edit timeline", lines, rect, &palette, buffer);
}

fn render_observatory(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(obs) = state
        .observatory()
        .filter(|o| o.visible && !o.nodes.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let lines = obs
        .nodes
        .iter()
        .map(|node| {
            let indent = "  ".repeat(node.depth as usize);
            components::list_item_line(
                format!("{}  {indent}{}  Q:{}", node.pid, node.name, node.message_queue_len),
                false,
                &palette,
            )
        })
        .collect();
    let title = format!("Observatory  {} processes", obs.count.max(obs.nodes.len() as u16));
    let height = (obs.nodes.len() as u16).saturating_add(2).min(area.height);
    let rect = geometry::centered_rect(area, area.width.min(70), height);
    components::popup_frame(&title, lines, rect, &palette, buffer);
}

fn render_agent_chat(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(chat) = state
        .agent_chat()
        .filter(|c| c.visible != 0)
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let width = area.width.saturating_mul(3) / 4;
    let height = area.height.saturating_mul(3) / 4;
    let rect = geometry::centered_rect(
        area,
        width.max(40).min(area.width),
        height.max(8).min(area.height),
    );
    Clear.render(rect, buffer);

    let inner_height = rect.height.saturating_sub(2) as usize;
    let mut lines: Vec<Line<'_>> = Vec::new();

    let header = format!(
        "{}  {}",
        if chat.model_name.is_empty() { "Agent" } else { &chat.model_name },
        status_name(chat.status),
    );
    lines.push(Line::styled(
        header,
        Style::default().fg(palette.accent()).add_modifier(Modifier::BOLD),
    ));

    if !chat.pending.is_empty() {
        lines.push(Line::styled(
            format!("  pending: {}", chat.pending),
            palette.muted(),
        ));
    }

    let msg_budget = inner_height.saturating_sub(lines.len()).saturating_sub(if chat.prompt.is_empty() { 0 } else { 2 });
    let visible_messages = if chat.messages.len() > msg_budget {
        &chat.messages[chat.messages.len() - msg_budget..]
    } else {
        &chat.messages
    };

    for msg in visible_messages {
        let (role, role_style) = match msg.kind {
            0x01 => ("system", palette.muted()),
            0x02 => ("user", Style::default().fg(palette.accent())),
            0x03 => ("assistant", palette.overlay()),
            0x04 | 0x08 => {
                let tool_style = if msg.is_error {
                    Style::default().fg(palette.diagnostic_fg(0))
                } else if msg.status == 1 {
                    Style::default().fg(palette.accent())
                } else {
                    palette.muted()
                };
                ("tool", tool_style)
            }
            0x05 => ("result", palette.muted()),
            0x06 => ("usage", palette.muted()),
            0x09 => ("approval", Style::default().fg(palette.warning())),
            _ => ("msg", palette.overlay()),
        };

        let content = if msg.text.len() > rect.width as usize * 2 {
            format!("{}...", &msg.text[..rect.width as usize * 2])
        } else {
            msg.text.clone()
        };

        let first_line = content.lines().next().unwrap_or("");
        let display = if msg.collapsed && !first_line.is_empty() {
            format!("  [{role}] {first_line} (collapsed)")
        } else {
            format!("  [{role}] {first_line}")
        };

        lines.push(Line::styled(display, role_style));
    }

    if !chat.prompt.is_empty() {
        lines.push(Line::from(""));
        lines.push(Line::styled(
            format!("> {}", chat.prompt),
            Style::default().fg(palette.editor_text()),
        ));
    }

    lines.truncate(inner_height);
    components::popup_frame("Agent chat", lines, rect, &palette, buffer);
}

fn status_name(status: u8) -> &'static str {
    match status {
        1 => "thinking",
        2 => "tools",
        3 => "error",
        _ => "idle",
    }
}

fn render_which_key(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(which_key) = state
        .which_key()
        .filter(|which_key| which_key.visible && !which_key.bindings.is_empty())
    else {
        return;
    };
    let palette = Palette::new(state.theme());
    let popup_width = if area.width <= 24 {
        area.width.max(1)
    } else {
        (area.width * 2 / 3).max(42).min(area.width.saturating_sub(4))
    };
    let inner_width = popup_width.saturating_sub(2).max(1);
    let columns = match inner_width {
        w if w >= 96 => 4,
        w if w >= 64 => 3,
        w if w >= 36 => 2,
        _ => 1,
    } as usize;
    let rows = (which_key.bindings.len() + columns - 1) / columns;
    let cell_width = (inner_width as usize / columns).max(1);
    let height = (rows as u16)
        .saturating_add(2)
        .min(area.height.min(14));
    let rect = Rect {
        x: area.x.saturating_add(2),
        y: area.y.saturating_add(area.height.saturating_sub(height).saturating_sub(2)),
        width: popup_width,
        height,
    };
    let mut lines: Vec<Line<'_>> = Vec::with_capacity(rows);
    for row in 0..rows {
        if lines.len() >= height.saturating_sub(2) as usize {
            break;
        }
        let mut spans = Vec::new();
        for col in 0..columns {
            let index = row * columns + col;
            if index >= which_key.bindings.len() {
                break;
            }
            let binding = &which_key.bindings[index];
            let key = binding.key.trim();
            spans.push(Span::styled(
                format!(" {key} "),
                palette.popup_selection().add_modifier(Modifier::BOLD),
            ));
            let desc_width = cell_width.saturating_sub(key.len() + 4);
            let desc = if binding.description.len() > desc_width {
                format!(" {}… ", &binding.description[..desc_width.saturating_sub(2)])
            } else {
                format!(" {:<width$}", binding.description, width = desc_width)
            };
            spans.push(Span::styled(desc, palette.overlay()));
        }
        lines.push(Line::from(spans));
    }
    let title = if which_key.page_count > 1 {
        format!(
            "Keys {} {}/{}",
            which_key.prefix,
            which_key.page.saturating_add(1),
            which_key.page_count.max(1)
        )
    } else if which_key.prefix.is_empty() {
        "Keys".to_owned()
    } else {
        format!("Keys {}", which_key.prefix)
    };
    components::popup_frame(&title, lines, rect, &palette, buffer);
}

fn render_picker(state: &SemanticState, area: Rect, buffer: &mut Buffer) {
    let Some(picker) = state.picker().filter(|picker| picker.visible) else {
        return;
    };
    let palette = Palette::new(state.theme());
    let popup_width = if area.width <= 24 {
        area.width.max(1)
    } else if area.width >= 120 {
        (area.width - 8).min(120)
    } else {
        (area.width - 4).min(48.max(area.width * 9 / 10))
    };
    let height = area.height.saturating_mul(3) / 4;
    let rect = geometry::centered_rect(
        area,
        popup_width.max(30).min(area.width),
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
    render_picker_list(picker, &palette, chunks[0], buffer);
    if chunks.len() > 1
        && let Some(preview) = layout::visible_picker_preview(state)
    {
        render_picker_preview(preview, &palette, chunks[1], buffer);
    }
}

fn render_picker_list(
    picker: &semantic::Picker,
    palette: &Palette<'_>,
    area: Rect,
    buffer: &mut Buffer,
) {
    let mut title = picker.title.clone();
    if !picker.query.is_empty() {
        title.push_str("  ");
        title.push_str(&picker.query);
    }
    if picker.marked_count > 0 {
        title.push_str(&format!("  marked {}", picker.marked_count));
    }
    match picker.load_status {
        1 => title.push_str("  loading"),
        2 => title.push_str("  error"),
        _ => {}
    }

    let row_budget = area.height.saturating_sub(3) as usize;
    let selected = (picker.selected_index as usize).min(picker.items.len().saturating_sub(1));
    let start = if selected >= row_budget && row_budget > 0 {
        selected - row_budget + 1
    } else {
        0
    };
    let end = (start + row_budget).min(picker.items.len());

    let mut lines: Vec<Line<'_>> = Vec::with_capacity(row_budget + 1);
    for index in start..end {
        let item = &picker.items[index];
        let is_selected = index == selected;
        let marker = if is_selected {
            "▌"
        } else if item.marked {
            "*"
        } else {
            " "
        };
        let marker_style = if is_selected {
            Style::default().fg(palette.accent()).add_modifier(Modifier::BOLD)
        } else if item.marked {
            Style::default().fg(palette.warning())
        } else {
            palette.overlay()
        };
        let label_style = if is_selected {
            palette.popup_selection().add_modifier(Modifier::BOLD)
        } else {
            palette.overlay()
        };
        let detail = if !item.description.is_empty() {
            item.description.as_str()
        } else if !item.annotation.is_empty() {
            item.annotation.as_str()
        } else {
            ""
        };
        let mut spans = vec![
            Span::styled(format!("{marker} "), marker_style),
            Span::styled(item.label.clone(), label_style),
        ];
        if !detail.trim().is_empty() {
            spans.push(Span::styled(
                format!("  {}", detail.trim()),
                palette.muted(),
            ));
        }
        lines.push(Line::from(spans));
    }

    let help = picker_help_line(picker, area.width as usize, palette);
    let mut all_lines = lines;
    all_lines.push(help);

    components::popup_frame(&title, all_lines, area, palette, buffer);
}

fn picker_help_line<'a>(
    picker: &semantic::Picker,
    width: usize,
    palette: &Palette<'_>,
) -> Line<'a> {
    let selected_display = if picker.items.is_empty() {
        0
    } else {
        (picker.selected_index as usize + 1).min(picker.items.len())
    };
    let left = format!(" {selected_display}/{}", picker.items.len());
    let right = "↑↓ move  Enter choose  Esc close";
    let spacer_width = width.saturating_sub(left.len() + right.len() + 2);
    let muted = palette.muted();
    Line::from(vec![
        Span::styled(left, muted),
        Span::styled(" ".repeat(spacer_width), muted),
        Span::styled(right.to_owned(), muted),
    ])
}

fn render_picker_preview(
    preview: &semantic::PickerPreview,
    palette: &Palette<'_>,
    area: Rect,
    buffer: &mut Buffer,
) {
    let lines = preview
        .lines
        .iter()
        .take(area.height.saturating_sub(2) as usize)
        .map(|line| {
            let spans = line
                .iter()
                .map(|segment| {
                    let mut style = palette.overlay();
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
        })
        .collect();
    components::popup_frame_wrapped("Preview", lines, area, palette, buffer);
}
