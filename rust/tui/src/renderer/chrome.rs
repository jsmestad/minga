use super::components;
use super::layout;
use super::theme;
use super::theme::Palette;
use crate::semantic;
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget};

pub fn render(state: &SemanticState, frame: &layout::FrameLayout, buffer: &mut Buffer) {
    let palette = Palette::new(state.theme());

    if let Some(workspaces) = layout::visible_workspaces(state) {
        render_workspace_bar(workspaces, &palette, frame.workspace_bar, buffer);
    }

    if let Some(tab_bar) = state.tab_bar() {
        Paragraph::new(components::tab_strip(&tab_bar.tabs, &palette))
            .render(frame.tab_bar, buffer);
    }

    if let Some(breadcrumb) = layout::visible_breadcrumb(state) {
        render_breadcrumb(breadcrumb, state, &palette, frame.breadcrumb, buffer);
    }

    if let Some(status_bar) = state.status_bar() {
        render_status_bar(state, status_bar, &palette, frame.status_bar, buffer);
    }

    if let Some(minibuffer) = layout::visible_minibuffer(state) {
        render_minibuffer(minibuffer, &palette, frame.minibuffer, buffer);
    }
}

fn render_workspace_bar(
    workspaces: &semantic::Workspaces,
    palette: &Palette<'_>,
    area: Rect,
    buffer: &mut Buffer,
) {
    let text = workspace_bar_text(workspaces);
    components::full_width_bar(&text, area, palette.editor_surface(), buffer);
}

fn workspace_bar_text(workspaces: &semantic::Workspaces) -> String {
    let Some(active) = workspaces
        .spaces
        .iter()
        .find(|workspace| workspace.id == workspaces.active_workspace_id)
        .or_else(|| workspaces.spaces.first())
    else {
        return format!(
            "Spaces  {}/{}",
            workspaces.active_workspace_id, workspaces.workspace_count
        );
    };

    let mut label = String::from("Spaces · ");
    if active.id == workspaces.active_workspace_id {
        label.push('▎');
    }
    if !active.icon.is_empty() {
        label.push_str(&active.icon);
        label.push(' ');
    }
    label.push_str(active.label.trim());

    let mut metadata = Vec::new();
    if active.tab_count > 0 {
        metadata.push(plural_count(active.tab_count, "tab"));
    }
    if active.draft_count > 0 {
        metadata.push(plural_count(active.draft_count, "draft"));
    }
    if active.conflict_count > 0 {
        metadata.push(plural_count(active.conflict_count, "conflict"));
    }
    if active.background_count > 0 {
        metadata.push(format!("{} running", active.background_count));
    }
    if !metadata.is_empty() {
        label.push_str(" (");
        label.push_str(&metadata.join(", "));
        label.push(')');
    }
    if active.flags & 0x01 != 0 {
        label.push_str(" !");
    }
    label
}

fn plural_count(count: u16, label: &str) -> String {
    if count == 1 {
        format!("1 {label}")
    } else {
        format!("{count} {label}s")
    }
}

fn render_status_bar(
    state: &SemanticState,
    status_bar: &semantic::StatusBar,
    palette: &Palette<'_>,
    area: Rect,
    buffer: &mut Buffer,
) {
    if !status_bar.left_segments.is_empty() || !status_bar.right_segments.is_empty() {
        render_segmented_status_bar(status_bar, palette, area, buffer);
    } else {
        render_fallback_status_bar(state, status_bar, palette, area, buffer);
    }
}

fn render_segmented_status_bar(
    status_bar: &semantic::StatusBar,
    palette: &Palette<'_>,
    area: Rect,
    buffer: &mut Buffer,
) {
    let base = palette.status_bar();
    let left_spans: Vec<Span<'_>> = status_bar
        .left_segments
        .iter()
        .map(|s| status_segment_span(s, palette))
        .collect();
    let right_spans: Vec<Span<'_>> = status_bar
        .right_segments
        .iter()
        .map(|s| status_segment_span(s, palette))
        .collect();
    let left_width: usize = left_spans.iter().map(|s| s.content.len()).sum();
    let right_width: usize = right_spans.iter().map(|s| s.content.len()).sum();
    let available = (area.width as usize).saturating_sub(left_width + right_width);

    let mut spans = left_spans;

    if !status_bar.message.is_empty() {
        let msg = &status_bar.message;
        let msg_width = msg.len().min(available);
        let left_pad = available.saturating_sub(msg_width) / 2;
        let right_pad = available.saturating_sub(msg_width).saturating_sub(left_pad);
        spans.push(Span::styled(" ".repeat(left_pad), base));
        spans.push(Span::styled(
            msg[..msg_width].to_owned(),
            base.fg(palette.warning()).add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::styled(" ".repeat(right_pad), base));
    } else {
        spans.push(Span::styled(" ".repeat(available), base));
    }

    spans.extend(right_spans);
    Paragraph::new(Line::from(spans)).render(area, buffer);
}

fn render_fallback_status_bar(
    state: &SemanticState,
    status_bar: &semantic::StatusBar,
    palette: &Palette<'_>,
    area: Rect,
    buffer: &mut Buffer,
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
    let left_spans = vec![Span::styled(left, palette.status_bar())];
    let right_spans = vec![Span::styled(
        status_right_text(state, status_bar),
        palette.status_bar(),
    )];
    components::styled_bar(left_spans, right_spans, area, palette.status_bar(), buffer);
}

fn status_segment_span<'a>(
    segment: &'a semantic::StatusSegment,
    palette: &Palette<'_>,
) -> Span<'a> {
    let mut style = palette.status_bar();
    if segment.fg != 0 {
        style = style.fg(theme::rgb(segment.fg));
    }
    if segment.bg != 0 {
        style = style.bg(theme::rgb(segment.bg));
    }
    if segment.attrs & 0x01 != 0 {
        style = style.add_modifier(Modifier::BOLD);
    }
    if segment.attrs & 0x02 != 0 {
        style = style.add_modifier(Modifier::UNDERLINED);
    }
    if segment.attrs & 0x04 != 0 {
        style = style.add_modifier(Modifier::ITALIC);
    }
    Span::styled(segment.text.clone(), style)
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

    if let Some(notifications) = state
        .notifications()
        .filter(|notifications| notifications.visible != 0 && notifications.notification_count > 0)
    {
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
        .filter(|sidebars| sidebars.visible != 0 && sidebars.visible_count() > 0)
    {
        parts.push(format!("sidebars {}", sidebars.visible_count()));
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
        .filter(|agent_chat| agent_chat.visible != 0)
    {
        parts.push(format!(
            "chat {}",
            agent_chat_status_label(agent_chat.status)
        ));
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

fn agent_chat_status_label(status: u8) -> &'static str {
    match status {
        1 => "thinking",
        2 => "tools",
        3 => "error",
        _ => "idle",
    }
}

fn render_breadcrumb(
    breadcrumb: &semantic::Breadcrumb,
    state: &SemanticState,
    palette: &Palette<'_>,
    area: Rect,
    buffer: &mut Buffer,
) {
    let separator = Span::styled(
        " › ",
        Style::default()
            .fg(palette.gutter_fg())
            .bg(palette.editor_bg()),
    );
    let mut spans: Vec<Span<'_>> = Vec::new();
    spans.push(Span::styled("  ", palette.editor_surface()));
    for (index, segment) in breadcrumb.segments.iter().enumerate() {
        if index > 0 {
            spans.push(separator.clone());
        }
        let style = if index == breadcrumb.segments.len() - 1 {
            Style::default()
                .fg(palette.editor_text())
                .bg(palette.editor_bg())
        } else {
            palette.muted()
        };
        spans.push(Span::styled(segment.clone(), style));
    }
    if let Some(git_status) = state.git_status().filter(|git| !git.branch.is_empty()) {
        let git_text = format!("  ·  {}", git_status.branch);
        spans.push(Span::styled(git_text, palette.muted()));
    }
    let left = spans;
    components::styled_bar(left, Vec::new(), area, palette.editor_surface(), buffer);
}

fn render_minibuffer(
    minibuffer: &semantic::Minibuffer,
    palette: &Palette<'_>,
    area: Rect,
    buffer: &mut Buffer,
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
        .style(palette.minibuffer())
        .render(area, buffer);
}
