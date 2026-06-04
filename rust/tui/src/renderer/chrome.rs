use super::layout;
use super::theme;
use crate::semantic;
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget};
use unicode_width::UnicodeWidthStr;

pub fn render(state: &SemanticState, frame: &layout::FrameLayout, buffer: &mut Buffer) {
    if let Some(workspaces) = layout::visible_workspaces(state) {
        render_workspace_bar(workspaces, state.theme(), frame.workspace_bar, buffer);
    }

    if let Some(tab_bar) = state.tab_bar() {
        render_tab_bar(tab_bar, state.theme(), frame.tab_bar, buffer);
    }

    if let Some(status_bar) = state.status_bar() {
        render_status_bar(state, status_bar, frame.status_bar, buffer);
    }

    if let Some(minibuffer) = layout::visible_minibuffer(state) {
        render_minibuffer(minibuffer, state.theme(), frame.minibuffer, buffer);
    }
}

fn render_workspace_bar(
    workspaces: &semantic::Workspaces,
    theme_state: Option<&semantic::Theme>,
    area: Rect,
    buffer: &mut Buffer,
) {
    let text = workspace_bar_text(workspaces);
    Paragraph::new(Line::from(vec![Span::styled(
        pad_to_width(&text, area.width as usize),
        theme::canvas(theme_state),
    )]))
    .render(area, buffer);
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

fn render_tab_bar(
    tab_bar: &semantic::TabBar,
    theme_state: Option<&semantic::Theme>,
    area: Rect,
    buffer: &mut Buffer,
) {
    let spans: Vec<Span<'_>> = tab_bar
        .tabs
        .iter()
        .map(|tab| {
            let label = if tab.dirty {
                format!(" {} * ", tab.label)
            } else {
                format!(" {} ", tab.label)
            };
            Span::styled(label, theme::tab(theme_state, tab.active))
        })
        .collect();
    Paragraph::new(Line::from(spans)).render(area, buffer);
}

fn render_status_bar(
    state: &SemanticState,
    status_bar: &semantic::StatusBar,
    area: Rect,
    buffer: &mut Buffer,
) {
    let left_spans = status_left_spans(state, status_bar);
    let left_width = line_width(&left_spans);
    let right_spans = status_right_spans(state, status_bar);
    let right_width = line_width(&right_spans);
    let width = area.width as usize;
    let padding = width.saturating_sub(left_width.saturating_add(right_width));
    let mut spans = left_spans;
    spans.push(Span::styled(
        " ".repeat(padding),
        theme::status_bar(state.theme()),
    ));
    spans.extend(right_spans);
    Paragraph::new(Line::from(spans)).render(area, buffer);
}

fn status_left_spans<'a>(
    state: &SemanticState,
    status_bar: &'a semantic::StatusBar,
) -> Vec<Span<'a>> {
    if !status_bar.left_segments.is_empty() || !status_bar.right_segments.is_empty() {
        return status_bar
            .left_segments
            .iter()
            .map(status_segment_span)
            .collect();
    }

    let mut left = if status_bar.filename.is_empty() {
        status_bar.message.clone()
    } else {
        status_bar.filename.clone()
    };
    if !status_bar.branch.is_empty() {
        left.push_str("  ");
        left.push_str(&status_bar.branch);
    }
    vec![Span::styled(left, theme::status_bar(state.theme()))]
}

fn status_right_spans<'a>(
    state: &SemanticState,
    status_bar: &'a semantic::StatusBar,
) -> Vec<Span<'a>> {
    if !status_bar.right_segments.is_empty() {
        return status_bar
            .right_segments
            .iter()
            .map(status_segment_span)
            .collect();
    }

    vec![Span::styled(
        status_right_text(state, status_bar),
        theme::status_bar(state.theme()),
    )]
}

fn status_segment_span(segment: &semantic::StatusSegment) -> Span<'_> {
    Span::styled(
        segment.text.clone(),
        theme::semantic(segment.fg, segment.bg, segment.attrs),
    )
}

fn line_width(spans: &[Span<'_>]) -> usize {
    spans.iter().map(|span| span.content.as_ref().width()).sum()
}

fn pad_to_width(text: &str, width: usize) -> String {
    let text_width = text.width();
    if text_width >= width {
        text.to_owned()
    } else {
        format!("{}{}", text, " ".repeat(width - text_width))
    }
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

fn render_minibuffer(
    minibuffer: &semantic::Minibuffer,
    theme_state: Option<&semantic::Theme>,
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
        .style(theme::minibuffer(theme_state))
        .render(area, buffer);
}
