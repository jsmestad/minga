mod theme;

use crate::protocol::{self, Command, DrawStyledText, DrawText, Region};
use crate::semantic;
use crate::terminal::{CellStyle, Terminal};
use ratatui::buffer::Buffer as RatatuiBuffer;
use ratatui::layout::Rect as RatatuiRect;
use ratatui::style::{Color as RatatuiColor, Modifier, Style as RatatuiStyle};
use ratatui::widgets::{Block, Borders, Paragraph, Widget, Wrap};
use std::collections::HashMap;
use std::io::{self, Write};
use theme::{SLOT_EDITOR_BG, ThemePalette};

#[cfg(test)]
use theme::{
    SLOT_MODELINE_BAR_BG, SLOT_POPUP_BG, SLOT_POPUP_FG, SLOT_POPUP_SEL_BG, SLOT_POPUP_SEL_FG,
};

#[derive(Debug, Clone, PartialEq, Eq)]
struct Cell {
    text: String,
    style: CellStyle,
}

#[derive(Debug, Clone)]
struct CellSnapshot {
    row: u16,
    col: u16,
    width: u16,
    height: u16,
    cells: Vec<Cell>,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            text: " ".to_owned(),
            style: CellStyle::default(),
        }
    }
}

pub struct Renderer {
    width: u16,
    height: u16,
    cells: Vec<Cell>,
    previous: Vec<Cell>,
    cursor: (u16, u16),
    cursor_shape: u8,
    default_bg: u32,
    regions: HashMap<u16, Region>,
    active_region: Option<Region>,
    file_tree: Option<semantic::FileTree>,
    breadcrumb: Option<semantic::Breadcrumb>,
    picker: Option<semantic::Picker>,
    picker_preview: Option<semantic::PickerPreview>,
    minibuffer: Option<semantic::Minibuffer>,
    completion: Option<semantic::Completion>,
    which_key: Option<semantic::WhichKey>,
    signature_help: Option<semantic::SignatureHelp>,
    float_popup: Option<semantic::FloatPopup>,
    hover_popup: Option<semantic::HoverPopup>,
    picker_snapshot: Option<CellSnapshot>,
    minibuffer_snapshot: Option<CellSnapshot>,
    completion_snapshot: Option<CellSnapshot>,
    which_key_snapshot: Option<CellSnapshot>,
    signature_help_snapshot: Option<CellSnapshot>,
    float_popup_snapshot: Option<CellSnapshot>,
    hover_popup_snapshot: Option<CellSnapshot>,
    theme: ThemePalette,
}

impl Renderer {
    pub fn new(width: u16, height: u16) -> Self {
        let len = width as usize * height as usize;
        Self {
            width,
            height,
            cells: vec![Cell::default(); len],
            previous: vec![Cell::default(); len],
            cursor: (0, 0),
            cursor_shape: 0,
            default_bg: 0,
            regions: HashMap::new(),
            active_region: None,
            file_tree: None,
            breadcrumb: None,
            picker: None,
            picker_preview: None,
            minibuffer: None,
            completion: None,
            which_key: None,
            signature_help: None,
            float_popup: None,
            hover_popup: None,
            picker_snapshot: None,
            minibuffer_snapshot: None,
            completion_snapshot: None,
            which_key_snapshot: None,
            signature_help_snapshot: None,
            float_popup_snapshot: None,
            hover_popup_snapshot: None,
            theme: ThemePalette::default(),
        }
    }

    pub fn handle(
        &mut self,
        command: Command,
        terminal: &mut Terminal,
        output: &mut impl Write,
    ) -> io::Result<()> {
        match command {
            Command::Clear => self.clear(),
            Command::BatchEnd => self.render(terminal)?,
            Command::DrawText(draw) => self.draw_text(draw),
            Command::DrawStyledText(draw) => self.draw_styled_text(draw),
            Command::SetCursor { row, col } => self.cursor = (col, row),
            Command::SetCursorShape(shape) => self.cursor_shape = shape,
            Command::SetTitle(title) => terminal.set_title(&title)?,
            Command::SetWindowBg(bg) => {
                self.default_bg = bg;
                self.fill_bg(bg);
            }
            Command::DefineRegion(region) => {
                self.regions.insert(region.id, region);
            }
            Command::ClearRegion(id) => self.clear_region(id),
            Command::DestroyRegion(id) => {
                self.clear_region(id);
                self.regions.remove(&id);
                if self.active_region.is_some_and(|region| region.id == id) {
                    self.active_region = None;
                }
            }
            Command::SetActiveRegion(0) => self.active_region = None,
            Command::SetActiveRegion(id) => self.active_region = self.regions.get(&id).copied(),
            Command::ScrollRegion { top, bottom, delta } => {
                terminal.scroll_region(top, bottom, delta)?;
                self.sync_after_scroll(top, bottom, delta);
            }
            Command::MeasureText { request_id, text } => {
                let width = text_width(&text);
                protocol::write_packet(output, &protocol::encode_text_width(request_id, width))?;
            }
            Command::Semantic(command) => self.handle_semantic(command),
            Command::Noop(_) => {}
        }

        Ok(())
    }

    pub fn resize(&mut self, width: u16, height: u16) {
        self.width = width;
        self.height = height;
        self.cells = vec![Cell::default(); width as usize * height as usize];
        self.previous = vec![
            Cell {
                text: "\0".to_owned(),
                style: CellStyle::default()
            };
            width as usize * height as usize
        ];
        self.cursor = (0, 0);
        self.regions.clear();
        self.active_region = None;
        self.file_tree = None;
        self.breadcrumb = None;
        self.picker = None;
        self.picker_preview = None;
        self.minibuffer = None;
        self.completion = None;
        self.which_key = None;
        self.signature_help = None;
        self.float_popup = None;
        self.hover_popup = None;
        self.picker_snapshot = None;
        self.minibuffer_snapshot = None;
        self.completion_snapshot = None;
        self.which_key_snapshot = None;
        self.signature_help_snapshot = None;
        self.float_popup_snapshot = None;
        self.hover_popup_snapshot = None;
    }

    fn clear(&mut self) {
        for cell in &mut self.cells {
            *cell = Cell {
                style: CellStyle {
                    bg: self.default_bg,
                    ..CellStyle::default()
                },
                ..Cell::default()
            };
        }
    }

    fn fill_bg(&mut self, bg: u32) {
        for cell in &mut self.cells {
            if cell.style.bg == 0 {
                cell.style.bg = bg;
            }
        }
    }

    fn draw_text(&mut self, draw: DrawText) {
        self.write_run(
            draw.row,
            draw.col,
            &draw.text,
            CellStyle {
                fg: draw.fg,
                bg: draw.bg,
                attrs: draw.attrs,
                ul_color: 0,
                blend: 100,
            },
        );
    }

    fn draw_styled_text(&mut self, draw: DrawStyledText) {
        let _ = (draw.font_weight, draw.font_id);
        self.write_run(
            draw.row,
            draw.col,
            &draw.text,
            CellStyle {
                fg: draw.fg,
                bg: draw.bg,
                attrs: draw.attrs,
                ul_color: draw.ul_color,
                blend: draw.blend,
            },
        );
    }

    fn handle_semantic(&mut self, command: semantic::Command) {
        match command {
            semantic::Command::WindowContent(window, _) => self.draw_semantic_window(window),
            semantic::Command::StatusBar(status, _) => self.draw_status_bar(status),
            semantic::Command::TabBar(tab_bar, _) => self.draw_tab_bar(tab_bar),
            semantic::Command::FileTree(tree, _) => self.draw_file_tree(tree),
            semantic::Command::FileTreeSelection(selection, _) => {
                self.update_file_tree_selection(selection)
            }
            semantic::Command::Picker(picker, _) => self.draw_picker(picker),
            semantic::Command::PickerPreview(preview, _) => self.draw_picker_preview(preview),
            semantic::Command::Minibuffer(minibuffer, _) => self.draw_minibuffer(minibuffer),
            semantic::Command::Breadcrumb(breadcrumb, _) => self.draw_breadcrumb(breadcrumb),
            semantic::Command::Completion(completion, _) => self.draw_completion(completion),
            semantic::Command::WhichKey(which_key, _) => self.draw_which_key(which_key),
            semantic::Command::SignatureHelp(signature_help, _) => {
                self.draw_signature_help(signature_help)
            }
            semantic::Command::FloatPopup(float_popup, _) => self.draw_float_popup(float_popup),
            semantic::Command::HoverPopup(hover_popup, _) => self.draw_hover_popup(hover_popup),
            semantic::Command::Theme(theme, _) => self.apply_theme(theme),
            semantic::Command::Unsupported { .. } => {}
        }
    }

    fn draw_semantic_window(&mut self, window: semantic::WindowContent) {
        self.clear();
        self.cursor = (
            window.origin_col.saturating_add(window.cursor_col),
            window.origin_row.saturating_add(window.cursor_row),
        );
        self.cursor_shape = window.cursor_shape;

        for (row, content) in window.rows.into_iter().enumerate() {
            let row = window
                .origin_row
                .saturating_add(row.min(u16::MAX as usize) as u16);
            self.draw_semantic_row(row, window.origin_col, content);
        }

        self.redraw_retained_chrome();
    }

    fn draw_semantic_row(&mut self, row: u16, origin_col: u16, content: semantic::Row) {
        if content.spans.is_empty() {
            self.write_run(row, origin_col, &content.text, CellStyle::default());
            return;
        }

        for span in content.spans {
            let segment = slice_chars(&content.text, span.start_col, span.end_col);
            if segment.is_empty() {
                continue;
            }

            self.write_run(
                row,
                origin_col.saturating_add(span.start_col),
                &segment,
                CellStyle {
                    fg: span.fg,
                    bg: span.bg,
                    attrs: span.attrs,
                    ul_color: 0,
                    blend: 100,
                },
            );
        }
    }

    fn apply_theme(&mut self, theme: semantic::Theme) {
        self.theme = ThemePalette::from_theme(theme);
        self.default_bg = self.theme.color(SLOT_EDITOR_BG, self.default_bg);
        self.fill_bg(self.default_bg);
    }

    fn draw_status_bar(&mut self, status: semantic::StatusBar) {
        if self.height == 0 {
            return;
        }

        let row = self.height - 1;
        self.clear_row(row);

        let left = if status.left_segments.is_empty() {
            fallback_status_left(&status)
        } else {
            join_status_segments(&status.left_segments)
        };

        let right = if status.right_segments.is_empty() {
            fallback_status_right(&status)
        } else {
            join_status_segments(&status.right_segments)
        };

        let style = self.theme.status_bar_style();

        self.write_run(row, 0, &pad_to_width(&left, self.width), style);

        let right_width = text_width(&right);
        if right_width < self.width {
            self.write_run(row, self.width - right_width, &right, style);
        }
    }

    fn draw_tab_bar(&mut self, tab_bar: semantic::TabBar) {
        if self.height == 0 {
            return;
        }

        self.clear_row(0);
        let mut col = 0;

        for tab in tab_bar.tabs {
            if col >= self.width {
                break;
            }

            let label = if tab.dirty {
                format!(" {} * ", tab.label)
            } else {
                format!(" {} ", tab.label)
            };
            self.write_run(0, col, &label, self.theme.tab_style(tab.active, tab.tint));
            col = col.saturating_add(text_width(&label));
        }
    }

    fn draw_file_tree(&mut self, tree: semantic::FileTree) {
        self.file_tree = Some(tree);
        self.render_file_tree();
    }

    fn update_file_tree_selection(&mut self, selection: semantic::FileTreeSelection) {
        if let Some(tree) = &mut self.file_tree {
            tree.focused = selection.focused;
            tree.selected_id = selection.selected_id;
        }
        self.render_file_tree();
    }

    fn draw_picker(&mut self, picker: semantic::Picker) {
        if picker.visible {
            self.picker = Some(picker);
            self.render_picker();
        } else {
            self.restore_picker_snapshot();
            self.picker = None;
            self.picker_preview = None;
        }
    }

    fn draw_picker_preview(&mut self, preview: semantic::PickerPreview) {
        if preview.visible {
            self.picker_preview = Some(preview);
        } else {
            self.picker_preview = None;
        }
        self.render_picker();
    }

    fn draw_minibuffer(&mut self, minibuffer: semantic::Minibuffer) {
        if !minibuffer.visible {
            self.restore_minibuffer_snapshot();
            self.minibuffer = None;
            return;
        }
        if self.height < 2 || self.width == 0 {
            return;
        }

        self.minibuffer = Some(minibuffer.clone());
        self.render_minibuffer(&minibuffer);
    }

    fn draw_breadcrumb(&mut self, breadcrumb: semantic::Breadcrumb) {
        if self.width == 0 || self.height < 3 {
            return;
        }

        let row = 1;
        if breadcrumb.segments.is_empty() {
            self.clear_row(row);
            self.breadcrumb = None;
            return;
        }

        self.breadcrumb = Some(breadcrumb.clone());
        let text = format!(" {}", breadcrumb.segments.join(" / "));
        self.write_run(
            row,
            0,
            &pad_to_width(&text, self.width),
            self.theme.breadcrumb_style(),
        );
    }

    fn draw_completion(&mut self, completion: semantic::Completion) {
        if completion.visible {
            self.completion = Some(completion.clone());
            self.render_completion(&completion);
        } else {
            self.restore_completion_snapshot();
            self.completion = None;
        }
    }

    fn draw_which_key(&mut self, which_key: semantic::WhichKey) {
        if which_key.visible {
            self.which_key = Some(which_key.clone());
            self.render_which_key(&which_key);
        } else {
            self.restore_which_key_snapshot();
            self.which_key = None;
        }
    }

    fn draw_signature_help(&mut self, signature_help: semantic::SignatureHelp) {
        if signature_help.visible {
            self.signature_help = Some(signature_help.clone());
            self.render_signature_help(&signature_help);
        } else {
            self.restore_signature_help_snapshot();
            self.signature_help = None;
        }
    }

    fn draw_float_popup(&mut self, float_popup: semantic::FloatPopup) {
        if float_popup.visible {
            self.float_popup = Some(float_popup.clone());
            self.render_float_popup(&float_popup);
        } else {
            self.restore_float_popup_snapshot();
            self.float_popup = None;
        }
    }

    fn draw_hover_popup(&mut self, hover_popup: semantic::HoverPopup) {
        if hover_popup.visible {
            self.hover_popup = Some(hover_popup.clone());
            self.render_hover_popup(&hover_popup);
        } else {
            self.restore_hover_popup_snapshot();
            self.hover_popup = None;
        }
    }

    fn render_minibuffer(&mut self, minibuffer: &semantic::Minibuffer) {
        self.capture_minibuffer_snapshot();
        self.restore_minibuffer_cells();

        let row = self.height.saturating_sub(2);
        let prompt = format!("{}{}", minibuffer.prompt, minibuffer.input);
        self.write_run(
            row,
            0,
            &pad_to_width(&prompt, self.width),
            self.theme.minibuffer_style(false),
        );
        if minibuffer.cursor_pos != u16::MAX {
            self.cursor = (
                text_width(&minibuffer.prompt)
                    .saturating_add(minibuffer.cursor_pos)
                    .min(self.width.saturating_sub(1)),
                row,
            );
        }

        if !minibuffer.context.is_empty() && row > 0 {
            self.write_run(
                row - 1,
                0,
                &pad_to_width(&format!(" {}", minibuffer.context), self.width),
                self.theme.minibuffer_context_style(),
            );
        }

        let candidate_count = minibuffer.candidates.len().min(5);
        if candidate_count == 0 || row == 0 {
            return;
        }

        let first_row = row.saturating_sub(candidate_count as u16);
        let selected_index = minibuffer.selected_index as usize;
        let start_index = selected_index
            .saturating_add(1)
            .saturating_sub(candidate_count)
            .min(minibuffer.candidates.len().saturating_sub(candidate_count));
        for (index, candidate) in minibuffer
            .candidates
            .iter()
            .skip(start_index)
            .take(candidate_count)
            .enumerate()
        {
            let candidate_index = start_index + index;
            let selected = candidate_index == selected_index;
            let annotation = if candidate.annotation.is_empty() {
                String::new()
            } else {
                format!("  {}", candidate.annotation)
            };
            let description = if candidate.description.is_empty() {
                String::new()
            } else {
                format!(" - {}", candidate.description)
            };
            let marker = if selected { ">" } else { " " };
            let text = format!("{marker} {}{}{}", candidate.label, annotation, description);
            self.write_run(
                first_row + index as u16,
                0,
                &pad_to_width(&text, self.width),
                self.theme.minibuffer_style(selected),
            );
        }
    }

    fn redraw_retained_chrome(&mut self) {
        self.render_file_tree();
        if let Some(breadcrumb) = self.breadcrumb.clone() {
            self.draw_breadcrumb(breadcrumb);
        }
        if let Some(completion) = self.completion.clone() {
            self.completion_snapshot = None;
            self.render_completion(&completion);
        }
        self.picker_snapshot = None;
        self.render_picker();

        if let Some(which_key) = self.which_key.clone() {
            self.which_key_snapshot = None;
            self.render_which_key(&which_key);
        }

        if let Some(signature_help) = self.signature_help.clone() {
            self.signature_help_snapshot = None;
            self.render_signature_help(&signature_help);
        }
        if let Some(float_popup) = self.float_popup.clone() {
            self.float_popup_snapshot = None;
            self.render_float_popup(&float_popup);
        }
        if let Some(hover_popup) = self.hover_popup.clone() {
            self.hover_popup_snapshot = None;
            self.render_hover_popup(&hover_popup);
        }

        if let Some(minibuffer) = self.minibuffer.clone() {
            self.minibuffer_snapshot = None;
            self.render_minibuffer(&minibuffer);
        }
    }

    fn render_picker(&mut self) {
        let Some(picker) = self.picker.clone() else {
            return;
        };
        if !picker.visible || self.width < 24 || self.height < 8 {
            return;
        }

        let preview = self.picker_preview.clone();
        let (row, col, width, height) = picker_geometry(self.width, self.height);
        if self.picker_snapshot.is_none() {
            self.picker_snapshot = Some(self.capture_rect(row, col, width, height));
        }
        self.fill_rect(row, col, width, height, self.theme.picker_style(false));

        let title = if picker.mode_prefix.is_empty() {
            picker.title.clone()
        } else {
            format!("{} {}", picker.mode_prefix, picker.title)
        };
        self.write_run(
            row,
            col,
            &pad_to_width(&title, width),
            self.theme.picker_header_style(),
        );

        let count = if picker.total_count == 0 {
            String::new()
        } else {
            format!("{} / {}", picker.filtered_count, picker.total_count)
        };
        let count_width = text_width(&count);
        if count_width > 0 && count_width < width {
            self.write_run(
                row,
                col + width - count_width - 1,
                &count,
                self.theme.picker_header_style(),
            );
        }

        let query = if picker.query.is_empty() {
            "> ".to_owned()
        } else {
            format!("> {}", picker.query)
        };
        self.write_run(
            row + 1,
            col,
            &pad_to_width(&query, width),
            self.theme.picker_query_style(),
        );

        let body_row = row + 2;
        let body_height = height.saturating_sub(2);
        let wants_preview = picker.has_preview && preview.as_ref().is_some_and(|p| p.visible);
        let preview_width = if wants_preview { width / 2 } else { 0 };
        let item_width = width.saturating_sub(preview_width);

        self.render_picker_items(body_row, col, item_width, body_height, &picker);

        if wants_preview && preview_width > 8 {
            self.render_picker_preview(
                body_row,
                col + item_width,
                preview_width,
                body_height,
                preview.as_ref().unwrap(),
            );
        }
    }

    fn restore_picker_snapshot(&mut self) {
        if let Some(snapshot) = self.picker_snapshot.take() {
            self.restore_snapshot(snapshot);
        }
    }

    fn capture_minibuffer_snapshot(&mut self) {
        if self.minibuffer_snapshot.is_some() || self.height < 2 || self.width == 0 {
            return;
        }

        let prompt_row = self.height.saturating_sub(2);
        let first_row = prompt_row.saturating_sub(5);
        let height = prompt_row.saturating_sub(first_row).saturating_add(1);
        self.minibuffer_snapshot = Some(self.capture_rect(first_row, 0, self.width, height));
    }

    fn restore_minibuffer_snapshot(&mut self) {
        if let Some(snapshot) = self.minibuffer_snapshot.take() {
            self.restore_snapshot(snapshot);
        }
    }

    fn restore_minibuffer_cells(&mut self) {
        if let Some(snapshot) = self.minibuffer_snapshot.clone() {
            self.restore_snapshot(snapshot);
        }
    }

    fn render_completion(&mut self, completion: &semantic::Completion) {
        self.restore_completion_cells();
        if completion.items.is_empty() || self.width == 0 || self.height == 0 {
            return;
        }

        let height = completion.items.len().min(8) as u16;
        let width = completion_width(completion).min(self.width).max(18);
        let row = completion
            .anchor_row
            .saturating_add(1)
            .min(self.height.saturating_sub(height));
        let col = completion.anchor_col.min(self.width.saturating_sub(width));

        if self.completion_snapshot.is_none() {
            self.completion_snapshot = Some(self.capture_rect(row, col, width, height));
        }

        self.fill_rect(row, col, width, height, self.theme.completion_style(false));

        let selected_index = completion.selected_index as usize;
        let visible_rows = height as usize;
        let start = selected_index
            .saturating_add(1)
            .saturating_sub(visible_rows)
            .min(completion.items.len().saturating_sub(visible_rows));
        for (screen_index, item) in completion
            .items
            .iter()
            .skip(start)
            .take(visible_rows)
            .enumerate()
        {
            let item_index = start + screen_index;
            let selected = item_index == selected_index;
            let detail = if item.detail.is_empty() {
                String::new()
            } else {
                format!("  {}", item.detail)
            };
            let line = format!(
                "{} {}{}",
                completion_kind_marker(item.kind),
                item.label,
                detail
            );
            self.write_run(
                row + screen_index as u16,
                col,
                &pad_to_width(&line, width),
                self.theme.completion_style(selected),
            );
        }
    }

    fn restore_completion_snapshot(&mut self) {
        if let Some(snapshot) = self.completion_snapshot.take() {
            self.restore_snapshot(snapshot);
        }
    }

    fn restore_completion_cells(&mut self) {
        if let Some(snapshot) = self.completion_snapshot.clone() {
            self.restore_snapshot(snapshot);
        }
    }

    fn render_which_key(&mut self, which_key: &semantic::WhichKey) {
        self.restore_which_key_cells();
        if which_key.bindings.is_empty() || self.width < 24 || self.height < 4 {
            return;
        }

        let width = self.width.saturating_sub(4).clamp(24, 92);
        let height = which_key.bindings.len().min(8) as u16 + 1;
        let row = self.height.saturating_sub(height + 1);
        let col = self.width.saturating_sub(width) / 2;

        if self.which_key_snapshot.is_none() {
            self.which_key_snapshot = Some(self.capture_rect(row, col, width, height));
        }

        self.fill_rect(row, col, width, height, self.theme.which_key_style(false));
        let page = if which_key.page_count > 1 {
            format!(
                "  {}/{}",
                which_key.page.saturating_add(1),
                which_key.page_count
            )
        } else {
            String::new()
        };
        let title = format!(" {}{}", which_key.prefix, page);
        self.write_run(
            row,
            col,
            &pad_to_width(&title, width),
            self.theme.which_key_header_style(),
        );

        for (index, binding) in which_key
            .bindings
            .iter()
            .take(height.saturating_sub(1) as usize)
            .enumerate()
        {
            let icon = if binding.icon.is_empty() {
                if binding.kind == 1 { ">" } else { " " }
            } else {
                binding.icon.as_str()
            };
            let text = format!(" {icon} {:<8} {}", binding.key, binding.description);
            self.write_run(
                row + 1 + index as u16,
                col,
                &pad_to_width(&text, width),
                self.theme.which_key_style(binding.kind == 1),
            );
        }
    }

    fn restore_which_key_snapshot(&mut self) {
        if let Some(snapshot) = self.which_key_snapshot.take() {
            self.restore_snapshot(snapshot);
        }
    }

    fn restore_which_key_cells(&mut self) {
        if let Some(snapshot) = self.which_key_snapshot.clone() {
            self.restore_snapshot(snapshot);
        }
    }

    fn render_signature_help(&mut self, signature_help: &semantic::SignatureHelp) {
        self.restore_signature_help_cells();
        let Some(signature) = signature_help
            .signatures
            .get(signature_help.active_signature as usize)
            .or_else(|| signature_help.signatures.first())
        else {
            return;
        };

        let mut lines = vec![highlight_signature_label(
            signature,
            signature_help.active_parameter as usize,
        )];
        if !signature.documentation.is_empty() {
            lines.push(signature.documentation.clone());
        }
        if let Some(parameter) = signature
            .parameters
            .get(signature_help.active_parameter as usize)
            && !parameter.documentation.is_empty()
        {
            lines.push(format!("{}: {}", parameter.label, parameter.documentation));
        }

        let (row, col, width, height) = anchored_popup_geometry(
            self.width,
            self.height,
            signature_help.anchor_row,
            signature_help.anchor_col,
            lines.iter().map(String::as_str),
            "Signature",
        );
        if self.signature_help_snapshot.is_none() {
            self.signature_help_snapshot = Some(self.capture_rect(row, col, width, height));
        }
        self.render_popup_panel(row, col, width, height, " Signature ", lines.join("\n"));
    }

    fn restore_signature_help_snapshot(&mut self) {
        if let Some(snapshot) = self.signature_help_snapshot.take() {
            self.restore_snapshot(snapshot);
        }
    }

    fn restore_signature_help_cells(&mut self) {
        if let Some(snapshot) = self.signature_help_snapshot.clone() {
            self.restore_snapshot(snapshot);
        }
    }

    fn render_float_popup(&mut self, float_popup: &semantic::FloatPopup) {
        self.restore_float_popup_cells();
        if float_popup.width == 0 || float_popup.height == 0 {
            return;
        }

        let width = float_popup.width.min(self.width).max(12);
        let height = float_popup.height.min(self.height).max(3);
        let row = self.height.saturating_sub(height) / 2;
        let col = self.width.saturating_sub(width) / 2;
        if self.float_popup_snapshot.is_none() {
            self.float_popup_snapshot = Some(self.capture_rect(row, col, width, height));
        }

        let title = if float_popup.title.is_empty() {
            " Popup ".to_owned()
        } else {
            format!(" {} ", float_popup.title)
        };
        self.render_popup_panel(
            row,
            col,
            width,
            height,
            &title,
            float_popup.lines.join("\n"),
        );
    }

    fn restore_float_popup_snapshot(&mut self) {
        if let Some(snapshot) = self.float_popup_snapshot.take() {
            self.restore_snapshot(snapshot);
        }
    }

    fn restore_float_popup_cells(&mut self) {
        if let Some(snapshot) = self.float_popup_snapshot.clone() {
            self.restore_snapshot(snapshot);
        }
    }

    fn render_hover_popup(&mut self, hover_popup: &semantic::HoverPopup) {
        self.restore_hover_popup_cells();
        if hover_popup.lines.is_empty() {
            return;
        }

        let lines: Vec<String> = hover_popup
            .lines
            .iter()
            .skip(hover_popup.scroll_offset as usize)
            .map(|line| {
                let text = line
                    .segments
                    .iter()
                    .map(|segment| segment.text.as_str())
                    .collect::<String>();
                if line.line_type == 1 {
                    format!("  {text}")
                } else {
                    text
                }
            })
            .collect();
        let title = if hover_popup.focused {
            " Hover * "
        } else {
            " Hover "
        };
        let (row, col, width, height) = anchored_popup_geometry(
            self.width,
            self.height,
            hover_popup.anchor_row,
            hover_popup.anchor_col,
            lines.iter().map(String::as_str),
            title,
        );
        if self.hover_popup_snapshot.is_none() {
            self.hover_popup_snapshot = Some(self.capture_rect(row, col, width, height));
        }
        self.render_popup_panel(row, col, width, height, title, lines.join("\n"));
    }

    fn restore_hover_popup_snapshot(&mut self) {
        if let Some(snapshot) = self.hover_popup_snapshot.take() {
            self.restore_snapshot(snapshot);
        }
    }

    fn restore_hover_popup_cells(&mut self) {
        if let Some(snapshot) = self.hover_popup_snapshot.clone() {
            self.restore_snapshot(snapshot);
        }
    }

    fn render_popup_panel(
        &mut self,
        row: u16,
        col: u16,
        width: u16,
        height: u16,
        title: &str,
        body: String,
    ) {
        let style = ratatui_style_from_cell(self.theme.picker_style(false));
        let border_style = ratatui_style_from_cell(self.theme.picker_header_style());
        let paragraph = Paragraph::new(body)
            .style(style)
            .wrap(Wrap { trim: false })
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_style(border_style)
                    .title(title.to_owned()),
            );
        self.render_ratatui_widget(row, col, width, height, paragraph);
    }

    fn render_picker_items(
        &mut self,
        row: u16,
        col: u16,
        width: u16,
        height: u16,
        picker: &semantic::Picker,
    ) {
        if width == 0 || height == 0 {
            return;
        }

        if picker.load_status == 1 {
            self.write_run(
                row,
                col,
                &pad_to_width(" Loading...", width),
                self.theme.picker_style(false),
            );
            return;
        }
        if picker.load_status == 2 {
            let message = if picker.load_error.is_empty() {
                " Picker failed".to_owned()
            } else {
                format!(" {}", picker.load_error)
            };
            self.write_run(
                row,
                col,
                &pad_to_width(&message, width),
                self.theme.picker_style(false),
            );
            return;
        }

        if picker.items.is_empty() {
            self.write_run(
                row,
                col,
                &pad_to_width(" No matches", width),
                self.theme.picker_style(false),
            );
            return;
        }

        let visible_rows = height as usize;
        let selected = picker.selected_index as usize;
        let start = selected.saturating_sub(visible_rows.saturating_sub(1));
        for (screen_index, item) in picker
            .items
            .iter()
            .skip(start)
            .take(visible_rows)
            .enumerate()
        {
            let item_index = start + screen_index;
            let selected = item_index == selected;
            let marker = if item.marked {
                "*"
            } else if selected {
                ">"
            } else {
                " "
            };
            let annotation = if item.annotation.is_empty() {
                String::new()
            } else {
                format!(" {}", item.annotation)
            };
            let description = if item.description.is_empty() {
                String::new()
            } else {
                format!("  {}", item.description)
            };
            let line = format!("{marker} {}{}{}", item.label, annotation, description);
            self.write_run(
                row + screen_index as u16,
                col,
                &pad_to_width(&line, width),
                self.theme.picker_style(selected),
            );
        }
    }

    fn render_picker_preview(
        &mut self,
        row: u16,
        col: u16,
        width: u16,
        height: u16,
        preview: &semantic::PickerPreview,
    ) {
        self.fill_rect(
            row,
            col,
            width,
            height,
            self.theme.picker_preview_style(false, 0),
        );

        for (line_index, segments) in preview.lines.iter().take(height as usize).enumerate() {
            let mut current_col = col.saturating_add(1);
            for segment in segments {
                if current_col >= col.saturating_add(width) {
                    break;
                }
                let remaining = col.saturating_add(width).saturating_sub(current_col);
                let text = slice_chars(&segment.text, 0, remaining);
                let segment_width = text_width(&text);
                self.write_run(
                    row + line_index as u16,
                    current_col,
                    &text,
                    self.theme.picker_preview_style(segment.bold, segment.fg),
                );
                current_col = current_col.saturating_add(segment_width);
            }
        }
    }

    fn render_file_tree(&mut self) {
        let Some(tree) = self.file_tree.clone() else {
            return;
        };
        if !tree.visible || tree.width == 0 || self.height <= 2 {
            return;
        }

        let width = tree.width.min(self.width);
        for row in 1..self.height - 1 {
            self.write_run(
                row,
                0,
                &" ".repeat(width as usize),
                self.theme.file_tree_style(false, tree.focused),
            );
        }

        match tree.status {
            1 => self.write_run(
                1,
                0,
                " Loading...",
                self.theme.file_tree_style(false, tree.focused),
            ),
            2 => self.write_run(
                1,
                0,
                " Empty",
                self.theme.file_tree_style(false, tree.focused),
            ),
            4 => {
                let message = if tree.error.is_empty() {
                    " File tree error".to_owned()
                } else {
                    format!(" {}", tree.error)
                };
                self.write_run(
                    1,
                    0,
                    &message,
                    self.theme.file_tree_style(false, tree.focused),
                );
            }
            _ => {
                let visible_rows = self.height.saturating_sub(2) as usize;
                for (index, row) in tree.rows.iter().take(visible_rows).enumerate() {
                    self.render_file_tree_row(
                        index as u16 + 1,
                        width,
                        tree.focused,
                        row,
                        &tree.selected_id,
                    );
                }
            }
        }
    }

    fn render_file_tree_row(
        &mut self,
        screen_row: u16,
        width: u16,
        focused: bool,
        row: &semantic::FileTreeRow,
        selected_id: &str,
    ) {
        let selected = row.id == selected_id;
        let indent = "  ".repeat(row.depth as usize);
        let marker = if row.flags & 0x01 != 0 {
            if row.flags & 0x02 != 0 { "v " } else { "> " }
        } else {
            "  "
        };
        let dirty = if row.flags & 0x20 != 0 { " *" } else { "" };
        let git = git_marker(row.git_status);
        let diag = diagnostic_marker(row.diagnostics);
        let label = if row.editing_text.is_empty() {
            format!(
                " {indent}{marker}{} {}{dirty}{git}{diag}",
                row.icon, row.name
            )
        } else {
            format!(" {indent}{marker}{} {}", row.icon, row.editing_text)
        };

        self.write_run(
            screen_row,
            0,
            &pad_to_width(&label, width),
            self.theme.file_tree_style(selected, focused),
        );
    }

    fn write_run(&mut self, row: u16, col: u16, text: &str, mut style: CellStyle) {
        let (row, mut col, max_col) = match self.resolve_region(row, col) {
            Some(bounds) => bounds,
            None => return,
        };

        if style.bg == 0 {
            style.bg = self.default_bg;
        }

        for ch in text.chars() {
            if col >= max_col {
                break;
            }

            if let Some(index) = self.index(col, row) {
                self.cells[index] = Cell {
                    text: ch.to_string(),
                    style,
                };
            }

            col = col.saturating_add(char_width(ch));
        }
    }

    fn resolve_region(&self, row: u16, col: u16) -> Option<(u16, u16, u16)> {
        match self.active_region {
            Some(region) => {
                let row = region.row.saturating_add(row);
                let col = region.col.saturating_add(col);
                let max_row = region.row.saturating_add(region.height);
                let max_col = self.width.min(region.col.saturating_add(region.width));

                if row >= max_row {
                    None
                } else {
                    Some((row, col, max_col))
                }
            }
            None => Some((row, col, self.width)),
        }
    }

    fn clear_region(&mut self, id: u16) {
        let Some(region) = self.regions.get(&id).copied() else {
            return;
        };

        for row in region.row..region.row.saturating_add(region.height).min(self.height) {
            for col in region.col..region.col.saturating_add(region.width).min(self.width) {
                if let Some(index) = self.index(col, row) {
                    self.cells[index] = Cell::default();
                }
            }
        }
    }

    fn sync_after_scroll(&mut self, top: u16, bottom: u16, delta: i16) {
        if delta == 0 || top >= bottom || bottom >= self.height {
            return;
        }

        let amount = delta.unsigned_abs();
        let height = bottom - top + 1;

        if amount >= height {
            for row in top..=bottom {
                self.clear_row(row);
            }
            self.previous.clone_from(&self.cells);
            return;
        }

        if delta > 0 {
            for row in top..=bottom - amount {
                self.copy_row(row + amount, row);
            }
            for row in bottom - amount + 1..=bottom {
                self.clear_row(row);
            }
        } else {
            for row in (top + amount..=bottom).rev() {
                self.copy_row(row - amount, row);
            }
            for row in top..top + amount {
                self.clear_row(row);
            }
        }

        self.previous.clone_from(&self.cells);
    }

    fn copy_row(&mut self, source: u16, target: u16) {
        for col in 0..self.width {
            if let (Some(source_index), Some(target_index)) =
                (self.index(col, source), self.index(col, target))
            {
                self.cells[target_index] = self.cells[source_index].clone();
            }
        }
    }

    fn clear_row(&mut self, row: u16) {
        for col in 0..self.width {
            if let Some(index) = self.index(col, row) {
                self.cells[index] = Cell::default();
            }
        }
    }

    fn fill_rect(&mut self, row: u16, col: u16, width: u16, height: u16, style: CellStyle) {
        let line = " ".repeat(width as usize);
        for y in row..row.saturating_add(height).min(self.height) {
            self.write_run(y, col, &line, style);
        }
    }

    fn render_ratatui_widget<W: Widget>(
        &mut self,
        row: u16,
        col: u16,
        width: u16,
        height: u16,
        widget: W,
    ) {
        if width == 0 || height == 0 {
            return;
        }

        let area = RatatuiRect::new(0, 0, width, height);
        let mut buffer = RatatuiBuffer::empty(area);
        widget.render(area, &mut buffer);

        for y in 0..height {
            for x in 0..width {
                let target_row = row.saturating_add(y);
                let target_col = col.saturating_add(x);
                let Some(target_index) = self.index(target_col, target_row) else {
                    continue;
                };
                let Some(source) = buffer.cell((x, y)) else {
                    continue;
                };
                self.cells[target_index] = Cell {
                    text: source.symbol().to_owned(),
                    style: cell_style_from_ratatui(source),
                };
            }
        }
    }

    fn capture_rect(&self, row: u16, col: u16, width: u16, height: u16) -> CellSnapshot {
        let max_row = row.saturating_add(height).min(self.height);
        let max_col = col.saturating_add(width).min(self.width);
        let mut cells = Vec::with_capacity(
            max_row.saturating_sub(row) as usize * max_col.saturating_sub(col) as usize,
        );

        for y in row..max_row {
            for x in col..max_col {
                if let Some(index) = self.index(x, y) {
                    cells.push(self.cells[index].clone());
                }
            }
        }

        CellSnapshot {
            row,
            col,
            width: max_col.saturating_sub(col),
            height: max_row.saturating_sub(row),
            cells,
        }
    }

    fn restore_snapshot(&mut self, snapshot: CellSnapshot) {
        let mut snapshot_index = 0;
        for y in snapshot.row
            ..snapshot
                .row
                .saturating_add(snapshot.height)
                .min(self.height)
        {
            for x in snapshot.col..snapshot.col.saturating_add(snapshot.width).min(self.width) {
                if let Some(index) = self.index(x, y)
                    && let Some(cell) = snapshot.cells.get(snapshot_index)
                {
                    self.cells[index] = cell.clone();
                }
                snapshot_index += 1;
            }
        }
    }

    fn render(&mut self, terminal: &mut Terminal) -> io::Result<()> {
        for row in 0..self.height {
            for col in 0..self.width {
                let Some(index) = self.index(col, row) else {
                    continue;
                };

                if self.cells[index] != self.previous[index] {
                    terminal.write_cell(
                        col,
                        row,
                        &self.cells[index].text,
                        self.cells[index].style,
                    )?;
                    self.previous[index] = self.cells[index].clone();
                }
            }
        }

        terminal.set_cursor_shape(self.cursor_shape)?;
        terminal.show_cursor(self.cursor.0, self.cursor.1)?;
        terminal.flush()
    }

    fn index(&self, col: u16, row: u16) -> Option<usize> {
        if col < self.width && row < self.height {
            Some(row as usize * self.width as usize + col as usize)
        } else {
            None
        }
    }
}

fn text_width(text: &str) -> u16 {
    text.chars()
        .map(char_width)
        .fold(0_u16, u16::saturating_add)
}

fn char_width(ch: char) -> u16 {
    let _ = ch;
    1
}

fn picker_geometry(width: u16, height: u16) -> (u16, u16, u16, u16) {
    let overlay_width = width.saturating_sub(4).clamp(24, 96);
    let overlay_height = height.saturating_sub(4).clamp(8, 18);
    let row = if height > overlay_height {
        (height - overlay_height) / 3 + 1
    } else {
        0
    };
    let col = width.saturating_sub(overlay_width) / 2;
    (
        row,
        col,
        overlay_width.min(width),
        overlay_height.min(height),
    )
}

fn anchored_popup_geometry<'a>(
    screen_width: u16,
    screen_height: u16,
    anchor_row: u16,
    anchor_col: u16,
    lines: impl Iterator<Item = &'a str>,
    title: &str,
) -> (u16, u16, u16, u16) {
    let mut max_width = text_width(title);
    let mut line_count = 0_u16;
    for line in lines {
        max_width = max_width.max(text_width(line));
        line_count = line_count.saturating_add(1);
    }

    let width = max_width.saturating_add(4).clamp(18, 72).min(screen_width);
    let height = line_count.saturating_add(2).clamp(3, 12).min(screen_height);
    let below_row = anchor_row.saturating_add(1);
    let row = if below_row.saturating_add(height) <= screen_height {
        below_row
    } else {
        anchor_row.saturating_sub(height)
    };
    let col = anchor_col.min(screen_width.saturating_sub(width));
    (row, col, width, height)
}

fn highlight_signature_label(signature: &semantic::Signature, active_parameter: usize) -> String {
    let Some(parameter) = signature.parameters.get(active_parameter) else {
        return signature.label.clone();
    };
    if parameter.label.is_empty() {
        signature.label.clone()
    } else {
        signature
            .label
            .replace(&parameter.label, &format!("[{}]", parameter.label))
    }
}

fn completion_width(completion: &semantic::Completion) -> u16 {
    completion
        .items
        .iter()
        .map(|item| {
            text_width(&format!(
                "{} {}  {}",
                completion_kind_marker(item.kind),
                item.label,
                item.detail
            ))
        })
        .max()
        .unwrap_or(18)
        .saturating_add(2)
}

fn completion_kind_marker(kind: u8) -> &'static str {
    match kind {
        1 => "fn",
        2 => "me",
        3 => "var",
        4 => "fld",
        5 => "mod",
        7 => "kw",
        8 => "sn",
        9 => "cn",
        11 => "st",
        12 => "en",
        _ => "tx",
    }
}

fn ratatui_style_from_cell(style: CellStyle) -> RatatuiStyle {
    let mut out = RatatuiStyle::default();
    if style.fg != 0 {
        out = out.fg(ratatui_color_from_rgb(style.fg));
    }
    if style.bg != 0 {
        out = out.bg(ratatui_color_from_rgb(style.bg));
    }
    if style.attrs & protocol::ATTR_BOLD != 0 {
        out = out.add_modifier(Modifier::BOLD);
    }
    if style.attrs & protocol::ATTR_ITALIC != 0 {
        out = out.add_modifier(Modifier::ITALIC);
    }
    if style.attrs & protocol::ATTR_UNDERLINE != 0 {
        out = out.add_modifier(Modifier::UNDERLINED);
    }
    if style.attrs & protocol::ATTR_REVERSE != 0 {
        out = out.add_modifier(Modifier::REVERSED);
    }
    if style.attrs & protocol::ATTR_STRIKETHROUGH != 0 {
        out = out.add_modifier(Modifier::CROSSED_OUT);
    }
    out
}

fn ratatui_color_from_rgb(rgb: u32) -> RatatuiColor {
    RatatuiColor::Rgb(
        ((rgb >> 16) & 0xFF) as u8,
        ((rgb >> 8) & 0xFF) as u8,
        (rgb & 0xFF) as u8,
    )
}

fn cell_style_from_ratatui(cell: &ratatui::buffer::Cell) -> CellStyle {
    CellStyle {
        fg: rgb_from_ratatui(cell.fg),
        bg: rgb_from_ratatui(cell.bg),
        attrs: attrs_from_modifier(cell.modifier),
        ul_color: 0,
        blend: 100,
    }
}

fn rgb_from_ratatui(color: RatatuiColor) -> u32 {
    match color {
        RatatuiColor::Rgb(r, g, b) => ((r as u32) << 16) | ((g as u32) << 8) | b as u32,
        RatatuiColor::Black => 0x000000,
        RatatuiColor::Red => 0xFF5555,
        RatatuiColor::Green => 0x50FA7B,
        RatatuiColor::Yellow => 0xF1FA8C,
        RatatuiColor::Blue => 0xBD93F9,
        RatatuiColor::Magenta => 0xFF79C6,
        RatatuiColor::Cyan => 0x8BE9FD,
        RatatuiColor::Gray => 0x808080,
        RatatuiColor::DarkGray => 0x404040,
        RatatuiColor::LightRed => 0xFF6E6E,
        RatatuiColor::LightGreen => 0x69FF94,
        RatatuiColor::LightYellow => 0xFFFFA5,
        RatatuiColor::LightBlue => 0xD6ACFF,
        RatatuiColor::LightMagenta => 0xFF92DF,
        RatatuiColor::LightCyan => 0xA4FFFF,
        RatatuiColor::White => 0xFFFFFF,
        _ => 0,
    }
}

fn attrs_from_modifier(modifier: Modifier) -> u16 {
    let mut attrs = 0;
    if modifier.contains(Modifier::BOLD) {
        attrs |= protocol::ATTR_BOLD;
    }
    if modifier.contains(Modifier::ITALIC) {
        attrs |= protocol::ATTR_ITALIC;
    }
    if modifier.contains(Modifier::UNDERLINED) {
        attrs |= protocol::ATTR_UNDERLINE;
    }
    if modifier.contains(Modifier::REVERSED) {
        attrs |= protocol::ATTR_REVERSE;
    }
    if modifier.contains(Modifier::CROSSED_OUT) {
        attrs |= protocol::ATTR_STRIKETHROUGH;
    }
    attrs
}

fn git_marker(status: u8) -> &'static str {
    match status {
        1 => " M",
        2 => " S",
        3 => " ?",
        4 => " !",
        5 => " R",
        6 => " D",
        _ => "",
    }
}

fn diagnostic_marker((errors, warnings, info, hints): (u16, u16, u16, u16)) -> &'static str {
    if errors > 0 {
        " E"
    } else if warnings > 0 {
        " W"
    } else if info > 0 {
        " I"
    } else if hints > 0 {
        " H"
    } else {
        ""
    }
}

fn join_status_segments(segments: &[semantic::StatusSegment]) -> String {
    segments
        .iter()
        .filter(|segment| !segment.text.is_empty())
        .map(|segment| segment.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
}

fn fallback_status_left(status: &semantic::StatusBar) -> String {
    let mode = match status.mode {
        1 => "INSERT",
        2 => "VISUAL",
        3 => "COMMAND",
        4 => "OP",
        5 => "SEARCH",
        6 => "REPLACE",
        _ => "NORMAL",
    };
    let dirty = if status.flags & 0x04 != 0 { " +" } else { "" };

    if status.filename.is_empty() {
        format!("{mode}{dirty}")
    } else {
        format!("{mode} {}{dirty}", status.filename)
    }
}

fn fallback_status_right(status: &semantic::StatusBar) -> String {
    let mut parts = Vec::new();

    if !status.branch.is_empty() {
        parts.push(format!("git:{}", status.branch));
    }
    if !status.filetype.is_empty() {
        parts.push(status.filetype.clone());
    }
    if status.line_count > 0 {
        parts.push(format!(
            "{}:{} / {}",
            status.line, status.col, status.line_count
        ));
    }
    if !status.message.is_empty() {
        parts.push(status.message.clone());
    }

    parts.join(" ")
}

fn pad_to_width(text: &str, width: u16) -> String {
    let current = text_width(text);
    if current >= width {
        return slice_chars(text, 0, width);
    }

    format!("{text}{}", " ".repeat((width - current) as usize))
}

fn slice_chars(text: &str, start_col: u16, end_col: u16) -> String {
    let start = start_col as usize;
    let len = end_col.saturating_sub(start_col) as usize;
    text.chars().skip(start).take(len).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn applies_region_offset() {
        let mut renderer = Renderer::new(10, 5);
        renderer
            .handle(
                Command::DefineRegion(Region {
                    id: 1,
                    parent_id: 0,
                    role: 0,
                    row: 2,
                    col: 3,
                    width: 4,
                    height: 2,
                    z_order: 0,
                }),
                &mut Terminal::memory(10, 5),
                &mut Vec::new(),
            )
            .unwrap();
        renderer
            .handle(
                Command::SetActiveRegion(1),
                &mut Terminal::memory(10, 5),
                &mut Vec::new(),
            )
            .unwrap();
        renderer.draw_text(DrawText {
            row: 0,
            col: 0,
            fg: 1,
            bg: 2,
            attrs: 0,
            text: "x".to_owned(),
        });

        let index = renderer.index(3, 2).unwrap();
        assert_eq!(renderer.cells[index].text, "x");
    }

    #[test]
    fn resize_rebuilds_grid_and_clears_regions() {
        let mut renderer = Renderer::new(10, 5);
        renderer.regions.insert(
            1,
            Region {
                id: 1,
                parent_id: 0,
                role: 0,
                row: 0,
                col: 0,
                width: 2,
                height: 2,
                z_order: 0,
            },
        );
        renderer.active_region = renderer.regions.get(&1).copied();

        renderer.resize(4, 3);

        assert_eq!(renderer.width, 4);
        assert_eq!(renderer.height, 3);
        assert_eq!(renderer.cells.len(), 12);
        assert!(renderer.regions.is_empty());
        assert!(renderer.active_region.is_none());
    }

    #[test]
    fn semantic_window_uses_geometry_origin() {
        let mut renderer = Renderer::new(12, 5);

        renderer.draw_semantic_window(semantic::WindowContent {
            origin_row: 1,
            origin_col: 2,
            cursor_row: 0,
            cursor_col: 1,
            cursor_shape: 2,
            rows: vec![semantic::Row {
                text: "hello".to_owned(),
                spans: vec![semantic::Span {
                    start_col: 0,
                    end_col: 5,
                    fg: 0xAABBCC,
                    bg: 0,
                    attrs: 0,
                }],
            }],
        });

        assert_eq!(renderer.cursor, (3, 1));
        let index = renderer.index(2, 1).unwrap();
        assert_eq!(renderer.cells[index].text, "h");
        assert_eq!(renderer.cells[index].style.fg, 0xAABBCC);
    }

    #[test]
    fn semantic_chrome_draws_tabs_and_status() {
        let mut renderer = Renderer::new(30, 4);

        renderer.draw_tab_bar(semantic::TabBar {
            active_index: 0,
            tabs: vec![semantic::Tab {
                active: true,
                dirty: true,
                label: "main.ex".to_owned(),
                tint: 0,
            }],
        });
        renderer.draw_status_bar(semantic::StatusBar {
            mode: 1,
            filename: "main.ex".to_owned(),
            filetype: "elixir".to_owned(),
            line: 12,
            col: 4,
            line_count: 99,
            ..semantic::StatusBar::default()
        });

        assert_eq!(renderer.cells[renderer.index(1, 0).unwrap()].text, "m");
        assert_eq!(renderer.cells[renderer.index(0, 3).unwrap()].text, "I");
    }

    #[test]
    fn semantic_file_tree_draws_rows_and_selection_updates() {
        let mut renderer = Renderer::new(24, 6);

        renderer.draw_file_tree(semantic::FileTree {
            visible: true,
            focused: true,
            status: 3,
            selected_id: "a".to_owned(),
            root_path: "/tmp".to_owned(),
            width: 12,
            error: String::new(),
            rows: vec![
                semantic::FileTreeRow {
                    id: "a".to_owned(),
                    name: "src".to_owned(),
                    icon: "D".to_owned(),
                    depth: 0,
                    flags: 0x17,
                    git_status: 0,
                    diagnostics: (0, 0, 0, 0),
                    editing_text: String::new(),
                },
                semantic::FileTreeRow {
                    id: "b".to_owned(),
                    name: "main.rs".to_owned(),
                    icon: "R".to_owned(),
                    depth: 1,
                    flags: 0,
                    git_status: 1,
                    diagnostics: (0, 1, 0, 0),
                    editing_text: String::new(),
                },
            ],
        });

        assert_eq!(renderer.cells[renderer.index(1, 1).unwrap()].text, "v");
        let selected_bg = renderer.cells[renderer.index(0, 1).unwrap()].style.bg;

        renderer.update_file_tree_selection(semantic::FileTreeSelection {
            focused: false,
            selected_id: "b".to_owned(),
        });

        assert_ne!(
            renderer.cells[renderer.index(0, 1).unwrap()].style.bg,
            selected_bg
        );
        assert_eq!(renderer.cells[renderer.index(5, 2).unwrap()].text, "R");
    }

    #[test]
    fn semantic_picker_draws_split_overlay() {
        let mut renderer = Renderer::new(80, 20);

        renderer.draw_picker(semantic::Picker {
            visible: true,
            selected_index: 1,
            filtered_count: 2,
            total_count: 9,
            marked_count: 0,
            has_preview: true,
            title: "Files".to_owned(),
            query: "lib".to_owned(),
            mode_prefix: ">".to_owned(),
            load_status: 0,
            load_error: String::new(),
            items: vec![
                semantic::PickerItem {
                    label: "mix.exs".to_owned(),
                    description: ".".to_owned(),
                    annotation: "root".to_owned(),
                    icon_color: 0,
                    marked: false,
                },
                semantic::PickerItem {
                    label: "lib.ex".to_owned(),
                    description: "lib/minga".to_owned(),
                    annotation: "modified".to_owned(),
                    icon_color: 0,
                    marked: false,
                },
            ],
        });
        renderer.draw_picker_preview(semantic::PickerPreview {
            visible: true,
            lines: vec![vec![semantic::PreviewSegment {
                text: "defmodule Minga".to_owned(),
                fg: 0xAABBCC,
                bold: true,
            }]],
        });

        assert_eq!(renderer.cells[renderer.index(2, 2).unwrap()].text, ">");
        assert_eq!(renderer.cells[renderer.index(4, 3).unwrap()].text, "l");
        assert_eq!(renderer.cells[renderer.index(4, 5).unwrap()].text, "l");
        assert_eq!(
            renderer.cells[renderer.index(4, 5).unwrap()].style.bg,
            0x3B4252
        );
        assert_eq!(renderer.cells[renderer.index(41, 4).unwrap()].text, "d");
        assert_eq!(
            renderer.cells[renderer.index(41, 4).unwrap()].style.fg,
            0xAABBCC
        );
    }

    #[test]
    fn semantic_picker_hide_restores_underlying_cells() {
        let mut renderer = Renderer::new(80, 20);
        renderer.draw_text(DrawText {
            row: 4,
            col: 4,
            fg: 0x111111,
            bg: 0x222222,
            attrs: 0,
            text: "under".to_owned(),
        });

        renderer.draw_picker(semantic::Picker {
            visible: true,
            selected_index: 0,
            filtered_count: 1,
            total_count: 1,
            marked_count: 0,
            has_preview: false,
            title: "Files".to_owned(),
            query: String::new(),
            mode_prefix: String::new(),
            load_status: 0,
            load_error: String::new(),
            items: vec![semantic::PickerItem {
                label: "main.ex".to_owned(),
                description: String::new(),
                annotation: String::new(),
                icon_color: 0,
                marked: false,
            }],
        });
        assert_ne!(renderer.cells[renderer.index(4, 4).unwrap()].text, "u");

        renderer.draw_picker(semantic::Picker::default());

        let restored = &renderer.cells[renderer.index(4, 4).unwrap()];
        assert_eq!(restored.text, "u");
        assert_eq!(restored.style.fg, 0x111111);
        assert_eq!(restored.style.bg, 0x222222);
    }

    #[test]
    fn semantic_window_redraw_replays_retained_picker() {
        let mut renderer = Renderer::new(80, 20);

        renderer.draw_semantic_window(semantic::WindowContent {
            origin_row: 4,
            origin_col: 4,
            cursor_row: 0,
            cursor_col: 0,
            cursor_shape: 0,
            rows: vec![semantic::Row {
                text: "old".to_owned(),
                spans: vec![],
            }],
        });
        renderer.draw_picker(semantic::Picker {
            visible: true,
            selected_index: 0,
            filtered_count: 1,
            total_count: 1,
            marked_count: 0,
            has_preview: false,
            title: "Files".to_owned(),
            query: String::new(),
            mode_prefix: String::new(),
            load_status: 0,
            load_error: String::new(),
            items: vec![semantic::PickerItem {
                label: "main.ex".to_owned(),
                description: String::new(),
                annotation: String::new(),
                icon_color: 0,
                marked: false,
            }],
        });

        renderer.draw_semantic_window(semantic::WindowContent {
            origin_row: 4,
            origin_col: 4,
            cursor_row: 0,
            cursor_col: 0,
            cursor_shape: 0,
            rows: vec![semantic::Row {
                text: "new".to_owned(),
                spans: vec![],
            }],
        });

        assert_ne!(renderer.cells[renderer.index(4, 4).unwrap()].text, "n");

        renderer.draw_picker(semantic::Picker::default());

        assert_eq!(renderer.cells[renderer.index(4, 4).unwrap()].text, "n");
    }

    #[test]
    fn semantic_minibuffer_draws_prompt_candidates_and_cursor() {
        let mut renderer = Renderer::new(40, 10);

        renderer.draw_minibuffer(semantic::Minibuffer {
            visible: true,
            mode: 0,
            cursor_pos: 1,
            prompt: ":".to_owned(),
            input: "w".to_owned(),
            context: String::new(),
            selected_index: 1,
            total_candidates: 2,
            candidates: vec![
                semantic::MinibufferCandidate {
                    label: "write".to_owned(),
                    description: "Save file".to_owned(),
                    annotation: ":w".to_owned(),
                },
                semantic::MinibufferCandidate {
                    label: "write-quit".to_owned(),
                    description: "Save and quit".to_owned(),
                    annotation: ":wq".to_owned(),
                },
            ],
        });

        assert_eq!(renderer.cells[renderer.index(0, 8).unwrap()].text, ":");
        assert_eq!(renderer.cells[renderer.index(1, 8).unwrap()].text, "w");
        assert_eq!(renderer.cursor, (2, 8));
        assert_eq!(renderer.cells[renderer.index(0, 7).unwrap()].text, ">");
        assert_eq!(renderer.cells[renderer.index(2, 7).unwrap()].text, "w");
        assert_eq!(
            renderer.cells[renderer.index(0, 7).unwrap()].style.bg,
            0x4C566A
        );
    }

    #[test]
    fn semantic_minibuffer_scrolls_candidates_to_selection() {
        let mut renderer = Renderer::new(40, 10);

        renderer.draw_minibuffer(semantic::Minibuffer {
            visible: true,
            mode: 0,
            cursor_pos: 1,
            prompt: ":".to_owned(),
            input: "b".to_owned(),
            context: String::new(),
            selected_index: 5,
            total_candidates: 6,
            candidates: (0..6)
                .map(|index| semantic::MinibufferCandidate {
                    label: format!("command-{index}"),
                    description: String::new(),
                    annotation: String::new(),
                })
                .collect(),
        });

        assert_eq!(renderer.cells[renderer.index(2, 3).unwrap()].text, "c");
        assert_eq!(renderer.cells[renderer.index(10, 3).unwrap()].text, "1");
        assert_eq!(renderer.cells[renderer.index(0, 7).unwrap()].text, ">");
        assert_eq!(renderer.cells[renderer.index(10, 7).unwrap()].text, "5");
        assert_eq!(
            renderer.cells[renderer.index(0, 7).unwrap()].style.bg,
            0x4C566A
        );
    }

    #[test]
    fn semantic_minibuffer_hide_restores_owned_rows() {
        let mut renderer = Renderer::new(40, 10);
        renderer.draw_text(DrawText {
            row: 8,
            col: 0,
            fg: 0x111111,
            bg: 0x222222,
            attrs: 0,
            text: "status".to_owned(),
        });
        renderer.draw_text(DrawText {
            row: 7,
            col: 0,
            fg: 0x333333,
            bg: 0x444444,
            attrs: 0,
            text: "candidate".to_owned(),
        });

        renderer.draw_minibuffer(semantic::Minibuffer {
            visible: true,
            mode: 0,
            cursor_pos: 1,
            prompt: ":".to_owned(),
            input: "w".to_owned(),
            context: String::new(),
            selected_index: 0,
            total_candidates: 1,
            candidates: vec![semantic::MinibufferCandidate {
                label: "write".to_owned(),
                description: "Save file".to_owned(),
                annotation: ":w".to_owned(),
            }],
        });
        assert_eq!(renderer.cells[renderer.index(0, 8).unwrap()].text, ":");
        assert_eq!(renderer.cells[renderer.index(0, 7).unwrap()].text, ">");

        renderer.draw_minibuffer(semantic::Minibuffer::default());

        let prompt = &renderer.cells[renderer.index(0, 8).unwrap()];
        assert_eq!(prompt.text, "s");
        assert_eq!(prompt.style.fg, 0x111111);
        assert_eq!(prompt.style.bg, 0x222222);

        let candidate = &renderer.cells[renderer.index(0, 7).unwrap()];
        assert_eq!(candidate.text, "c");
        assert_eq!(candidate.style.fg, 0x333333);
        assert_eq!(candidate.style.bg, 0x444444);
    }

    #[test]
    fn semantic_minibuffer_visible_update_clears_stale_candidates() {
        let mut renderer = Renderer::new(40, 10);

        renderer.draw_minibuffer(semantic::Minibuffer {
            visible: true,
            mode: 0,
            cursor_pos: 1,
            prompt: ":".to_owned(),
            input: "w".to_owned(),
            context: String::new(),
            selected_index: 0,
            total_candidates: 1,
            candidates: vec![semantic::MinibufferCandidate {
                label: "write".to_owned(),
                description: "Save file".to_owned(),
                annotation: ":w".to_owned(),
            }],
        });
        assert_eq!(renderer.cells[renderer.index(0, 7).unwrap()].text, ">");

        renderer.draw_minibuffer(semantic::Minibuffer {
            visible: true,
            mode: 0,
            cursor_pos: 2,
            prompt: ":".to_owned(),
            input: "zz".to_owned(),
            context: String::new(),
            selected_index: 0,
            total_candidates: 0,
            candidates: vec![],
        });

        assert_eq!(renderer.cells[renderer.index(0, 7).unwrap()].text, " ");
        assert_eq!(renderer.cells[renderer.index(2, 7).unwrap()].text, " ");
        assert_eq!(renderer.cells[renderer.index(0, 8).unwrap()].text, ":");
        assert_eq!(renderer.cells[renderer.index(1, 8).unwrap()].text, "z");
    }

    #[test]
    fn semantic_minibuffer_no_cursor_sentinel_preserves_existing_cursor() {
        let mut renderer = Renderer::new(40, 10);
        renderer.cursor = (12, 3);

        renderer.draw_minibuffer(semantic::Minibuffer {
            visible: true,
            mode: 0,
            cursor_pos: u16::MAX,
            prompt: "Confirm?".to_owned(),
            input: String::new(),
            context: String::new(),
            selected_index: 0,
            total_candidates: 0,
            candidates: vec![],
        });

        assert_eq!(renderer.cursor, (12, 3));
        assert_eq!(renderer.cells[renderer.index(0, 8).unwrap()].text, "C");
    }

    #[test]
    fn semantic_window_redraw_replays_retained_minibuffer() {
        let mut renderer = Renderer::new(40, 10);

        renderer.draw_minibuffer(semantic::Minibuffer {
            visible: true,
            mode: 0,
            cursor_pos: 1,
            prompt: ":".to_owned(),
            input: "w".to_owned(),
            context: String::new(),
            selected_index: 0,
            total_candidates: 0,
            candidates: vec![],
        });

        renderer.draw_semantic_window(semantic::WindowContent {
            origin_row: 8,
            origin_col: 0,
            cursor_row: 0,
            cursor_col: 0,
            cursor_shape: 0,
            rows: vec![semantic::Row {
                text: "under".to_owned(),
                spans: vec![],
            }],
        });

        assert_eq!(renderer.cells[renderer.index(0, 8).unwrap()].text, ":");

        renderer.draw_minibuffer(semantic::Minibuffer::default());

        assert_eq!(renderer.cells[renderer.index(0, 8).unwrap()].text, "u");
    }

    #[test]
    fn semantic_completion_draws_and_restores_overlay() {
        let mut renderer = Renderer::new(40, 10);
        renderer.draw_text(DrawText {
            row: 4,
            col: 5,
            fg: 0x111111,
            bg: 0x222222,
            attrs: 0,
            text: "under".to_owned(),
        });

        renderer.draw_completion(semantic::Completion {
            visible: true,
            anchor_row: 3,
            anchor_col: 5,
            selected_index: 1,
            items: vec![
                semantic::CompletionItem {
                    kind: 1,
                    label: "write".to_owned(),
                    detail: "Save file".to_owned(),
                },
                semantic::CompletionItem {
                    kind: 5,
                    label: "Minga".to_owned(),
                    detail: "module".to_owned(),
                },
            ],
        });

        assert_eq!(renderer.cells[renderer.index(5, 4).unwrap()].text, "f");
        assert_eq!(renderer.cells[renderer.index(9, 5).unwrap()].text, "M");
        assert_eq!(
            renderer.cells[renderer.index(5, 5).unwrap()].style.bg,
            0x3B4252
        );

        renderer.draw_completion(semantic::Completion::default());

        let restored = &renderer.cells[renderer.index(5, 4).unwrap()];
        assert_eq!(restored.text, "u");
        assert_eq!(restored.style.fg, 0x111111);
        assert_eq!(restored.style.bg, 0x222222);
    }

    #[test]
    fn semantic_window_redraw_replays_retained_completion_and_which_key() {
        let mut renderer = Renderer::new(60, 16);

        renderer.draw_completion(semantic::Completion {
            visible: true,
            anchor_row: 4,
            anchor_col: 4,
            selected_index: 0,
            items: vec![semantic::CompletionItem {
                kind: 1,
                label: "write".to_owned(),
                detail: String::new(),
            }],
        });
        renderer.draw_which_key(semantic::WhichKey {
            visible: true,
            prefix: "SPC".to_owned(),
            page: 0,
            page_count: 1,
            bindings: vec![semantic::WhichKeyBinding {
                kind: 0,
                key: "f".to_owned(),
                description: "Find file".to_owned(),
                icon: String::new(),
            }],
        });

        renderer.draw_semantic_window(semantic::WindowContent {
            origin_row: 5,
            origin_col: 4,
            cursor_row: 0,
            cursor_col: 0,
            cursor_shape: 0,
            rows: vec![semantic::Row {
                text: "under completion".to_owned(),
                spans: vec![],
            }],
        });

        assert_eq!(renderer.cells[renderer.index(4, 5).unwrap()].text, "f");
        assert_eq!(renderer.cells[renderer.index(3, 13).unwrap()].text, "S");
        assert_eq!(renderer.cells[renderer.index(5, 14).unwrap()].text, "f");
    }

    #[test]
    fn semantic_popups_render_with_ratatui_and_restore() {
        let mut renderer = Renderer::new(60, 16);
        renderer.draw_text(DrawText {
            row: 4,
            col: 5,
            fg: 0x111111,
            bg: 0x222222,
            attrs: 0,
            text: "under".to_owned(),
        });

        renderer.draw_signature_help(semantic::SignatureHelp {
            visible: true,
            anchor_row: 2,
            anchor_col: 4,
            active_signature: 0,
            active_parameter: 0,
            signatures: vec![semantic::Signature {
                label: "open(path)".to_owned(),
                documentation: "Open file".to_owned(),
                parameters: vec![semantic::SignatureParameter {
                    label: "path".to_owned(),
                    documentation: "File path".to_owned(),
                }],
            }],
        });

        assert_eq!(renderer.cells[renderer.index(5, 4).unwrap()].text, "o");

        renderer.draw_signature_help(semantic::SignatureHelp::default());

        let restored = &renderer.cells[renderer.index(5, 4).unwrap()];
        assert_eq!(restored.text, "u");
        assert_eq!(restored.style.fg, 0x111111);
        assert_eq!(restored.style.bg, 0x222222);

        renderer.draw_float_popup(semantic::FloatPopup {
            visible: true,
            width: 24,
            height: 5,
            title: "Docs".to_owned(),
            lines: vec!["alpha".to_owned(), "beta".to_owned()],
        });
        assert_eq!(renderer.cells[renderer.index(19, 6).unwrap()].text, "a");

        renderer.draw_hover_popup(semantic::HoverPopup {
            visible: true,
            anchor_row: 1,
            anchor_col: 8,
            focused: true,
            scroll_offset: 0,
            lines: vec![semantic::HoverLine {
                line_type: 0,
                segments: vec![semantic::HoverSegment {
                    style: 0,
                    fg: 0,
                    flags: 0,
                    text: "hover docs".to_owned(),
                }],
            }],
        });
        assert_eq!(renderer.cells[renderer.index(9, 3).unwrap()].text, "h");
    }

    #[test]
    fn semantic_theme_drives_picker_and_minibuffer_colors() {
        let mut renderer = Renderer::new(40, 12);

        renderer.apply_theme(semantic::Theme {
            slots: vec![
                semantic::ThemeSlot {
                    id: SLOT_POPUP_BG,
                    rgb: 0x010203,
                },
                semantic::ThemeSlot {
                    id: SLOT_POPUP_SEL_BG,
                    rgb: 0x040506,
                },
                semantic::ThemeSlot {
                    id: SLOT_POPUP_FG,
                    rgb: 0x070809,
                },
                semantic::ThemeSlot {
                    id: SLOT_POPUP_SEL_FG,
                    rgb: 0x0A0B0C,
                },
                semantic::ThemeSlot {
                    id: SLOT_MODELINE_BAR_BG,
                    rgb: 0x0D0E0F,
                },
            ],
        });
        renderer.draw_picker(semantic::Picker {
            visible: true,
            selected_index: 0,
            filtered_count: 1,
            total_count: 1,
            marked_count: 0,
            has_preview: false,
            title: "Files".to_owned(),
            query: String::new(),
            mode_prefix: String::new(),
            load_status: 0,
            load_error: String::new(),
            items: vec![semantic::PickerItem {
                label: "main.ex".to_owned(),
                description: String::new(),
                annotation: String::new(),
                icon_color: 0,
                marked: false,
            }],
        });
        renderer.draw_minibuffer(semantic::Minibuffer {
            visible: true,
            mode: 0,
            cursor_pos: 0,
            prompt: ":".to_owned(),
            input: String::new(),
            context: String::new(),
            selected_index: 0,
            total_candidates: 1,
            candidates: vec![semantic::MinibufferCandidate {
                label: "write".to_owned(),
                description: String::new(),
                annotation: String::new(),
            }],
        });

        assert_eq!(
            renderer.cells[renderer.index(2, 4).unwrap()].style.bg,
            0x040506
        );
        assert_eq!(
            renderer.cells[renderer.index(2, 4).unwrap()].style.fg,
            0x0A0B0C
        );
        assert_eq!(
            renderer.cells[renderer.index(0, 10).unwrap()].style.bg,
            0x0D0E0F
        );
        assert_eq!(
            renderer.cells[renderer.index(0, 9).unwrap()].style.bg,
            0x040506
        );
    }
}
