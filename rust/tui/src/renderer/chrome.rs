use super::layout;
use super::theme;
use crate::semantic;
use crate::semantic_state::SemanticState;
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget};

pub fn render(state: &SemanticState, frame: &layout::FrameLayout, buffer: &mut Buffer) {
    if let Some(tab_bar) = state.tab_bar() {
        render_tab_bar(tab_bar, frame.tab_bar, buffer);
    }

    if let Some(status_bar) = state.status_bar() {
        render_status_bar(state, status_bar, frame.status_bar, buffer);
    }

    if let Some(minibuffer) = layout::visible_minibuffer(state) {
        render_minibuffer(minibuffer, frame.minibuffer, buffer);
    }
}

fn render_tab_bar(tab_bar: &semantic::TabBar, area: Rect, buffer: &mut Buffer) {
    let spans: Vec<Span<'_>> = tab_bar
        .tabs
        .iter()
        .map(|tab| {
            let label = if tab.dirty {
                format!(" {} * ", tab.label)
            } else {
                format!(" {} ", tab.label)
            };
            Span::styled(label, theme::tab(tab.active))
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
    let mut left = if status_bar.filename.is_empty() {
        status_bar.message.clone()
    } else {
        status_bar.filename.clone()
    };
    if !status_bar.branch.is_empty() {
        left.push_str("  ");
        left.push_str(&status_bar.branch);
    }
    let right = status_right_text(state, status_bar);
    let width = area.width as usize;
    let padding = width.saturating_sub(left.len().saturating_add(right.len()));
    let text = format!("{left}{}{right}", " ".repeat(padding));
    Paragraph::new(text)
        .style(theme::status_bar())
        .render(area, buffer);
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
        .filter(|sidebars| sidebars.visible != 0 && sidebars.sidebar_count > 0)
    {
        parts.push(format!("sidebars {}", sidebars.sidebar_count));
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
        .filter(|agent_chat| agent_chat.visible != 0 && agent_chat.message_count > 0)
    {
        parts.push(format!("chat {}", agent_chat.message_count));
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

fn render_minibuffer(minibuffer: &semantic::Minibuffer, area: Rect, buffer: &mut Buffer) {
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
        .style(theme::minibuffer())
        .render(area, buffer);
}
