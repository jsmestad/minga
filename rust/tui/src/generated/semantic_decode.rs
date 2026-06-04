// Generated semantic decode functions.
//
// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.

use crate::protocol::DecodeError;
use super::semantic_types::*;

fn require_len(bytes: &[u8], needed: usize, label: &'static str) -> Result<(), DecodeError> {
    if bytes.len() < needed {
        Err(DecodeError::Malformed(label))
    } else {
        Ok(())
    }
}

fn read_u16(bytes: &[u8], offset: usize) -> u16 {
    u16::from_be_bytes([bytes[offset], bytes[offset + 1]])
}

fn read_u24(bytes: &[u8], offset: usize) -> u32 {
    ((bytes[offset] as u32) << 16) | ((bytes[offset + 1] as u32) << 8) | bytes[offset + 2] as u32
}

fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]])
}

fn read_u64(bytes: &[u8], offset: usize) -> u64 {
    u64::from_be_bytes([
        bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3],
        bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
    ])
}

fn read_string(bytes: &[u8], offset: usize, len: usize) -> Result<String, DecodeError> {
    require_len(bytes, offset + len, "string body")?;
    std::str::from_utf8(&bytes[offset..offset + len])
        .map(str::to_owned)
        .map_err(|_| DecodeError::Utf8)
}

fn read_string8(bytes: &[u8], offset: &mut usize) -> Result<String, DecodeError> {
    require_len(bytes, *offset + 1, "string8 header")?;
    let len = bytes[*offset] as usize;
    *offset += 1;
    let value = read_string(bytes, *offset, len)?;
    *offset += len;
    Ok(value)
}

fn read_string16(bytes: &[u8], offset: &mut usize) -> Result<String, DecodeError> {
    require_len(bytes, *offset + 2, "string16 header")?;
    let len = read_u16(bytes, *offset) as usize;
    *offset += 2;
    let value = read_string(bytes, *offset, len)?;
    *offset += len;
    Ok(value)
}

fn read_string32(bytes: &[u8], offset: &mut usize) -> Result<String, DecodeError> {
    require_len(bytes, *offset + 4, "string32 header")?;
    let len = read_u32(bytes, *offset) as usize;
    *offset += 4;
    let value = read_string(bytes, *offset, len)?;
    *offset += len;
    Ok(value)
}

pub fn decode_rect(bytes: &[u8], offset: usize) -> Result<(Rect, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "row")?;
    let row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "col")?;
    let col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "width")?;
    let width = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "height")?;
    let height = read_u16(bytes, pos);
    pos += 2;
    Ok((Rect {
        row,
        col,
        width,
        height,
    }, pos - offset))
}

pub fn decode_span(bytes: &[u8], offset: usize) -> Result<(Span, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "start_col")?;
    let start_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "end_col")?;
    let end_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 3, "fg")?;
    let fg = read_u24(bytes, pos);
    pos += 3;
    require_len(bytes, pos + 3, "bg")?;
    let bg = read_u24(bytes, pos);
    pos += 3;
    require_len(bytes, pos + 1, "attrs")?;
    let attrs = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "font_weight")?;
    let font_weight = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "font_id")?;
    let font_id = bytes[pos];
    pos += 1;
    Ok((Span {
        start_col,
        end_col,
        fg,
        bg,
        attrs,
        font_weight,
        font_id,
    }, pos - offset))
}

pub fn decode_row(bytes: &[u8], offset: usize) -> Result<(Row, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "row_type")?;
    let row_type = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 8, "row_id")?;
    let row_id = read_u64(bytes, pos);
    pos += 8;
    require_len(bytes, pos + 4, "buf_line")?;
    let buf_line = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 4, "content_hash")?;
    let content_hash = read_u32(bytes, pos);
    pos += 4;
    let text = read_string32(bytes, &mut pos)?;
    require_len(bytes, pos + 2, "spans count")?;
    let spans_count = read_u16(bytes, pos) as usize;
    pos += 2;
    require_len(bytes, pos + spans_count * 13, "spans")?;
    let mut spans = Vec::with_capacity(spans_count);
    for _ in 0..spans_count {
        let (item, consumed) = decode_span(bytes, pos)?;
        pos += consumed;
        spans.push(item);
    }
    Ok((Row {
        row_type,
        row_id,
        buf_line,
        content_hash,
        text,
        spans,
    }, pos - offset))
}

pub fn decode_search_match(bytes: &[u8], offset: usize) -> Result<(SearchMatch, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "row")?;
    let row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "start_col")?;
    let start_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "end_col")?;
    let end_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "is_current")?;
    let is_current = bytes[pos];
    pos += 1;
    Ok((SearchMatch {
        row,
        start_col,
        end_col,
        is_current,
    }, pos - offset))
}

pub fn decode_diagnostic_range(bytes: &[u8], offset: usize) -> Result<(DiagnosticRange, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "start_row")?;
    let start_row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "start_col")?;
    let start_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "end_row")?;
    let end_row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "end_col")?;
    let end_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "severity")?;
    let severity = bytes[pos];
    pos += 1;
    Ok((DiagnosticRange {
        start_row,
        start_col,
        end_row,
        end_col,
        severity,
    }, pos - offset))
}

pub fn decode_document_highlight(bytes: &[u8], offset: usize) -> Result<(DocumentHighlight, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "start_row")?;
    let start_row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "start_col")?;
    let start_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "end_row")?;
    let end_row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "end_col")?;
    let end_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "kind")?;
    let kind = bytes[pos];
    pos += 1;
    Ok((DocumentHighlight {
        start_row,
        start_col,
        end_row,
        end_col,
        kind,
    }, pos - offset))
}

pub fn decode_annotation(bytes: &[u8], offset: usize) -> Result<(Annotation, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "row")?;
    let row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "kind")?;
    let kind = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 3, "fg")?;
    let fg = read_u24(bytes, pos);
    pos += 3;
    require_len(bytes, pos + 3, "bg")?;
    let bg = read_u24(bytes, pos);
    pos += 3;
    let text = read_string16(bytes, &mut pos)?;
    Ok((Annotation {
        row,
        kind,
        fg,
        bg,
        text,
    }, pos - offset))
}

pub fn decode_hit_region(bytes: &[u8], offset: usize) -> Result<(HitRegion, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "kind")?;
    let kind = bytes[pos];
    pos += 1;
    let (rect, consumed) = decode_rect(bytes, pos)?;
    pos += consumed;
    require_len(bytes, pos + 2, "id")?;
    let id = read_u16(bytes, pos);
    pos += 2;
    Ok((HitRegion {
        kind,
        rect,
        id,
    }, pos - offset))
}

pub fn decode_gutter_entry(bytes: &[u8], offset: usize) -> Result<(GutterEntry, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 4, "buf_line")?;
    let buf_line = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 1, "display_type")?;
    let display_type = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "sign_type")?;
    let sign_type = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 4, "fold_end_line")?;
    let fold_end_line = read_u32(bytes, pos);
    pos += 4;
    let mut sign_fg = 0;
    let mut sign_text = String::new();
    if sign_type == 8 {
        require_len(bytes, pos + 3, "sign_fg")?;
        sign_fg = read_u24(bytes, pos);
        pos += 3;
        sign_text = read_string8(bytes, &mut pos)?;
    }
    Ok((GutterEntry {
        buf_line,
        display_type,
        sign_type,
        fold_end_line,
        sign_fg,
        sign_text,
    }, pos - offset))
}

pub fn decode_modeline_segment(bytes: &[u8], offset: usize) -> Result<(ModelineSegment, usize), DecodeError> {
    let mut pos = offset;
    let name = read_string8(bytes, &mut pos)?;
    require_len(bytes, pos + 3, "fg")?;
    let fg = read_u24(bytes, pos);
    pos += 3;
    require_len(bytes, pos + 3, "bg")?;
    let bg = read_u24(bytes, pos);
    pos += 3;
    require_len(bytes, pos + 1, "attrs")?;
    let attrs = bytes[pos];
    pos += 1;
    let text = read_string16(bytes, &mut pos)?;
    let target = read_string16(bytes, &mut pos)?;
    Ok((ModelineSegment {
        name,
        fg,
        bg,
        attrs,
        text,
        target,
    }, pos - offset))
}

pub fn decode_tab_entry(bytes: &[u8], offset: usize) -> Result<(TabEntry, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "flags")?;
    let flags = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 4, "id")?;
    let id = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 2, "workspace_id")?;
    let workspace_id = read_u16(bytes, pos);
    pos += 2;
    let icon = read_string8(bytes, &mut pos)?;
    let label = read_string16(bytes, &mut pos)?;
    require_len(bytes, pos + 4, "tint_color")?;
    let tint_color = read_u32(bytes, pos);
    pos += 4;
    Ok((TabEntry {
        flags,
        id,
        workspace_id,
        icon,
        label,
        tint_color,
    }, pos - offset))
}

pub fn decode_theme_color(bytes: &[u8], offset: usize) -> Result<(ThemeColor, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "slot")?;
    let slot = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 3, "color")?;
    let color = read_u24(bytes, pos);
    pos += 3;
    Ok((ThemeColor {
        slot,
        color,
    }, pos - offset))
}

pub fn decode_completion_item(bytes: &[u8], offset: usize) -> Result<(CompletionItem, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "kind")?;
    let kind = bytes[pos];
    pos += 1;
    let label = read_string16(bytes, &mut pos)?;
    let detail = read_string16(bytes, &mut pos)?;
    Ok((CompletionItem {
        kind,
        label,
        detail,
    }, pos - offset))
}

pub fn decode_picker_item(bytes: &[u8], offset: usize) -> Result<(PickerItem, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 3, "icon_color")?;
    let icon_color = read_u24(bytes, pos);
    pos += 3;
    require_len(bytes, pos + 1, "flags")?;
    let flags = bytes[pos];
    pos += 1;
    let label = read_string16(bytes, &mut pos)?;
    let description = read_string16(bytes, &mut pos)?;
    let annotation = read_string16(bytes, &mut pos)?;
    require_len(bytes, pos + 1, "match_positions count")?;
    let match_positions_count = bytes[pos] as usize;
    pos += 1;
    require_len(bytes, pos + match_positions_count * 2, "match_positions")?;
    let mut match_positions = Vec::with_capacity(match_positions_count);
    for _ in 0..match_positions_count {
        match_positions.push(read_u16(bytes, pos));
        pos += 2;
    }
    Ok((PickerItem {
        icon_color,
        flags,
        label,
        description,
        annotation,
        match_positions,
    }, pos - offset))
}

pub fn decode_which_key_binding(bytes: &[u8], offset: usize) -> Result<(WhichKeyBinding, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "kind")?;
    let kind = bytes[pos];
    pos += 1;
    let key = read_string8(bytes, &mut pos)?;
    let desc = read_string16(bytes, &mut pos)?;
    let icon = read_string8(bytes, &mut pos)?;
    Ok((WhichKeyBinding {
        kind,
        key,
        desc,
        icon,
    }, pos - offset))
}

pub fn decode_change_summary_entry(bytes: &[u8], offset: usize) -> Result<(ChangeSummaryEntry, usize), DecodeError> {
    let mut pos = offset;
    let path = read_string16(bytes, &mut pos)?;
    require_len(bytes, pos + 1, "action")?;
    let action = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 4, "lines_added")?;
    let lines_added = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 4, "lines_removed")?;
    let lines_removed = read_u32(bytes, pos);
    pos += 4;
    Ok((ChangeSummaryEntry {
        path,
        action,
        lines_added,
        lines_removed,
    }, pos - offset))
}

pub fn decode_git_status_entry(bytes: &[u8], offset: usize) -> Result<(GitStatusEntry, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 4, "path_hash")?;
    let path_hash = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 1, "section")?;
    let section = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "status")?;
    let status = bytes[pos];
    pos += 1;
    let path = read_string16(bytes, &mut pos)?;
    Ok((GitStatusEntry {
        path_hash,
        section,
        status,
        path,
    }, pos - offset))
}


// Section decoders for gui_agent_chat

pub fn decode_gui_agent_chat_header(bytes: &[u8], offset: usize) -> Result<(GuiAgentChatHeader, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "status")?;
    let status = bytes[pos];
    pos += 1;
    Ok((GuiAgentChatHeader {
        visible,
        status,
    }, pos - offset))
}

// Section decoders for gui_gutter

pub fn decode_gui_gutter_window(bytes: &[u8], offset: usize) -> Result<(GuiGutterWindow, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "window_id")?;
    let window_id = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "content_row")?;
    let content_row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "content_col")?;
    let content_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "content_height")?;
    let content_height = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "is_active")?;
    let is_active = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "content_width")?;
    let content_width = read_u16(bytes, pos);
    pos += 2;
    Ok((GuiGutterWindow {
        window_id,
        content_row,
        content_col,
        content_height,
        is_active,
        content_width,
    }, pos - offset))
}

pub fn decode_gui_gutter_config(bytes: &[u8], offset: usize) -> Result<(GuiGutterConfig, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 4, "cursor_line")?;
    let cursor_line = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 1, "line_number_style")?;
    let line_number_style = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "line_number_width")?;
    let line_number_width = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "sign_col_width")?;
    let sign_col_width = bytes[pos];
    pos += 1;
    Ok((GuiGutterConfig {
        cursor_line,
        line_number_style,
        line_number_width,
        sign_col_width,
    }, pos - offset))
}

pub fn decode_gui_gutter_entries(bytes: &[u8], offset: usize) -> Result<(Vec<GutterEntry>, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "entries count")?;
    let count = read_u16(bytes, pos) as usize;
    pos += 2;
    let mut items = Vec::with_capacity(count.min(bytes.len() - pos));
    for _ in 0..count {
        let (item, consumed) = decode_gutter_entry(bytes, pos)?;
        pos += consumed;
        items.push(item);
    }
    Ok((items, pos - offset))
}

// Section decoders for gui_picker

pub fn decode_gui_picker_header(bytes: &[u8], offset: usize) -> Result<(GuiPickerHeader, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "selected_index")?;
    let selected_index = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "filtered_count")?;
    let filtered_count = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "total_count")?;
    let total_count = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "has_preview")?;
    let has_preview = bytes[pos];
    pos += 1;
    let title = read_string16(bytes, &mut pos)?;
    require_len(bytes, pos + 2, "marked_count")?;
    let marked_count = read_u16(bytes, pos);
    pos += 2;
    Ok((GuiPickerHeader {
        visible,
        selected_index,
        filtered_count,
        total_count,
        has_preview,
        title,
        marked_count,
    }, pos - offset))
}

pub fn decode_gui_picker_query(bytes: &[u8], offset: usize) -> Result<(GuiPickerQuery, usize), DecodeError> {
    let mut pos = offset;
    let text = read_string16(bytes, &mut pos)?;
    Ok((GuiPickerQuery {
        text,
    }, pos - offset))
}

pub fn decode_gui_picker_items(bytes: &[u8], offset: usize) -> Result<(Vec<PickerItem>, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "items count")?;
    let count = read_u16(bytes, pos) as usize;
    pos += 2;
    let mut items = Vec::with_capacity(count.min(bytes.len() - pos));
    for _ in 0..count {
        let (item, consumed) = decode_picker_item(bytes, pos)?;
        pos += consumed;
        items.push(item);
    }
    Ok((items, pos - offset))
}

pub fn decode_gui_picker_action_menu(bytes: &[u8], offset: usize) -> Result<(GuiPickerActionMenu, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    let mut selected_index = 0;
    let mut actions = Vec::<String>::new();
    if visible == 1 {
        require_len(bytes, pos + 1, "selected_index")?;
        selected_index = bytes[pos];
        pos += 1;
        require_len(bytes, pos + 1, "actions count")?;
        let actions_count = bytes[pos] as usize;
        pos += 1;
        let mut actions_value = Vec::with_capacity(actions_count.min(bytes.len() - pos));
        for _ in 0..actions_count {
            actions_value.push(read_string16(bytes, &mut pos)?);
        }
        actions = actions_value;
    }
    Ok((GuiPickerActionMenu {
        visible,
        selected_index,
        actions,
    }, pos - offset))
}

pub fn decode_gui_picker_mode_prefix(bytes: &[u8], offset: usize) -> Result<(GuiPickerModePrefix, usize), DecodeError> {
    let mut pos = offset;
    let text = read_string16(bytes, &mut pos)?;
    Ok((GuiPickerModePrefix {
        text,
    }, pos - offset))
}

pub fn decode_gui_picker_load_status(bytes: &[u8], offset: usize) -> Result<(GuiPickerLoadStatus, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "status")?;
    let status = bytes[pos];
    pos += 1;
    let mut message = String::new();
    if status == 2 {
        message = read_string16(bytes, &mut pos)?;
    }
    Ok((GuiPickerLoadStatus {
        status,
        message,
    }, pos - offset))
}

// Section decoders for gui_picker_preview

pub fn decode_gui_picker_preview_header(bytes: &[u8], offset: usize) -> Result<(GuiPickerPreviewHeader, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "kind")?;
    let kind = bytes[pos];
    pos += 1;
    let title = read_string16(bytes, &mut pos)?;
    Ok((GuiPickerPreviewHeader {
        visible,
        kind,
        title,
    }, pos - offset))
}

// Section decoders for gui_status_bar

pub fn decode_gui_status_bar_identity(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarIdentity, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "content_kind")?;
    let content_kind = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "mode")?;
    let mode = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "flags")?;
    let flags = bytes[pos];
    pos += 1;
    Ok((GuiStatusBarIdentity {
        content_kind,
        mode,
        flags,
    }, pos - offset))
}

pub fn decode_gui_status_bar_cursor(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarCursor, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 4, "line")?;
    let line = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 4, "col")?;
    let col = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 4, "line_count")?;
    let line_count = read_u32(bytes, pos);
    pos += 4;
    Ok((GuiStatusBarCursor {
        line,
        col,
        line_count,
    }, pos - offset))
}

pub fn decode_gui_status_bar_diagnostics(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarDiagnostics, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "errors")?;
    let errors = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "warnings")?;
    let warnings = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "info")?;
    let info = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "hints")?;
    let hints = read_u16(bytes, pos);
    pos += 2;
    let hint_text = read_string16(bytes, &mut pos)?;
    Ok((GuiStatusBarDiagnostics {
        errors,
        warnings,
        info,
        hints,
        hint_text,
    }, pos - offset))
}

pub fn decode_gui_status_bar_language(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarLanguage, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "lsp_status")?;
    let lsp_status = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "parser_status")?;
    let parser_status = bytes[pos];
    pos += 1;
    Ok((GuiStatusBarLanguage {
        lsp_status,
        parser_status,
    }, pos - offset))
}

pub fn decode_gui_status_bar_git(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarGit, usize), DecodeError> {
    let mut pos = offset;
    let branch = read_string8(bytes, &mut pos)?;
    require_len(bytes, pos + 2, "added")?;
    let added = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "modified")?;
    let modified = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "deleted")?;
    let deleted = read_u16(bytes, pos);
    pos += 2;
    Ok((GuiStatusBarGit {
        branch,
        added,
        modified,
        deleted,
    }, pos - offset))
}

pub fn decode_gui_status_bar_file(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarFile, usize), DecodeError> {
    let mut pos = offset;
    let icon = read_string8(bytes, &mut pos)?;
    require_len(bytes, pos + 3, "icon_color")?;
    let icon_color = read_u24(bytes, pos);
    pos += 3;
    let filename = read_string16(bytes, &mut pos)?;
    let filetype = read_string8(bytes, &mut pos)?;
    Ok((GuiStatusBarFile {
        icon,
        icon_color,
        filename,
        filetype,
    }, pos - offset))
}

pub fn decode_gui_status_bar_message(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarMessage, usize), DecodeError> {
    let mut pos = offset;
    let text = read_string16(bytes, &mut pos)?;
    Ok((GuiStatusBarMessage {
        text,
    }, pos - offset))
}

pub fn decode_gui_status_bar_recording(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarRecording, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "macro_register")?;
    let macro_register = bytes[pos];
    pos += 1;
    Ok((GuiStatusBarRecording {
        macro_register,
    }, pos - offset))
}

pub fn decode_gui_status_bar_indent(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarIndent, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "indent_type")?;
    let indent_type = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "indent_size")?;
    let indent_size = bytes[pos];
    pos += 1;
    Ok((GuiStatusBarIndent {
        indent_type,
        indent_size,
    }, pos - offset))
}

pub fn decode_gui_status_bar_modeline(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarModeline, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "format")?;
    let format = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "left_segments count")?;
    let left_segments_count = read_u16(bytes, pos) as usize;
    pos += 2;
    let mut left_segments = Vec::with_capacity(left_segments_count.min(bytes.len() - pos));
    for _ in 0..left_segments_count {
        let (item, consumed) = decode_modeline_segment(bytes, pos)?;
        pos += consumed;
        left_segments.push(item);
    }
    require_len(bytes, pos + 2, "right_segments count")?;
    let right_segments_count = read_u16(bytes, pos) as usize;
    pos += 2;
    let mut right_segments = Vec::with_capacity(right_segments_count.min(bytes.len() - pos));
    for _ in 0..right_segments_count {
        let (item, consumed) = decode_modeline_segment(bytes, pos)?;
        pos += consumed;
        right_segments.push(item);
    }
    Ok((GuiStatusBarModeline {
        format,
        left_segments,
        right_segments,
    }, pos - offset))
}

pub fn decode_gui_status_bar_selection(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarSelection, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "selection_mode")?;
    let selection_mode = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 4, "selection_size")?;
    let selection_size = read_u32(bytes, pos);
    pos += 4;
    Ok((GuiStatusBarSelection {
        selection_mode,
        selection_size,
    }, pos - offset))
}

pub fn decode_gui_status_bar_workspace(bytes: &[u8], offset: usize) -> Result<(GuiStatusBarWorkspace, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "workspace_id")?;
    let workspace_id = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "kind")?;
    let kind = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "status")?;
    let status = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "flags")?;
    let flags = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "draft_count")?;
    let draft_count = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "conflict_count")?;
    let conflict_count = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "running_background_count")?;
    let running_background_count = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "attention_count")?;
    let attention_count = read_u16(bytes, pos);
    pos += 2;
    let label = read_string8(bytes, &mut pos)?;
    let icon = read_string8(bytes, &mut pos)?;
    Ok((GuiStatusBarWorkspace {
        workspace_id,
        kind,
        status,
        flags,
        draft_count,
        conflict_count,
        running_background_count,
        attention_count,
        label,
        icon,
    }, pos - offset))
}

// Section decoders for gui_window_content

pub fn decode_gui_window_content_header(bytes: &[u8], offset: usize) -> Result<(GuiWindowContentHeader, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "window_id")?;
    let window_id = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "flags")?;
    let flags = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "cursor_row")?;
    let cursor_row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "cursor_col")?;
    let cursor_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "cursor_shape")?;
    let cursor_shape = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "scroll_left")?;
    let scroll_left = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 4, "content_epoch")?;
    let content_epoch = read_u32(bytes, pos);
    pos += 4;
    Ok((GuiWindowContentHeader {
        window_id,
        flags,
        cursor_row,
        cursor_col,
        cursor_shape,
        scroll_left,
        content_epoch,
    }, pos - offset))
}

pub fn decode_gui_window_content_rows(bytes: &[u8], offset: usize) -> Result<(Vec<Row>, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "rows count")?;
    let count = read_u16(bytes, pos) as usize;
    pos += 2;
    let mut items = Vec::with_capacity(count.min(bytes.len() - pos));
    for _ in 0..count {
        let (item, consumed) = decode_row(bytes, pos)?;
        pos += consumed;
        items.push(item);
    }
    Ok((items, pos - offset))
}

pub fn decode_gui_window_content_selection(bytes: &[u8], offset: usize) -> Result<(GuiWindowContentSelection, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "type")?;
    let r#type = bytes[pos];
    pos += 1;
    let mut start_row = 0;
    let mut start_col = 0;
    let mut end_row = 0;
    let mut end_col = 0;
    if r#type != 0 {
        require_len(bytes, pos + 2, "start_row")?;
        start_row = read_u16(bytes, pos);
        pos += 2;
        require_len(bytes, pos + 2, "start_col")?;
        start_col = read_u16(bytes, pos);
        pos += 2;
        require_len(bytes, pos + 2, "end_row")?;
        end_row = read_u16(bytes, pos);
        pos += 2;
        require_len(bytes, pos + 2, "end_col")?;
        end_col = read_u16(bytes, pos);
        pos += 2;
    }
    Ok((GuiWindowContentSelection {
        r#type,
        start_row,
        start_col,
        end_row,
        end_col,
    }, pos - offset))
}

pub fn decode_gui_window_content_search_matches(bytes: &[u8], offset: usize) -> Result<(Vec<SearchMatch>, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "search_matches count")?;
    let count = read_u16(bytes, pos) as usize;
    pos += 2;
    require_len(bytes, pos + count * 7, "search_matches")?;
    let mut items = Vec::with_capacity(count);
    for _ in 0..count {
        let (item, consumed) = decode_search_match(bytes, pos)?;
        pos += consumed;
        items.push(item);
    }
    Ok((items, pos - offset))
}

pub fn decode_gui_window_content_diagnostic_ranges(bytes: &[u8], offset: usize) -> Result<(Vec<DiagnosticRange>, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "diagnostic_ranges count")?;
    let count = read_u16(bytes, pos) as usize;
    pos += 2;
    require_len(bytes, pos + count * 9, "diagnostic_ranges")?;
    let mut items = Vec::with_capacity(count);
    for _ in 0..count {
        let (item, consumed) = decode_diagnostic_range(bytes, pos)?;
        pos += consumed;
        items.push(item);
    }
    Ok((items, pos - offset))
}

pub fn decode_gui_window_content_document_highlights(bytes: &[u8], offset: usize) -> Result<(Vec<DocumentHighlight>, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "document_highlights count")?;
    let count = read_u16(bytes, pos) as usize;
    pos += 2;
    require_len(bytes, pos + count * 9, "document_highlights")?;
    let mut items = Vec::with_capacity(count);
    for _ in 0..count {
        let (item, consumed) = decode_document_highlight(bytes, pos)?;
        pos += consumed;
        items.push(item);
    }
    Ok((items, pos - offset))
}

pub fn decode_gui_window_content_annotations(bytes: &[u8], offset: usize) -> Result<(Vec<Annotation>, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "annotations count")?;
    let count = read_u16(bytes, pos) as usize;
    pos += 2;
    let mut items = Vec::with_capacity(count.min(bytes.len() - pos));
    for _ in 0..count {
        let (item, consumed) = decode_annotation(bytes, pos)?;
        pos += consumed;
        items.push(item);
    }
    Ok((items, pos - offset))
}

pub fn decode_gui_window_content_geometry(bytes: &[u8], offset: usize) -> Result<(GuiWindowContentGeometry, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "window_id")?;
    let window_id = read_u16(bytes, pos);
    pos += 2;
    let (total_rect, consumed) = decode_rect(bytes, pos)?;
    pos += consumed;
    let (content_rect, consumed) = decode_rect(bytes, pos)?;
    pos += consumed;
    let (text_rect, consumed) = decode_rect(bytes, pos)?;
    pos += consumed;
    let (gutter_rect, consumed) = decode_rect(bytes, pos)?;
    pos += consumed;
    let (clip_rect, consumed) = decode_rect(bytes, pos)?;
    pos += consumed;
    require_len(bytes, pos + 4, "viewport_top")?;
    let viewport_top = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 2, "viewport_left")?;
    let viewport_left = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "viewport_rows")?;
    let viewport_rows = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "viewport_cols")?;
    let viewport_cols = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 4, "viewport_total_lines")?;
    let viewport_total_lines = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 2, "viewport_visual_row_offset")?;
    let viewport_visual_row_offset = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 4, "viewport_total_visual_rows")?;
    let viewport_total_visual_rows = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 2, "line_number_width")?;
    let line_number_width = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "sign_col_width")?;
    let sign_col_width = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "hit_regions count")?;
    let hit_regions_count = bytes[pos] as usize;
    pos += 1;
    require_len(bytes, pos + hit_regions_count * 11, "hit_regions")?;
    let mut hit_regions = Vec::with_capacity(hit_regions_count);
    for _ in 0..hit_regions_count {
        let (item, consumed) = decode_hit_region(bytes, pos)?;
        pos += consumed;
        hit_regions.push(item);
    }
    Ok((GuiWindowContentGeometry {
        window_id,
        total_rect,
        content_rect,
        text_rect,
        gutter_rect,
        clip_rect,
        viewport_top,
        viewport_left,
        viewport_rows,
        viewport_cols,
        viewport_total_lines,
        viewport_visual_row_offset,
        viewport_total_visual_rows,
        line_number_width,
        sign_col_width,
        hit_regions,
    }, pos - offset))
}

pub fn decode_gui_window_content_cursorline(bytes: &[u8], offset: usize) -> Result<(GuiWindowContentCursorline, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "row")?;
    let row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 3, "bg")?;
    let bg = read_u24(bytes, pos);
    pos += 3;
    Ok((GuiWindowContentCursorline {
        row,
        bg,
    }, pos - offset))
}

// Section decoders for gui_window_rows_delta

pub fn decode_gui_window_rows_delta_header(bytes: &[u8], offset: usize) -> Result<(GuiWindowRowsDeltaHeader, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "window_id")?;
    let window_id = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 4, "content_epoch")?;
    let content_epoch = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 1, "flags")?;
    let flags = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "cursor_row")?;
    let cursor_row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "cursor_col")?;
    let cursor_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "cursor_shape")?;
    let cursor_shape = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "scroll_left")?;
    let scroll_left = read_u16(bytes, pos);
    pos += 2;
    Ok((GuiWindowRowsDeltaHeader {
        window_id,
        content_epoch,
        flags,
        cursor_row,
        cursor_col,
        cursor_shape,
        scroll_left,
    }, pos - offset))
}

pub fn decode_gui_window_rows_delta_rows(bytes: &[u8], offset: usize) -> Result<(Vec<Row>, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "rows count")?;
    let count = read_u16(bytes, pos) as usize;
    pos += 2;
    let mut items = Vec::with_capacity(count.min(bytes.len() - pos));
    for _ in 0..count {
        let (item, consumed) = decode_row(bytes, pos)?;
        pos += consumed;
        items.push(item);
    }
    Ok((items, pos - offset))
}

// Section decoders for gui_window_viewport_delta

pub fn decode_gui_window_viewport_delta_header(bytes: &[u8], offset: usize) -> Result<(GuiWindowViewportDeltaHeader, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "window_id")?;
    let window_id = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 4, "content_epoch")?;
    let content_epoch = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 1, "flags")?;
    let flags = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "cursor_row")?;
    let cursor_row = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "cursor_col")?;
    let cursor_col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "cursor_shape")?;
    let cursor_shape = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "scroll_left")?;
    let scroll_left = read_u16(bytes, pos);
    pos += 2;
    Ok((GuiWindowViewportDeltaHeader {
        window_id,
        content_epoch,
        flags,
        cursor_row,
        cursor_col,
        cursor_shape,
        scroll_left,
    }, pos - offset))
}

pub fn decode_gui_window_viewport_delta_rows(bytes: &[u8], offset: usize) -> Result<(Vec<Row>, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "rows count")?;
    let count = read_u16(bytes, pos) as usize;
    pos += 2;
    let mut items = Vec::with_capacity(count.min(bytes.len() - pos));
    for _ in 0..count {
        let (item, consumed) = decode_row(bytes, pos)?;
        pos += consumed;
        items.push(item);
    }
    Ok((items, pos - offset))
}

// Command field decoder for gui_tab_bar

pub fn decode_gui_tab_bar_fields(bytes: &[u8], offset: usize) -> Result<(GuiTabBarFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "active_index")?;
    let active_index = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "tab_count")?;
    let tab_count = bytes[pos];
    pos += 1;
    Ok((GuiTabBarFields {
        active_index,
        tab_count,
    }, pos - offset))
}

// Command field decoder for gui_theme

pub fn decode_gui_theme_fields(bytes: &[u8], offset: usize) -> Result<(GuiThemeFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "color_count")?;
    let color_count = bytes[pos];
    pos += 1;
    Ok((GuiThemeFields {
        color_count,
    }, pos - offset))
}

// Command field decoder for gui_breadcrumb

pub fn decode_gui_breadcrumb_fields(bytes: &[u8], offset: usize) -> Result<(GuiBreadcrumbFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "segment_count")?;
    let segment_count = bytes[pos];
    pos += 1;
    Ok((GuiBreadcrumbFields {
        segment_count,
    }, pos - offset))
}

// Command field decoder for gui_completion

pub fn decode_gui_completion_fields(bytes: &[u8], offset: usize) -> Result<(GuiCompletionFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    let mut cursor_row = 0;
    let mut cursor_col = 0;
    let mut selected_offset = 0;
    let mut items = Vec::<CompletionItem>::new();
    if visible == 1 {
        require_len(bytes, pos + 2, "cursor_row")?;
        cursor_row = read_u16(bytes, pos);
        pos += 2;
        require_len(bytes, pos + 2, "cursor_col")?;
        cursor_col = read_u16(bytes, pos);
        pos += 2;
        require_len(bytes, pos + 2, "selected_offset")?;
        selected_offset = read_u16(bytes, pos);
        pos += 2;
        require_len(bytes, pos + 2, "items count")?;
        let items_count = read_u16(bytes, pos) as usize;
        pos += 2;
        let mut items_value = Vec::with_capacity(items_count.min(bytes.len() - pos));
        for _ in 0..items_count {
            let (item, consumed) = decode_completion_item(bytes, pos)?;
            pos += consumed;
            items_value.push(item);
        }
        items = items_value;
    }
    Ok((GuiCompletionFields {
        visible,
        cursor_row,
        cursor_col,
        selected_offset,
        items,
    }, pos - offset))
}

// Command field decoder for gui_which_key

pub fn decode_gui_which_key_fields(bytes: &[u8], offset: usize) -> Result<(GuiWhichKeyFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    Ok((GuiWhichKeyFields {
        visible,
    }, pos - offset))
}

// Command field decoder for gui_minibuffer

pub fn decode_gui_minibuffer_fields(bytes: &[u8], offset: usize) -> Result<(GuiMinibufferFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    Ok((GuiMinibufferFields {
        visible,
    }, pos - offset))
}

// Command field decoder for gui_hover_popup

pub fn decode_gui_hover_popup_fields(bytes: &[u8], offset: usize) -> Result<(GuiHoverPopupFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    Ok((GuiHoverPopupFields {
        visible,
    }, pos - offset))
}

// Command field decoder for gui_signature_help

pub fn decode_gui_signature_help_fields(bytes: &[u8], offset: usize) -> Result<(GuiSignatureHelpFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    Ok((GuiSignatureHelpFields {
        visible,
    }, pos - offset))
}

// Command field decoder for gui_float_popup

pub fn decode_gui_float_popup_fields(bytes: &[u8], offset: usize) -> Result<(GuiFloatPopupFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    Ok((GuiFloatPopupFields {
        visible,
    }, pos - offset))
}

// Command field decoder for gui_split_separators

pub fn decode_gui_split_separators_fields(bytes: &[u8], offset: usize) -> Result<(GuiSplitSeparatorsFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 3, "bg")?;
    let bg = read_u24(bytes, pos);
    pos += 3;
    require_len(bytes, pos + 1, "vertical_count")?;
    let vertical_count = bytes[pos];
    pos += 1;
    Ok((GuiSplitSeparatorsFields {
        bg,
        vertical_count,
    }, pos - offset))
}

// Command field decoder for gui_git_status

pub fn decode_gui_git_status_fields(bytes: &[u8], offset: usize) -> Result<(GuiGitStatusFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "repo_state")?;
    let repo_state = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "syncing")?;
    let syncing = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "ahead")?;
    let ahead = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "behind")?;
    let behind = read_u16(bytes, pos);
    pos += 2;
    Ok((GuiGitStatusFields {
        repo_state,
        syncing,
        ahead,
        behind,
    }, pos - offset))
}

// Command field decoder for gui_bottom_panel

pub fn decode_gui_bottom_panel_fields(bytes: &[u8], offset: usize) -> Result<(GuiBottomPanelFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    Ok((GuiBottomPanelFields {
        visible,
    }, pos - offset))
}

// Command field decoder for gui_change_summary

pub fn decode_gui_change_summary_fields(bytes: &[u8], offset: usize) -> Result<(GuiChangeSummaryFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "selected_index")?;
    let selected_index = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "entry_count")?;
    let entry_count = read_u16(bytes, pos);
    pos += 2;
    Ok((GuiChangeSummaryFields {
        visible,
        selected_index,
        entry_count,
    }, pos - offset))
}

// Command field decoder for gui_board

pub fn decode_gui_board_fields(bytes: &[u8], offset: usize) -> Result<(GuiBoardFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 4, "focused_card_id")?;
    let focused_card_id = read_u32(bytes, pos);
    pos += 4;
    require_len(bytes, pos + 2, "card_count")?;
    let card_count = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "filter_mode")?;
    let filter_mode = bytes[pos];
    pos += 1;
    Ok((GuiBoardFields {
        visible,
        focused_card_id,
        card_count,
        filter_mode,
    }, pos - offset))
}

// Command field decoder for gui_agent_context

pub fn decode_gui_agent_context_fields(bytes: &[u8], offset: usize) -> Result<(GuiAgentContextFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    Ok((GuiAgentContextFields {
        visible,
    }, pos - offset))
}

// Command field decoder for gui_gutter_sep

pub fn decode_gui_gutter_sep_fields(bytes: &[u8], offset: usize) -> Result<(GuiGutterSepFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "col")?;
    let col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 3, "bg")?;
    let bg = read_u24(bytes, pos);
    pos += 3;
    Ok((GuiGutterSepFields {
        col,
        bg,
    }, pos - offset))
}

// Command field decoder for gui_cursorline

pub fn decode_gui_cursorline_fields(bytes: &[u8], offset: usize) -> Result<(GuiCursorlineFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 2, "col")?;
    let col = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 3, "bg")?;
    let bg = read_u24(bytes, pos);
    pos += 3;
    Ok((GuiCursorlineFields {
        col,
        bg,
    }, pos - offset))
}

// Command field decoder for gui_search_state

pub fn decode_gui_search_state_fields(bytes: &[u8], offset: usize) -> Result<(GuiSearchStateFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "active")?;
    let active = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "match_count")?;
    let match_count = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 2, "current_index")?;
    let current_index = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "flags")?;
    let flags = bytes[pos];
    pos += 1;
    Ok((GuiSearchStateFields {
        active,
        match_count,
        current_index,
        flags,
    }, pos - offset))
}

// Command field decoder for gui_edit_timeline

pub fn decode_gui_edit_timeline_fields(bytes: &[u8], offset: usize) -> Result<(GuiEditTimelineFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "viewing_index")?;
    let viewing_index = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "entry_count")?;
    let entry_count = bytes[pos];
    pos += 1;
    Ok((GuiEditTimelineFields {
        visible,
        viewing_index,
        entry_count,
    }, pos - offset))
}

// Command field decoder for gui_workspaces

pub fn decode_gui_workspaces_fields(bytes: &[u8], offset: usize) -> Result<(GuiWorkspacesFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "active_workspace_id")?;
    let active_workspace_id = read_u16(bytes, pos);
    pos += 2;
    require_len(bytes, pos + 1, "mode")?;
    let mode = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "flags")?;
    let flags = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "workspace_count")?;
    let workspace_count = bytes[pos];
    pos += 1;
    Ok((GuiWorkspacesFields {
        visible,
        active_workspace_id,
        mode,
        flags,
        workspace_count,
    }, pos - offset))
}

// Command field decoder for gui_notifications

pub fn decode_gui_notifications_fields(bytes: &[u8], offset: usize) -> Result<(GuiNotificationsFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "notification_count")?;
    let notification_count = read_u16(bytes, pos);
    pos += 2;
    Ok((GuiNotificationsFields {
        visible,
        notification_count,
    }, pos - offset))
}

// Command field decoder for gui_sidebars

pub fn decode_gui_sidebars_fields(bytes: &[u8], offset: usize) -> Result<(GuiSidebarsFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 2, "sidebar_count")?;
    let sidebar_count = read_u16(bytes, pos);
    pos += 2;
    Ok((GuiSidebarsFields {
        visible,
        sidebar_count,
    }, pos - offset))
}

// Command field decoder for gui_extension_overlay

pub fn decode_gui_extension_overlay_fields(bytes: &[u8], offset: usize) -> Result<(GuiExtensionOverlayFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "entry_count")?;
    let entry_count = bytes[pos];
    pos += 1;
    Ok((GuiExtensionOverlayFields {
        entry_count,
    }, pos - offset))
}

// Command field decoder for gui_extension_panel

pub fn decode_gui_extension_panel_fields(bytes: &[u8], offset: usize) -> Result<(GuiExtensionPanelFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "panel_count")?;
    let panel_count = bytes[pos];
    pos += 1;
    Ok((GuiExtensionPanelFields {
        panel_count,
    }, pos - offset))
}

// Command field decoder for gui_file_tree

pub fn decode_gui_file_tree_fields(bytes: &[u8], offset: usize) -> Result<(GuiFileTreeFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "flags")?;
    let flags = bytes[pos];
    pos += 1;
    require_len(bytes, pos + 1, "status")?;
    let status = bytes[pos];
    pos += 1;
    Ok((GuiFileTreeFields {
        visible,
        flags,
        status,
    }, pos - offset))
}

// Command field decoder for gui_tool_manager

pub fn decode_gui_tool_manager_fields(bytes: &[u8], offset: usize) -> Result<(GuiToolManagerFields, usize), DecodeError> {
    let mut pos = offset;
    require_len(bytes, pos + 1, "visible")?;
    let visible = bytes[pos];
    pos += 1;
    Ok((GuiToolManagerFields {
        visible,
    }, pos - offset))
}

