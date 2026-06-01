use crate::protocol::{self, Command, DrawStyledText, DrawText, Region};
use crate::semantic;
use crate::terminal::{CellStyle, Terminal};
use std::collections::HashMap;
use std::io::{self, Write};

#[derive(Debug, Clone, PartialEq, Eq)]
struct Cell {
    text: String,
    style: CellStyle,
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

        let style = CellStyle {
            fg: 0xD8DEE9,
            bg: 0x2E3440,
            attrs: protocol::ATTR_BOLD,
            ul_color: 0,
            blend: 100,
        };

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
            let bg = if tab.active { 0x3B4252 } else { 0x242933 };
            let fg = if tab.tint == 0 {
                0xD8DEE9
            } else {
                tab.tint & 0x00FF_FFFF
            };
            self.write_run(
                0,
                col,
                &label,
                CellStyle {
                    fg,
                    bg,
                    attrs: if tab.active { protocol::ATTR_BOLD } else { 0 },
                    ul_color: 0,
                    blend: 100,
                },
            );
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
                file_tree_style(false, tree.focused),
            );
        }

        match tree.status {
            1 => self.write_run(1, 0, " Loading...", file_tree_style(false, tree.focused)),
            2 => self.write_run(1, 0, " Empty", file_tree_style(false, tree.focused)),
            4 => {
                let message = if tree.error.is_empty() {
                    " File tree error".to_owned()
                } else {
                    format!(" {}", tree.error)
                };
                self.write_run(1, 0, &message, file_tree_style(false, tree.focused));
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
            file_tree_style(selected, focused),
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

fn file_tree_style(selected: bool, focused: bool) -> CellStyle {
    CellStyle {
        fg: if selected { 0xECEFF4 } else { 0xC7CED9 },
        bg: match (selected, focused) {
            (true, true) => 0x4C566A,
            (true, false) => 0x3B4252,
            (false, _) => 0x20242D,
        },
        attrs: if selected { protocol::ATTR_BOLD } else { 0 },
        ul_color: 0,
        blend: 100,
    }
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
}
