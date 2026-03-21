# GUI Chrome Protocol Specification

This document specifies the structured data protocol for native GUI frontends (SwiftUI, GTK4, etc.). It covers the wire format for GUI chrome opcodes, the `gui_action` input opcode, theme color slots, and the behavioral contract a GUI frontend must satisfy.

For the cell-grid rendering protocol (draw_text, set_cursor, clear, etc.), see [PROTOCOL.md](PROTOCOL.md). The GUI chrome protocol runs alongside the cell-grid protocol, not instead of it.

## Architecture Overview

Minga's rendering pipeline produces two types of output:

1. **Cell-grid commands** (opcodes 0x10-0x1B): draw_text, set_cursor, clear, batch_end, etc. These paint the editor content surface (buffer text, gutter, modeline for splits, minibuffer). In a TUI frontend, these go to the terminal. In a GUI frontend, these go to a Metal/OpenGL surface.

2. **GUI chrome commands** (opcodes 0x70-0x7F): structured data for native chrome elements (tab bar, file tree sidebar, status bar, bottom panel, which-key popup, cursorline, gutter, etc.). These are sent only to GUI frontends. A TUI frontend never sees them.

Both types are sent within the same render cycle. The BEAM sends cell-grid commands first (one `{:packet, 4}` message containing clear through batch_end), then GUI chrome commands as separate `{:packet, 4}` messages immediately after. GUI chrome commands are not inside the batch_end-terminated cell-grid frame.

## Capability Negotiation

When a frontend sends the `ready` event (opcode 0x03), it includes a capabilities payload:

```
ready: opcode(1) + width(2) + height(2) + caps_version(1) + caps_len(1) + caps_data
caps_data: frontend_type(1) + color_depth(1) + unicode_width(1) + image_support(1) + float_support(1) + text_rendering(1)
```

The `frontend_type` byte determines which protocol variant the BEAM uses:

| Value | Type | Description |
|-------|------|-------------|
| 0x00 | TUI | Terminal frontend, cell-grid only |
| 0x01 | native_gui | Native GUI (SwiftUI, GTK4), receives both cell-grid and GUI chrome |
| 0x02 | web | Web frontend (future) |

The BEAM checks `Capabilities.gui?` (true when `frontend_type == :native_gui`) to decide whether to send GUI chrome opcodes and whether to skip TUI-only chrome (file tree cell rendering, tab bar cell rendering, picker/which-key/completion cell overlays).

## GUI Render Opcodes (BEAM → Frontend)

GUI chrome opcodes live in the range 0x70-0x7F. GUI content opcodes (semantic buffer rendering) start at 0x80. Frontends can classify an opcode as GUI by checking `opcode >= 0x70`.

### 0x70 — gui_file_tree

File tree sidebar entries for the native sidebar view.

```
opcode(1) + selected_index(2) + tree_width(2) + entry_count(2) + root_len(2) + root(root_len) + entries...

Per entry:
  path_hash(4) + flags(1) + depth(1) + git_status(1) + icon_len(1) + icon(icon_len) + name_len(2) + name(name_len) + rel_path_len(2) + rel_path(rel_path_len)

Root: absolute project root path, sent once in the header.

Path hash: erlang:phash2 of the full file path, mod 2^32. Stable across tree
updates so GUI frontends can use it as a persistent view identity for diffing.

Rel path: path relative to root (e.g., "lib/minga/editor.ex"). GUI computes
full path as root + "/" + rel_path for context menu actions.

Flags bits:
  bit 0: is_dir
  bit 1: is_expanded (only meaningful when is_dir)
  bit 2: is_selected

Git status values:
  0 = none, 1 = modified, 2 = staged, 3 = untracked, 4 = conflict, 5 = ignored
```

When `entry_count == 0`, the file tree should be hidden.

### 0x71 — gui_tab_bar

Tab bar state with all open tabs.

```
opcode(1) + active_index(1) + tab_count(1) + entries...

Per entry:
  flags(1) + id(4) + icon_len(1) + icon(icon_len) + label_len(2) + label(label_len)

Flags bits:
  bit 0: is_active
  bit 1: is_dirty
  bit 2: is_agent (agent chat tab vs file tab)
  bit 3: has_attention
  bits 4-5: agent_status (0=idle, 1=thinking, 2=tool_executing, 3=error)
```

### 0x72 — gui_which_key

Which-key popup showing available keybindings after a prefix key.

```
visible byte: 0 = hidden, 1 = visible

When visible:
  opcode(1) + 1(1) + prefix_len(2) + prefix(prefix_len) + page(1) + page_count(1) + binding_count(2) + bindings...

Per binding:
  kind(1) + key_len(1) + key(key_len) + desc_len(2) + desc(desc_len) + icon_len(1) + icon(icon_len)

Kind: 0 = command, 1 = group (prefix for more keys)

When hidden:
  opcode(1) + 0(1)
```

### 0x73 — gui_completion

Completion popup with LSP/buffer completion items.

```
When visible:
  opcode(1) + 1(1) + anchor_row(2) + anchor_col(2) + selected_index(2) + item_count(2) + items...

Per item:
  kind(1) + label_len(2) + label(label_len) + detail_len(2) + detail(detail_len)

Kind values:
  0 = unknown, 1 = function, 2 = method, 3 = variable, 4 = field,
  5 = module, 7 = keyword, 8 = snippet, 9 = constant, 11 = struct, 12 = enum

When hidden:
  opcode(1) + 0(1)
```

`anchor_row` and `anchor_col` are the screen coordinates of the cursor at the time of completion, for positioning the popup.

### 0x74 — gui_theme

Theme color slots for styling native chrome views.

```
opcode(1) + count(1) + slots...

Per slot:
  slot_id(1) + r(1) + g(1) + b(1)
```

Sent when the theme changes. The frontend should apply these colors to all chrome views. See the "Theme Color Slots" section below for the full slot ID table.

### 0x75 — gui_breadcrumb

Path breadcrumb showing the file location of the active buffer.

```
When visible:
  opcode(1) + segment_count(1) + segments...

Per segment:
  seg_len(2) + seg(seg_len)

When nil (no file):
  opcode(1) + 0(1)
```

Segments are the path components relative to the project root. For example, `lib/minga/editor.ex` produces `["lib", "minga", "editor.ex"]`.

### 0x76 — gui_status_bar

Status bar data for the focused window. The first byte after the opcode is `content_kind`:
- `0` — buffer window: show file info, cursor position, git, diagnostics.
- `1` — agent chat window: show model name, message count, session status.

**Buffer variant (content_kind == 0):**
```
opcode(1) + content_kind=0(1) + mode(1) + cursor_line(4) + cursor_col(4) + line_count(4)
+ flags(1) + lsp_status(1) + git_branch_len(1) + git_branch(git_branch_len)
+ message_len(2) + message(message_len) + filetype_len(1) + filetype(filetype_len)
+ error_count(2) + warning_count(2)
-- Extended fields (TUI modeline parity) --
+ info_count(2) + hint_count(2)
+ macro_recording(1) + parser_status(1) + agent_status(1)
+ git_added(2) + git_modified(2) + git_deleted(2)
+ icon_len(1) + icon(icon_len) + icon_color_r(1) + icon_color_g(1) + icon_color_b(1)
+ filename_len(2) + filename(filename_len)
```

**Agent variant (content_kind == 1):**
```
opcode(1) + content_kind=1(1) + mode(1)
+ zeros(4) + zeros(4) + zeros(4)          <- shared header slots, all zero for agent
+ zeros(1) + zeros(1) + zeros(1) + zeros(2) + zeros(1) + zeros(2) + zeros(2)
+ model_name_len(1) + model_name(model_name_len)
+ message_count(4) + session_status(1)
```

`cursor_line` and `cursor_col` are 1-indexed on the wire.

Mode values: 0=normal, 1=insert, 2=visual, 3=command, 4=operator_pending, 5=search, 6=replace

Flags bits: bit 0=has_lsp, bit 1=has_git, bit 2=is_dirty

LSP status: 0=none, 1=ready, 2=initializing, 3=starting, 4=error

Parser status: 0=available, 1=unavailable, 2=restarting

Agent status: 0=idle, 1=thinking, 2=tool_executing, 3=error

Session status (agent variant): 0=idle, 1=thinking, 2=tool_executing, 3=error

Macro recording: 0=not recording, 1-26=recording register a-z

`icon` is a UTF-8 encoded Nerd Font glyph for the filetype (e.g., "" for Elixir). `icon_color` is 24-bit RGB split into 3 bytes. `filename` is the display name of the active buffer (for accessibility/tooltip use). `git_added`, `git_modified`, `git_deleted` are line counts from the buffer's diff against HEAD.

### 0x77 — gui_picker

Fuzzy finder / command palette state (v2 extended format).

```
When visible:
  opcode(1) + 1(1) + selected_index(2) + filtered_count(2) + total_count(2)
  + title_len(2) + title(title_len) + query_len(2) + query(query_len)
  + has_preview(1) + item_count(2) + items...

Per item:
  icon_color(3) + flags(1) + label_len(2) + label(label_len)
  + desc_len(2) + desc(desc_len) + annotation_len(2) + annotation(annotation_len)
  + match_pos_count(1) + match_positions(match_pos_count * 2)

After all items, action menu:
  action_visible(1)
  When action_visible == 1:
    selected_action(1) + action_count(1) + actions...
    Per action: name_len(2) + name(name_len)

icon_color is a 24-bit RGB value for the item's icon.
flags bits:
  bit 0: two_line (render description on second line)
  bit 1: marked (multi-select checkmark)
annotation is a right-aligned string (e.g., keybinding "SPC f s").
match_positions is a list of uint16 character indices for highlighting matched characters.
has_preview indicates whether the picker source supports preview (triggers split layout).
filtered_count and total_count enable "X/Y" display in the search field.
action menu shows source-specific actions (e.g., "Open", "Delete", "Open in split").

When hidden:
  opcode(1) + 0(1)
```

### 0x7D — gui_picker_preview

Preview content for the currently selected picker item. Sent alongside gui_picker when has_preview is true.

```
When visible:
  opcode(1) + 1(1) + line_count(2) + lines...

Per line:
  segment_count(1) + segments...

Per segment:
  fg_color(3) + flags(1) + text_len(2) + text(text_len)

flags bits:
  bit 0: bold

When hidden:
  opcode(1) + 0(1)
```

### 0x78 — gui_agent_chat

Agent conversation view state.

```
When visible:
  opcode(1) + 1(1) + status(1) + model_len(2) + model(model_len) + prompt_len(2) + prompt(prompt_len) + pending_approval + message_count(2) + messages...

Status values: 0 = idle, 1 = thinking, 2 = tool_executing, 3 = error

Pending approval:
  0(1) — no pending approval
  1(1) + name_len(2) + name(name_len) + summary_len(2) + summary(summary_len)

Per message (type byte first):
  0x01 (user):      type(1) + text_len(4) + text
  0x02 (assistant):  type(1) + text_len(4) + text
  0x03 (thinking):   type(1) + collapsed(1) + text_len(4) + text
  0x04 (tool_call):  type(1) + status(1) + error(1) + collapsed(1) + duration_ms(4) + name_len(2) + name + result_len(4) + result
  0x05 (system):     type(1) + level(1) + text_len(4) + text
  0x06 (usage):      type(1) + input(4) + output(4) + cache_read(4) + cache_write(4) + cost_micros(4)

When hidden:
  opcode(1) + 0(1)
```

### 0x79 — gui_gutter_separator

Gutter separator column position and color.

```
opcode(1) + col(2) + r(1) + g(1) + b(1)
```

`col` is the cell column at the right edge of the gutter (0 = no separator visible). Color is 24-bit RGB.

### 0x7A — gui_cursorline

Cursorline highlight row and background color for native rendering.

```
opcode(1) + row(2) + r(1) + g(1) + b(1)
```

`row` is the 0-indexed screen row where the cursorline should be drawn. `row = 0xFFFF` means no cursorline (disabled or inactive window). Color is 24-bit RGB.

The GUI frontend draws the cursorline as a full-width colored rectangle behind the text on this row. This replaces the TUI approach of prepending a full-width space fill draw to paint the background.

### 0x7B — gui_gutter

Structured gutter data for native line number and sign rendering. One message is sent per editor window (split pane), each including the window's screen position. Agent chat windows are skipped.

```
opcode(1) + window_id(2) + content_row(2) + content_col(2) + content_height(2) + is_active(1)
+ cursor_line(4) + line_number_style(1) + line_number_width(1)
+ sign_col_width(1) + line_count(2) + entries...

Per entry:
  buf_line(4) + display_type(1) + sign_type(1)
```

`window_id` matches the `window_id` field in `gui_window_content` (0x80), enabling the frontend to correlate gutter data with semantic buffer content for the same window. `content_row` and `content_col` are the screen position of the window's content area (0-indexed). `content_height` is the height in rows. `is_active` is 1 for the focused window, 0 otherwise. `cursor_line` is the 0-indexed buffer line where the cursor sits. `line_number_width` is the character column count allocated for line numbers. `sign_col_width` is 0 (no sign column) or 2 (sign column present). `line_count` is the number of visible line entries.

Line number style values:
| Value | Style |
|-------|-------|
| 0 | hybrid (relative + absolute on cursor line) |
| 1 | absolute |
| 2 | relative |
| 3 | none (line numbers hidden) |

Display type values:
| Value | Type |
|-------|------|
| 0 | normal line |
| 1 | fold start |
| 2 | fold continuation |
| 3 | wrap continuation |

Sign type values:
| Value | Sign |
|-------|------|
| 0 | none |
| 1 | git added |
| 2 | git modified |
| 3 | git deleted |
| 4 | diagnostic error |
| 5 | diagnostic warning |
| 6 | diagnostic info |
| 7 | diagnostic hint |

Diagnostics take priority over git signs (same line shows only the highest-priority sign). The GUI frontend renders line numbers natively using its font engine, computing relative/absolute display from `buf_line` and `cursor_line`. Git signs are drawn as colored bars; diagnostic signs as colored text characters.

When this opcode is sent, the BEAM strips `WindowFrame.gutter` from the cell-grid frame output, so no draw_text commands are sent for gutter content. The TUI rendering path is unaffected.

### 0x7C — gui_bottom_panel

Bottom panel container state (resizable, tabbed panel below editor surface).

```
When visible:
  opcode(1) + 1(1) + active_tab_index(1) + height_percent(1) + filter_preset(1) + tab_count(1) + tab_defs... + content_payload

Per tab_def:
  tab_type(1) + name_len(1) + name(name_len)

Tab type values:
  0x01 = messages, 0x02 = diagnostics (future), 0x03 = terminal (future)

Filter preset values:
  0x00 = none (user controls filters), 0x01 = warnings (preset to warnings+errors)

Messages content_payload (when active tab is messages):
  entry_count(2) + entries...

Per entry:
  id(4) + level(1) + subsystem(1) + timestamp_secs(4) + path_len(2) + path(path_len) + text_len(2) + text(text_len)

Level bytes: 0=debug, 1=info, 2=warning, 3=error
Subsystem bytes: 0=editor, 1=lsp, 2=parser, 3=git, 4=render, 5=agent, 6=zig, 7=gui

Entries are sent incrementally: the BEAM tracks the last sent ID and only sends new entries each frame. On first connection (or reconnect), all entries are sent.

When hidden:
  opcode(1) + 0(1)
```

`height_percent` is the BEAM's default/initial height (10-60). The frontend may override with a user-dragged height stored locally.

`filter_preset` is a hint for the Messages tab. When the panel auto-opens for warnings, the BEAM sets `filter_preset=1`. The frontend should apply a warnings+errors level filter on the visibility transition (hidden to visible). If the user has already changed filters manually, don't override.

### 0x7E — gui_tool_manager

Tool manager panel for browsing, installing, updating, and uninstalling LSP servers and formatters.

```
When visible:
  opcode(1) + 1(1) + filter(1) + selected_index(2) + tool_count(2) + tools...

Per tool:
  name_len(1) + name(name_len) + label_len(1) + label(label_len)
  + desc_len(2) + desc(desc_len) + category(1) + status(1)
  + method(1) + language_count(1) + languages...
  + version_len(1) + version(version_len)
  + homepage_len(2) + homepage(homepage_len)
  + provides_count(1) + provides...
  + error_reason_len(2) + error_reason(error_reason_len)

Per language:
  lang_len(1) + lang(lang_len)

Per provides:
  cmd_len(1) + cmd(cmd_len)

When hidden:
  opcode(1) + 0(1)
```

Filter values:
| Value | Filter |
|-------|--------|
| 0 | all |
| 1 | installed |
| 2 | not_installed |
| 3 | lsp_servers |
| 4 | formatters |

Category values:
| Value | Category |
|-------|----------|
| 0 | lsp_server |
| 1 | formatter |
| 2 | linter |
| 3 | debugger |

Status values:
| Value | Status |
|-------|--------|
| 0 | not_installed |
| 1 | installed |
| 2 | installing |
| 3 | update_available |
| 4 | failed |

Method values:
| Value | Method |
|-------|--------|
| 0 | npm |
| 1 | pip |
| 2 | cargo |
| 3 | go_install |
| 4 | github_release |

### 0x7F — gui_minibuffer

Native minibuffer state with inline completion candidates. Replaces the cell-grid minibuffer row for GUI frontends. The input bar shows the prompt, typed text, and cursor; the candidate list (when present) expands above it.

```
When visible:
  opcode(1) + 1(1) + mode(1) + cursor_pos(2)
  + prompt_len(1) + prompt(prompt_len)
  + input_len(2) + input(input_len)
  + context_len(2) + context(context_len)
  + selected_index(2) + candidate_count(2) + candidates...

Per candidate:
  match_score(1) + label_len(2) + label(label_len) + desc_len(2) + desc(desc_len)

When hidden:
  opcode(1) + 0(1)
```

Mode values:

| Value | Mode | Prompt Example | Has Cursor | Context Example |
|-------|------|----------------|------------|-----------------|
| 0 | command | `:` | yes | (empty) |
| 1 | search_forward | `/` | yes | `"3 of 42"` |
| 2 | search_backward | `?` | yes | `"3 of 42"` |
| 3 | search_prompt | `"Search: "` | yes | (empty) |
| 4 | eval | `"Eval: "` | yes | (empty) |
| 5 | substitute_confirm | `"replace with foo?"` | no | `"y/n/a/q (2 of 15)"` |
| 6 | extension_confirm | (plugin prompt) | no | (empty) |
| 7 | describe_key | `"Press key: "` | no | (accumulated keys) |

`cursor_pos` is the 0-indexed character position within `input` for the beam cursor. `0xFFFF` means no cursor (prompt-only modes 5-7). `context` is right-aligned supplementary text. `match_score` is 0-255 fuzzy match quality. `candidate_count == 0` naturally represents "input visible, no completions."

### 0x80 — gui_window_content

Semantic rendering data for a buffer window. Replaces draw_text commands for buffer content. The BEAM pre-resolves all layout (word wrap, folding, virtual text splicing, conceal ranges) and all styling (syntax highlighting colors). The frontend renders directly from this data via CoreText, with selection/search/diagnostics as overlay quads (not baked into text colors).

One 0x80 message is sent per buffer window per frame. Agent chat windows do not use this opcode.

```
opcode(1) + window_id(2) + flags(1) + cursor_row(2) + cursor_col(2) + cursor_shape(1) + scroll_left(2) + visible_row_count(2) + rows... + selection + search_matches + diagnostic_ranges

Flags:
  bit 0: full_refresh (1 = all rows changed, 0 = incremental)

Cursor shape: 0 = block, 1 = beam, 2 = underline

scroll_left: horizontal scroll offset in display columns. When > 0, the frontend
shifts line textures and overlay quads left by scroll_left * cell_width so that
content past the viewport's left edge becomes visible. The gutter stays fixed.

Per visual row:
  row_type(1) + buf_line(4) + content_hash(4) + text_len(4) + text(text_len) + span_count(2) + spans...

Row types:
  0 = normal, 1 = fold_start, 2 = virtual_line, 3 = block_decoration, 4 = wrap_continuation

Per highlight span:
  start_col(2) + end_col(2) + fg(3) + bg(3) + attrs(1) + font_weight(1) + font_id(1)

Attrs bits: 0=bold, 1=italic, 2=underline, 3=strikethrough, 4=curl_underline

Span columns are in display column coordinates (CJK/fullwidth = 2 columns).
Colors are pre-resolved 24-bit RGB from the BEAM's theme/highlight resolver.

Selection section:
  selection_type(1): 0=none, 1=char, 2=line, 3=block
  If type != 0: start_row(2) + start_col(2) + end_row(2) + end_col(2)
  All coordinates are display-relative (within the window's content area).

Search matches section:
  match_count(2)
  Per match: row(2) + start_col(2) + end_col(2) + is_current(1)

Diagnostic ranges section:
  diag_count(2)
  Per range: start_row(2) + start_col(2) + end_row(2) + end_col(2) + severity(1)
  Severity: 0=error, 1=warning, 2=info, 3=hint
```

The frontend renders selection and search matches as Metal quads behind text (not baked into line textures). This enables zero re-rasterization when the selection changes. Diagnostic underlines are rendered as quads after text.

`content_hash` is a per-row hash computed by the BEAM. The frontend uses it for CTLine texture cache invalidation: if the hash matches, the cached texture is reused without re-rasterization.

When `gui_window_content` is present for a window, the BEAM does not send draw_text commands for that window's buffer content. Overlays (hover popups, signature help) continue as draw_text. Gutter data (0x7B), cursorline (0x7A), and cursor position continue through their existing opcodes.

## GUI Action Input Opcode (Frontend → BEAM)

The frontend sends user interactions with native chrome back to the BEAM using the `gui_action` opcode (0x07). This opcode lives in the input event range, not the GUI chrome range.

```
opcode(1) + action_type(1) + payload...
```

| Action Type | Name | Payload | Description |
|-------------|------|---------|-------------|
| 0x01 | select_tab | id(4) | User clicked a tab |
| 0x02 | close_tab | id(4) | User closed a tab |
| 0x03 | file_tree_click | index(2) | User clicked a file tree entry |
| 0x04 | file_tree_toggle | index(2) | User toggled a directory |
| 0x05 | completion_select | index(2) | User selected a completion item |
| 0x06 | breadcrumb_click | segment_index(1) | User clicked a breadcrumb segment |
| 0x07 | toggle_panel | panel(1) | User toggled a panel |
| 0x08 | new_tab | (empty) | User requested a new tab |
| 0x09 | panel_switch_tab | tab_index(1) | User clicked a bottom panel tab |
| 0x0A | panel_dismiss | (empty) | User dismissed the bottom panel |
| 0x0B | panel_resize | height_percent(1) | User resized the bottom panel |
| 0x0C | open_file | path_len(2) + path(path_len) | Open or switch to a file |
| 0x0D | file_tree_new_file | (empty) | Create new file at selected entry |
| 0x0E | file_tree_new_folder | (empty) | Create new folder at selected entry |
| 0x0F | file_tree_collapse_all | (empty) | Collapse all directories in tree |
| 0x10 | file_tree_refresh | (empty) | Refresh file tree |
| 0x11 | tool_install | name_len(2) + name(name_len) | Install a tool by name |
| 0x12 | tool_uninstall | name_len(2) + name(name_len) | Uninstall a tool by name |
| 0x13 | tool_update | name_len(2) + name(name_len) | Update a tool by name |
| 0x14 | tool_dismiss | (empty) | Dismiss the tool manager panel |

## Theme Color Slots

Theme colors are sent as `{slot_id, r, g, b}` tuples in the `gui_theme` opcode. The slot IDs are organized by UI domain:

The "Source" column shows which `Theme.t()` field each slot reads from (see `lib/minga/theme/slots.ex`). Slots that share a source will always have the same color value. Frontends that need fallback colors before the first `gui_theme` arrives can use the Doom One defaults listed below.

### Editor + Tree (0x01-0x0F)

| Slot | Name | Source | Usage |
|------|------|--------|-------|
| 0x01 | editor_bg | `editor.bg` | Editor content background |
| 0x02 | editor_fg | `editor.fg` | Editor content foreground |
| 0x03 | tree_bg | `tree.bg` | File tree sidebar background |
| 0x04 | tree_fg | `tree.fg` | File tree default text color |
| 0x05 | tree_selection_bg | `tree.cursor_bg` | Selected entry background |
| 0x06 | tree_dir_fg | `tree.dir_fg` | Directory name color |
| 0x07 | tree_active_fg | `tree.active_fg` | Currently open file highlight |
| 0x08 | tree_header_bg | `tree.header_bg` | Tree header background |
| 0x09 | tree_header_fg | `tree.header_fg` | Tree header text color |
| 0x0A | tree_separator_fg | `tree.separator_fg` | Tree border/separator color |
| 0x0B | tree_git_modified | `tree.git_modified_fg` | Modified file indicator |
| 0x0C | tree_git_staged | `tree.git_staged_fg` | Staged file indicator |
| 0x0D | tree_git_untracked | `tree.git_untracked_fg` | Untracked file indicator |
| 0x0E | tree_selection_fg | `editor.fg` | Selected entry foreground (same as editor fg) |
| 0x0F | tree_guide_fg | `tree.separator_fg` | Indentation guide (same as tree separator) |

### Tab Bar (0x10-0x17)

| Slot | Name | Source | Usage |
|------|------|--------|-------|
| 0x10 | tab_bg | `tab_bar.bg` | Tab bar background |
| 0x11 | tab_active_bg | `tab_bar.active_bg` | Active tab background |
| 0x12 | tab_active_fg | `tab_bar.active_fg` | Active tab text |
| 0x13 | tab_inactive_fg | `tab_bar.inactive_fg` | Inactive tab text |
| 0x14 | tab_modified_fg | `tab_bar.modified_fg` | Modified indicator color |
| 0x15 | tab_separator_fg | `tab_bar.separator_fg` | Tab separator color |
| 0x16 | tab_close_hover_fg | `tab_bar.close_hover_fg` | Close button hover color |
| 0x17 | tab_attention_fg | `tab_bar.attention_fg` | Attention indicator (agent activity) |

Tab bar slots are nil when the theme has no `tab_bar` section. Frontends should fall back to editor bg/fg.

### Popups + Breadcrumb (0x20-0x29)

| Slot | Name | Source | Usage |
|------|------|--------|-------|
| 0x20 | popup_bg | `popup.bg` | Popup background |
| 0x21 | popup_fg | `popup.fg` | Popup text |
| 0x22 | popup_border | `popup.border_fg` | Popup border |
| 0x23 | popup_sel_bg | `popup.sel_bg` | Selected item background |
| 0x24 | popup_key_fg | `popup.key_fg` | Key binding text color |
| 0x25 | popup_group_fg | `popup.group_fg` | Group heading color |
| 0x26 | popup_desc_fg | `popup.fg` | Description text (same as popup fg) |
| 0x27 | breadcrumb_bg | `modeline.bar_bg` | Breadcrumb bar bg (same as modeline) |
| 0x28 | breadcrumb_fg | `modeline.info_fg` | Breadcrumb text (same as modeline info) |
| 0x29 | breadcrumb_separator_fg | `tree.separator_fg` | Breadcrumb separator (same as tree separator) |

### Modeline + Status Bar (0x30-0x3A)

| Slot | Name | Source | Usage |
|------|------|--------|-------|
| 0x30 | modeline_bar_bg | `modeline.bar_bg` | Status bar background |
| 0x31 | modeline_bar_fg | `modeline.bar_fg` | Status bar text |
| 0x32 | modeline_info_bg | `modeline.info_bg` | Info section background |
| 0x33 | modeline_info_fg | `modeline.info_fg` | Info section text |
| 0x34 | mode_normal_bg | `modeline.mode_colors[:normal]` bg | Normal mode indicator bg |
| 0x35 | mode_normal_fg | `modeline.mode_colors[:normal]` fg | Normal mode indicator fg |
| 0x36 | mode_insert_bg | `modeline.mode_colors[:insert]` bg | Insert mode indicator bg |
| 0x37 | mode_insert_fg | `modeline.mode_colors[:insert]` fg | Insert mode indicator fg |
| 0x38 | mode_visual_bg | `modeline.mode_colors[:visual]` bg | Visual mode indicator bg |
| 0x39 | mode_visual_fg | `modeline.mode_colors[:visual]` fg | Visual mode indicator fg |
| 0x3A | statusbar_accent_fg | `tree.active_fg` | Accent for status segments (same as tree active) |

Mode color slots fall back to `modeline.bar_fg` / `modeline.bar_bg` when a mode isn't defined in the theme's `mode_colors` map.

### Accent (0x40)

| Slot | Name | Source | Usage |
|------|------|--------|-------|
| 0x40 | accent | `tree.active_fg` | Global accent color (same as tree active) |

### Gutter + Git (0x50-0x58)

| Slot | Name | Source | Usage |
|------|------|--------|-------|
| 0x50 | gutter_fg | `gutter.fg` | Line number foreground (non-current lines) |
| 0x51 | gutter_current_fg | `gutter.current_fg` | Current line number foreground |
| 0x52 | gutter_error_fg | `gutter.error_fg` | Diagnostic error sign color |
| 0x53 | gutter_warning_fg | `gutter.warning_fg` | Diagnostic warning sign color |
| 0x54 | gutter_info_fg | `gutter.info_fg` | Diagnostic info sign color |
| 0x55 | gutter_hint_fg | `gutter.hint_fg` | Diagnostic hint sign color |
| 0x56 | git_added_fg | `git.added_fg` | Git added sign color |
| 0x57 | git_modified_fg | `git.modified_fg` | Git modified sign color |
| 0x58 | git_deleted_fg | `git.deleted_fg` | Git deleted sign color |

## Behavioral Contract

A GUI frontend must satisfy these requirements:

1. **Send `ready` with `frontend_type = 0x01`** (native_gui) in the capabilities payload. This tells the BEAM to send GUI chrome opcodes.

2. **Render cell-grid commands to a pixel surface** (Metal, OpenGL, Vulkan). The BEAM sends editor content (buffer text, gutter, modeline for splits, minibuffer) as cell-grid commands. The GUI frontend must maintain a cell grid and render it to a texture/surface.

3. **Render GUI chrome natively.** Tab bar, file tree, status bar, breadcrumb, which-key, completion, picker, and agent chat should be rendered using native UI frameworks (SwiftUI, GTK4, Qt). Do not render them from the cell grid.

4. **Send `gui_action` events for user interactions with chrome.** When a user clicks a tab, selects a completion item, or toggles a panel, encode the action and send it to the BEAM on stdout.

5. **Handle missing opcodes gracefully.** New GUI opcodes may be added in the 0x70-0x7F range. Frontends should skip unknown opcodes rather than crashing.

6. **Process `gui_theme` before rendering other chrome.** The theme command typically arrives early in the first frame. Apply colors before rendering chrome elements to avoid a flash of unstyled content.

## Sequencing

Within a single render cycle (one `{:packet, 4}` framed batch):

1. Cell-grid commands: `clear`, `define_region`, `draw_text` (multiple), `set_cursor`, `set_cursor_shape`, `batch_end`
2. GUI chrome commands: `gui_theme` (if changed), `gui_tab_bar`, `gui_file_tree`, `gui_which_key`, `gui_completion`, `gui_breadcrumb`, `gui_status_bar`, `gui_picker`, `gui_agent_chat`, `gui_bottom_panel`

Note: GUI chrome commands are sent after `batch_end`. They are separate from the cell-grid frame because they update native UI state, not the pixel surface. The frontend should process them after committing the cell-grid frame to the GPU.

## Implementation References

### BEAM (canonical source of truth)

| Component | File | Language |
|-----------|------|----------|
| Encoder | `lib/minga/port/protocol/gui.ex` | Elixir |
| Theme slot mapping | `lib/minga/theme/slots.ex` | Elixir |
| Integration tests | `test/minga/integration/gui_protocol_test.exs` | Elixir |

### macOS GUI

| Component | File | Language |
|-----------|------|----------|
| Decoder | `macos/Sources/Protocol/ProtocolDecoder.swift` | Swift |
| Constants | `macos/Sources/Protocol/ProtocolConstants.swift` | Swift |
| Test harness | `macos/TestHarness/main.swift` | Swift |

### Linux GUI (planned)

The GTK4 frontend will need its own protocol decoder implementing the same opcodes. When building it, use the BEAM encoder and integration tests as the reference, not the Swift decoder (which may have platform-specific assumptions).
