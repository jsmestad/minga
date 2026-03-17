# GUI Chrome Protocol Specification

This document specifies the structured data protocol for native GUI frontends (SwiftUI, GTK4, etc.). It covers the wire format for GUI chrome opcodes, the `gui_action` input opcode, theme color slots, and the behavioral contract a GUI frontend must satisfy.

For the cell-grid rendering protocol (draw_text, set_cursor, clear, etc.), see [PROTOCOL.md](PROTOCOL.md). The GUI chrome protocol runs alongside the cell-grid protocol, not instead of it.

## Architecture Overview

Minga's rendering pipeline produces two types of output:

1. **Cell-grid commands** (opcodes 0x10-0x1B): draw_text, set_cursor, clear, batch_end, etc. These paint the editor content surface (buffer text, gutter, modeline for splits, minibuffer). In a TUI frontend, these go to the terminal. In a GUI frontend, these go to a Metal/OpenGL surface.

2. **GUI chrome commands** (opcodes 0x70-0x78): structured data for native chrome elements (tab bar, file tree sidebar, status bar, which-key popup, etc.). These are sent only to GUI frontends. A TUI frontend never sees them.

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

All GUI chrome opcodes live in the contiguous range 0x70-0x78. Frontends can classify an opcode as GUI chrome by checking `opcode >= 0x70 && opcode <= 0x7F`.

### 0x70 — gui_file_tree

File tree sidebar entries for the native sidebar view.

```
opcode(1) + selected_index(2) + tree_width(2) + entry_count(2) + entries...

Per entry:
  flags(1) + depth(1) + git_status(1) + icon_len(1) + icon(icon_len) + name_len(2) + name(name_len)

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

Status bar data (mode, cursor position, git branch, etc.).

```
opcode(1) + mode(1) + cursor_line(4) + cursor_col(4) + line_count(4) + flags(1) + lsp_status(1) + git_branch_len(1) + git_branch(git_branch_len) + message_len(2) + message(message_len) + filetype_len(1) + filetype(filetype_len)

Mode values:
  0 = normal, 1 = insert, 2 = visual, 3 = command, 4 = operator_pending, 5 = search, 6 = replace

Flags bits:
  bit 0: has_lsp
  bit 1: has_git
  bit 2: is_dirty

LSP status values:
  0 = none, 1 = ready, 2 = initializing, 3 = starting, 4 = error
```

### 0x77 — gui_picker

Fuzzy finder / command palette state.

```
When visible:
  opcode(1) + 1(1) + selected_index(2) + title_len(2) + title(title_len) + query_len(2) + query(query_len) + item_count(2) + items...

Per item:
  icon_color(3) + label_len(2) + label(label_len) + desc_len(2) + desc(desc_len)

icon_color is a 24-bit RGB value for the item's icon.

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
2. GUI chrome commands: `gui_theme` (if changed), `gui_tab_bar`, `gui_file_tree`, `gui_which_key`, `gui_completion`, `gui_breadcrumb`, `gui_status_bar`, `gui_picker`, `gui_agent_chat`

Note: GUI chrome commands are sent after `batch_end`. They are separate from the cell-grid frame because they update native UI state, not the pixel surface. The frontend should process them after committing the cell-grid frame to the GPU.

## Implementation References

| Component | File | Language |
|-----------|------|----------|
| Encoder | `lib/minga/port/protocol/gui.ex` | Elixir |
| Theme slot mapping | `lib/minga/theme/slots.ex` | Elixir |
| Decoder | `macos/Sources/Protocol/ProtocolDecoder.swift` | Swift |
| Constants | `macos/Sources/Protocol/ProtocolConstants.swift` | Swift |
| Test harness | `macos/TestHarness/main.swift` | Swift |
| Integration tests | `test/minga/integration/gui_protocol_test.exs` | Elixir |
