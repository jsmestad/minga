# Semantic UI Protocol Specification

This document specifies Minga's structured Semantic UI protocol for frontend-visible chrome and editor surfaces. It covers the wire format historically named `GUI` chrome opcodes, the `gui_action` input opcode, theme color slots, and the behavioral contract a semantic frontend must satisfy.

The `GUI_*` opcode and module names are historical wire names from the Swift frontend. They are not a statement that only native GUI clients may consume the contract. GUI, terminal, web, and future clients should consume the same Semantic UI models when their capabilities say they support them.

For the cell-grid rendering protocol (draw_text, set_cursor, clear, etc.), see [PROTOCOL.md](PROTOCOL.md). Cell-grid commands are not the shared UI extension point. They remain only for legacy terminal rendering and explicitly tracked compatibility work. New shared UI must be added as Semantic UI.

## Architecture Overview

Minga's rendering pipeline produces two categories of output:

1. **Legacy cell-grid commands** (opcodes 0x10-0x1B): draw_text, set_cursor, clear, batch_end, etc. These paint terminal-shaped content for legacy paths and temporary compatibility boundaries. They must not be used for new shared chrome.

2. **Semantic UI commands** (opcodes 0x70+): structured data for chrome and editor surfaces (tab bar, file tree sidebar, status bar, bottom panel, which-key popup, cursorline, gutter, buffer window content, agent surfaces, etc.). Semantic-capable frontends render these models using their own surface primitives.

Both categories may appear within the same render cycle while compatibility remains. New product UI should be represented by Semantic UI. Non-semantic shared UI frontend work is stale scope unless a ticket explicitly deletes old support or narrows a temporary compatibility boundary.

## Capability Negotiation

When a frontend sends the `ready` event (opcode 0x03), it includes a capabilities payload:

```
ready: opcode(1) + width(2) + height(2) + caps_version(1) + caps_len(1) + caps_data
caps_data: frontend_type(1) + color_depth(1) + unicode_width(1) + image_support(1) + float_support(1) + text_rendering(1)
```

`width`/`height` are **content cells at the current presentation metrics**, not pixels. A native GUI computes rows-that-fit with a single floor where the pixels live (`rows = floor(content_pixels / (cell_height × line_spacing))`) and reports that in `ready` and every `resize` (0x02). The BEAM lays out in exactly those rows and performs no line-spacing arithmetic of its own. See the `0x02 resize` section in `PROTOCOL.md` and `docs/adr/0001-frontend-owns-row-fit.md`.

The `frontend_type` byte describes the rendering surface, not the product implementation:

| Value | Type | Description |
|-------|------|-------------|
| 0x00 | TUI | Terminal frontend |
| 0x01 | native_gui | Native desktop GUI frontend (SwiftUI, GTK4) |
| 0x02 | web | Web frontend (future) |

The `semantic_ui` capability decides whether a non-GUI frontend can consume Semantic UI opcodes. Native GUI frontends are expected to consume Semantic UI. Product behavior should adapt through capability helpers such as semantic UI support, text measurement, color depth, float support, image support, and surface type. It should not branch on Swift, Go, GTK, or another implementation identity.

## Semantic UI Opcodes (BEAM → Frontend)

Semantic UI opcodes start at 0x70. Older positional commands live in 0x70-0x8F, and newer forward-compatible commands live in 0x90+. Semantic buffer rendering and overlay opcodes start at 0x80. Frontends can classify an opcode as Semantic UI by checking `opcode >= 0x70`; existing code may still call this range "GUI" for compatibility.

### Forward-Compatible Opcodes (0x90+)

Most opcodes at 0x90 and above use a 16-bit length-prefixed envelope:

```
opcode(1) + payload_length(2, big-endian) + payload(payload_length)
```

This allows old frontends to skip unknown opcodes without crashing. When a frontend encounters an unrecognized opcode >= 0x90, it reads the 2-byte length, advances past the payload, and continues decoding the rest of the batch.

Opcodes below 0x90 generally do NOT include a length prefix and retain their existing positional wire format. The explicit exceptions are `0x86 gui_agent_transcript`, which carries a 32-bit length-prefixed payload (`len32`) because the resident transcript can exceed 64KB, and `0x88 gui_agent_context`, which carries a 16-bit length-prefixed payload for compatibility with its expanded activity fields. Both occupy legacy opcode slots but self-describe their length so a frontend that recognizes the opcode can size and skip them; the schema's generated `command_size` sizes both from their declared framing. If a frontend encounters an *unknown* opcode below 0x90, it cannot determine the message size and must abort decoding. Known 0x90+ opcodes may document a wider envelope when the payload can exceed 64KB, as `clipboard_write` and `gui_file_tree` do.

The BEAM-side encoder must use a documented length-prefixed envelope for all new opcodes (0x90+). Currently defined 0x90+ opcodes:

| Opcode | Name | Description |
|--------|------|-------------|
| 0x90 | clipboard_write | Write text to the system clipboard. Uses a 32-bit payload length for content beyond 64KB. |
| 0x91 | gui_indent_guides | Indent guide positions per window |
| 0x92 | gui_line_spacing | Line spacing multiplier for the renderer |
| 0x93 | gui_file_tree | Semantic file tree rows for the native sidebar view. Uses a 32-bit payload length because expanded project trees can exceed 64KB. |
| 0x94 | gui_file_tree_selection | Lightweight file tree selection and focus update. |
| 0x95 | gui_cursor_animation | Cursor movement animation preference for GUI renderers. |
| 0x96 | gui_hover_action | Optional action metadata for the hover popup |
| 0x9A | gui_observatory | BEAM Observatory process tree and metrics for native sidebars. Uses a 32-bit payload length because large supervision trees can exceed 64KB. |
| 0x9B | gui_edit_timeline | Agent edit timeline overlay with per-file summaries appended after the per-entry list. Uses a 16-bit payload length. |
| 0x9F | gui_sidebars | Semantic sidebar host metadata. Uses a 32-bit payload length so future sidebar lists can grow without changing the envelope. |
| 0xA3 | gui_extension_runtime | Generic frontend-extension runtime envelope. Uses a 32-bit payload length so extension-owned payloads can grow without changing the shared envelope. |

### 0xA3 — gui_extension_runtime

Frontend extensions receive opaque runtime messages through a generic envelope. The shared protocol identifies the extension and channel; the payload bytes are owned by that extension's frontend adapter and must not require shared protocol structs or generated extension-specific frontend paths.

```
opcode(1) + payload_len(4) + payload(payload_len)

Payload:
  extension_id_len(2) + extension_id(extension_id_len) + channel_len(2) + channel(channel_len) + extension_payload
```

`extension_id` is the stable bundled or installed extension id, for example `minga_tasks`. `channel` is an extension-owned routing key, for example `tasks`. `extension_payload` is intentionally opaque to shared frontend code; a frontend that has a registered runtime decoder for the extension may decode it, and a frontend without one should ignore the message without crashing.

This envelope is for extension-owned runtime state. New shared chrome should still use a normal Semantic UI opcode instead of hiding shared product contracts inside extension payloads.

### 0x9F — gui_sidebars

Native frontends receive sidebar identity and placement separately from rich sidebar payloads. The BEAM remains the source of truth for which sidebars exist, which one is visible or focused, and how user actions should route back. The frontend selects a compiled-in native adapter by `semantic_kind`; it must not load arbitrary extension frontend code at runtime.

```
opcode(1) + payload_len(4) + payload(payload_len)

Payload v1:
  version(1) + sidebar_count(2) + active_id_len(2) + active_id(active_id_len) + sidebars...

Sidebar entry:
  id_len(2) + id(id_len) + display_name_len(2) + display_name(display_name_len) + semantic_kind_len(2) + semantic_kind(semantic_kind_len) + icon_len(2) + icon(icon_len) + order(2) + flags(1) + preferred_width(2) + badge_count(2)
```

Flag bits:
  bit 0: visible
  bit 1: focused

`badge_count == 0xFFFF` means no badge. Known semantic kinds in the macOS frontend are `file_tree`, `git_status`, and `observatory`. Unknown kinds must not crash the frontend. A frontend may ignore them or show a generic fallback and should log one concise warning.

User actions from the native sidebar host should use `sidebar_action` with the sidebar id, semantic kind, and action name. Existing rich payloads such as `gui_file_tree`, `gui_git_status`, and `gui_observatory` remain separately versioned and centrally encoded.

### 0x9A — gui_observatory

The BEAM Observatory receives a length-prefixed, sectioned process tree snapshot. The BEAM remains the source of truth for process identity, hierarchy, class, metrics, and message-queue history. Frontends render the tree or graph directly and send process inspection requests back through `observatory_inspect`.

```
opcode(1) + payload_len(4) + payload(payload_len)

Sections:
  0x01 header: visible(1) + node_count(2)
  0x02 nodes: node entries... (may repeat; concatenate entries in order)
  0x03 sparklines: sparkline entries... (may repeat; later entries for the same pid replace earlier ones)

Node entry:
  pid_len(1) + pid + parent_pid_len(1) + parent_pid + name_len(2) + name + class(1) + depth(1) + memory(4) + message_queue_len(2) + reductions(4)

Sparkline entry:
  pid_len(1) + pid + sample_count(1) + samples(sample_count * 2)
```

Process class values: `0 = supervisor`, `1 = buffer`, `2 = agent_session`, `3 = lsp`, `4 = service`, `5 = worker`. Sparkline samples are unsigned 16-bit normalized values in `[0, 65535]`, representing message queue pressure over recent samples.

When `visible == 0`, the frontend should hide the Observatory and clear selected process state.

### 0x93 — gui_file_tree

The native file tree receives the same semantic row model that the TUI renderer uses. The BEAM remains the source of truth for row identity, depth, expansion state, git status, diagnostics, guide columns, icons, labels, focus context, inline editing state, and committed file actions. Semantic frontends are not dumb terminals: they may own zero-latency local interaction state, such as transient row selection while the user navigates the already committed row model. On activation, toggle, rename, delete, drag/drop, or another committed intent, the frontend sends a semantic action with stable row identity and the BEAM validates it against the current model.

Legacy note: early GUI prototypes used the low 0x70 chrome range and inferred hidden state from an empty entry list. New frontends must ignore that sentinel behavior. `0x93` v2 is the canonical file-tree protocol, and `tree_state` is the only source of truth for hidden, loading, empty, ready, and error states.

```
opcode(1) + payload_len(4) + payload(payload_len)

Payload v2:
  version(1) + tree_flags(1) + tree_state(1) + selected_id_len(2) + selected_id(selected_id_len) + root_len(2) + root(root_len) + tree_width(2) + row_count(2) + error_reason_len(2) + error_reason(error_reason_len) + rows...

Payload v1, kept for decoder compatibility, omitted `tree_state` and `error_reason`. Frontends should derive v1 state from `visible` and `empty`, but all new BEAM payloads use v2.

Per row:
  path_hash(4) + row_flags(2) + depth(1) + git_status(1) + diagnostic_error_count(2) + diagnostic_warning_count(2) + diagnostic_info_count(2) + diagnostic_hint_count(2) + guide_count(1) + guides(guide_count) + id_len(2) + id(id_len) + path_len(2) + path(path_len) + rel_path_len(2) + rel_path(rel_path_len) + name_len(2) + name(name_len) + icon_len(1) + icon(icon_len) + editing_type(1) + editing_text_len(2) + editing_text(editing_text_len) + icon_color(3) + heat_level(1)

`heat_level` is an extension-contributed familiarity or heat bucket. Values `0..4` represent cold to warm, and `0xFF` means no heat decoration.

Tree flag bits:
  bit 0: visible
  bit 1: focused
  bit 4: empty
  bit 5: frontend-local navigation eligible

Tree state values:
  0 = hidden
  1 = loading
  2 = empty
  3 = ready
  4 = error

Row flag bits:
  bit 0: is_dir
  bit 1: is_expanded
  bit 2: is_selected
  bit 3: is_focused
  bit 4: is_active
  bit 5: is_dirty
  bit 6: is_editing
  bit 7: is_last_child

Git status values:
  0 = none, 1 = modified, 2 = staged, 3 = untracked, 4 = conflict, 5 = renamed, 6 = deleted

Editing type values:
  0 = new_file, 1 = new_folder, 2 = rename, 255 = none
```

When `tree_state == 0`, the frontend should hide the file tree. Hidden payloads still include the root path when the BEAM knows it, so Swift can preserve context while clearing visible rows.

`row_count == 0` only means the payload contains no entry rows. It does not imply hidden. Use `tree_state` to distinguish hidden (`0`), loading (`1`), visible-empty (`2`), and error (`4`) states. The `empty` flag bit is retained for compatibility and is set only for `tree_state == 2`.

When `tree_state == 4`, `error_reason` contains a short user-displayable reason. For all other states, `error_reason` is an empty string.

When tree flag bit 5 is set, a semantic frontend may apply zero-latency local row navigation over the last committed row model while still forwarding the key to the BEAM. This is an **identity transform** in the local-presentation taxonomy (see ARCHITECTURE.md "Frontend-local interaction state"): the frontend stores a preview index in its local-presentation container, renders the effective selection as `previewIndex ?? committedIndex`, and discards the preview when the next `gui_file_tree` or `gui_file_tree_selection` payload arrives (BEAM update is authoritative) or when the previewed row's stable ID is absent from the committed model (`retained_row_miss`). The BEAM clears this bit for modes where row navigation is not safe to predict, such as inline editing, filtering, or help. Cursor motion and selection extension are out of bounds for local presentation; they are operands the BEAM hit-tests and encodes, not client-decided.

### 0x94 — gui_file_tree_selection

Selection and focus changes can still originate from the BEAM, for example after focus restoration, reveal-active-file, stale-row resync, or compatibility paths that still route navigation through the editor. The BEAM sends this small update when the row model itself has not changed, so the native sidebar can update selection without receiving or decoding the full tree payload again. This opcode is not a requirement that every transient navigation step round-trip through the BEAM.

```
opcode(1) + payload_len(2) + payload(payload_len)

Payload:
  flags(1) + selected_id_len(2) + selected_id(selected_id_len)
```

Flag bits:
  bit 0: focused

Frontends should apply this only to the current file-tree model. If no full `gui_file_tree` payload has been received yet, the update is safe to ignore.

### 0x71 — gui_tab_bar

Visible file tabs for the active workspace.

Only file tabs from the active workspace are sent here. Agent tabs and tabs from inactive workspaces are omitted; native GUI frontends use gui_workspaces (0x98) to render inactive workspace capsules and workspace switching UI.

```
opcode(1) + active_index(1) + tab_count(1) + entries...

Per entry:
  flags(1) + id(4) + group_id(2) + icon_len(1) + icon(icon_len) + label_len(2) + label(label_len) + tint_color_rgb(4)

Flags bits:
  bit 0: is_active
  bit 1: is_dirty
  bit 2: is_agent (always 0 in the active-workspace projection)
  bit 3: has_attention
  bits 4-6: kind-scoped status. When is_agent=1: agent_status (0=idle,
            1=thinking, 2=tool_executing, 3=error, 4=plan). When is_agent=0:
            bit 4 = is_ephemeral (file tab backed by no file on disk, e.g.
            Untitled-1); bits 5-6 reserved.
  bit 7: is_pinned

group_id: workspace id this tab belongs to. 0 = manual workspace. Non-zero values match workspace IDs from gui_workspaces (0x98). Frontends use this to keep file open/close/navigation scoped to the active workspace while rendering inactive workspace capsules from gui_workspaces. `tint_color_rgb` is `0` for no tint, otherwise `0xRRGGBB`.

active_index: zero-based index into the visible tab entries, or 255 when the current active tab is not present in the visible list (for example, an active agent chat tab with only its workspace's file tabs shown).
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

### 0x76 — gui_status_bar (sectioned format)

Status bar data for the focused window. Uses a sectioned wire format where each field group is wrapped in a self-describing section. Unknown sections are skipped by the frontend, enabling forward/backward compatibility when new fields are added.

**Envelope:**
```
opcode(1) + section_count(1) + [section_id(1) + section_len(2) + payload(section_len)]*
```

**Sections:**

| ID | Name | Payload |
|----|------|---------|
| 0x01 | Identity | content_kind(1) + mode(1) + flags(1) |
| 0x02 | Cursor | cursor_line(4) + cursor_col(4) + line_count(4) |
| 0x03 | Diagnostics | error_count(2) + warning_count(2) + info_count(2) + hint_count(2) + diag_hint_len(2) + diag_hint |
| 0x04 | Language | lsp_status(1) + parser_status(1) |
| 0x05 | Git | branch_len(1) + branch + added(2) + modified(2) + deleted(2) |
| 0x06 | File | icon_len(1) + icon + icon_r(1) + icon_g(1) + icon_b(1) + filename_len(2) + filename + filetype_len(1) + filetype |
| 0x07 | Message | msg_len(2) + msg |
| 0x08 | Recording | macro_recording(1) |
| 0x09 | Agent | custom: payload depends on `content_kind` (buffer variant: agent_status(1) + background_count(2) + background_label_len(2) + background_label + active_tool_name_len(1) + active_tool_name. Agent variant: model_name_len(1) + model_name + message_count(4) + session_status(1) + agent_status(1) + background_count(2) + background_label_len(2) + background_label + active_tool_name_len(1) + active_tool_name) |
| 0x0A | Indent | indent_type(1: 0=spaces, 1=tabs) + indent_size(1) |
| 0x0B | ModelineSegments | version(1, currently 2) + left_count(2) + right_count(2) + left segments + right segments. Each v2 segment is name_len(1) + name + fg(3) + bg(3) + attrs(1) + text_len(2) + text + target_len(2) + target. |
| 0x0C | Selection | selection_mode(1: 0=none, 1=chars, 2=lines) + selection_size(4) |
| 0x0D | Workspace | id(2) + kind(1) + status(1) + flags(2) + draft_count(2) + conflict_count(2) + background_count(2) + attention_count(2) + label_len(1) + label + icon_len(1) + icon |
| 0x0E | PendingKeys | keys_len(2) + keys |
| 0x0F | Operation | operation_id(8) + kind(1) + status(1) + flags(1) + message_len(2) + message + queue_position(2) + queue_total(2) + progress_current(4) + progress_total(4) |

The Operation section is omitted when the Editor-global operation store is empty. It is independent of the Message section, so a structured-only payload remains discoverable. Operation selection prefers the newest active (`pending`, `queued`, or `running`) record and otherwise the newest retained terminal record. An older terminal outcome never displaces a newer active operation.

Operation kind values: 0=unknown, 1=external_format, 2=git_stage, 3=git_unstage, 4=git_discard, 5=git_stage_all, 6=git_unstage_all, 7=git_commit, 8=lsp_references, 9=lsp_rename.

Operation status values: 1=pending, 2=queued, 3=running, 4=success, 5=error, 6=timeout, 7=canceled, 8=stale. Flags: bit 0=cancelable, bit 1=queue values present, bit 2=progress values present. Queue and progress integer fields are zero placeholders when their presence flag is clear. Message punctuation has no semantic meaning; clients must use the generated status value.

`content_kind`: 0 = buffer window, 1 = agent chat window. When `content_kind == 1`, the standard sections (cursor, git, diagnostics, etc.) contain background buffer data and section 0x09 includes agent-specific fields. `background_count` is the number of currently running background sub-agents. `background_label` is the active background child label when focused, otherwise the first running child label. `active_tool_name` is the currently running tool label when the agent status is `tool_executing`; it is empty otherwise.

`cursor_line` and `cursor_col` are 1-indexed on the wire.

Mode values: 0=normal, 1=insert, 2=visual, 3=command, 4=operator_pending, 5=search, 6=replace

Flags bits: bit 0=has_lsp, bit 1=has_git, bit 2=is_dirty, bit 3=safe_mode

When bit 3 is set, the frontend should surface safe mode in the native status bar, for example with a small `[SAFE]` badge next to the mode indicator.

LSP status: 0=none, 1=ready, 2=initializing, 3=starting, 4=error

Parser status: 0=available, 1=unavailable, 2=restarting

Agent status: 0=idle, 1=thinking, 2=tool_executing, 3=error, 4=plan

Workspace kind: 0=manual, 1=agent. Workspace status uses the same values as agent status. Workspace flags: bit 0=attention, bit 1=closeable.

Session status (agent variant): 0=idle, 1=thinking, 2=tool_executing, 3=error, 4=plan

Macro recording: 0=not recording, 1-26=recording register a-z

`icon` is a UTF-8 encoded Nerd Font glyph for the filetype (e.g., "" for Elixir). `icon_color` is 24-bit RGB split into 3 bytes. `filename` is the display name of the active buffer (for accessibility/tooltip use). `git_added`, `git_modified`, `git_deleted` are line counts from the buffer's diff against HEAD.

`ModelineSegments` is the named GUI projection of the configurable modeline. The BEAM resolves built-in and custom segment names, side placement, explicit ordering, and click targets, then sends named styled segments to the frontend. Native frontends should use `name` to render known built-ins with platform-native controls (`mode` as a badge, `position` as compact text, `filetype` with the devicon, and so on) instead of drawing terminal-style full-height color blocks. Unknown or custom names can use `text`, `fg`, `bg`, and `attrs` as a native chip fallback. `attrs` uses the same low bits as `draw_text`: bit 0 bold, bit 1 underline, bit 2 italic. `target` is empty for non-clickable segments; otherwise it is a command name to send through the existing `execute_command` GUI action.

Section `0x0B` is omitted when the BEAM has no GUI modeline data for this frame. A present section with zero left and right segments is explicit and tells the frontend not to synthesize fallback built-ins.

`PendingKeys` (`0x0E`) is vim's `showcmd`: the pending key sequence typed in normal/operator-pending mode that has not yet resolved into a command (an accumulated count, a register prefix like `"a`, an operator like `d`, or a pending single-key op like `f`/`r`/`m`). The frontend renders it as a dim, right-aligned status-bar segment so every keypress is acknowledged instantly, underneath the delayed which-key popup. The section is omitted when the string is empty, so it clears automatically when the sequence resolves, is aborted (Esc), or which-key opens (the BEAM derives an empty string, and this section specifically omits empty payloads — unlike e.g. `Message` 0x07, which is always emitted). It renders purely from BEAM FSM state per frame with no frontend timers.

### 0x77 — gui_picker (sectioned format)

Fuzzy finder / command palette state. Uses sectioned envelope: `opcode(1) + section_count(1) + sections...`. Hidden picker: section_count=0.

| Section ID | Name | Content |
|-----------|------|--------|
| 0x01 | Header | visible, selected_index, filtered_count, total_count, has_preview, title, marked_count |
| 0x02 | Query | query string, native editing generation, acknowledged native edit sequence |
| 0x03 | Items | item_count + items (positional per item) |
| 0x04 | ActionMenu | visible flag + selected + actions |
| 0x05 | ModePrefix | mode prefix string |

```
When visible:
  opcode(1) + section_count(1) + sections...

Each section:
  section_id(1) + payload_len(2) + payload(payload_len)

Header section 0x01 payload:
  visible(1) + selected_index(2) + filtered_count(2) + total_count(2)
  + has_preview(1) + title_len(2) + title(title_len) + marked_count(2)

Query section 0x02 payload:
  query_len(2) + query(query_len) + generation(4) + acknowledged_edit_seq(4)

Items section 0x03 payload:
  item_count(2) + items...

Per item:
  icon_color(3) + flags(1) + label_len(2) + label(label_len)
  + desc_len(2) + desc(desc_len) + annotation_len(2) + annotation(annotation_len)
  + match_pos_count(1) + match_positions(match_pos_count * 2)

ActionMenu section 0x04 payload:
  action_visible(1)
  When action_visible == 1:
    selected_action(1) + action_count(1) + actions...
    Per action: name_len(2) + name(name_len)

ModePrefix section 0x05 payload:
  mode_prefix_len(2) + mode_prefix(mode_prefix_len)

icon_color is a 24-bit RGB value for the item's icon.
flags bits:
  bit 0: two_line (render description on second line)
  bit 1: marked (multi-select checkmark)
annotation is a right-aligned string (e.g., keybinding "SPC f s").
match_positions is a list of uint16 character indices for highlighting matched characters.
has_preview indicates whether the picker source supports preview (triggers split layout).
filtered_count and total_count enable "X/Y" display in the search field.
marked_count is authoritative across the full picker item set, including marked items hidden by the current filter or item limit.
action menu shows source-specific actions (e.g., "Open", "Delete", "Open in split").
mode prefix badges show switched picker sources like command, buffer, or project search.

Native frontends may optimistically edit the query with a platform text control so caret movement, selection, paste, cut, copy, undo, and IME composition remain local and immediate. Query semantics remain BEAM-owned. The frontend sends each complete field value with the current `generation` and a monotonically increasing edit sequence. The BEAM echoes the accepted sequence as `acknowledged_edit_seq`; the frontend must not replace a newer unacknowledged local value with an older echo. A new generation replaces all pending local edits.

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

### 0x78 — gui_agent_chat (sectioned format)

Agent conversation view state. Uses sectioned envelope: `opcode(1) + section_count(1) + sections...`. Hidden frames use `section_count=0`.

Each section uses `section_id(1) + section_len(2) + payload(section_len)`. Section payloads must fit in 65,535 bytes.

| Section ID | Name | Content |
|-----------|------|--------|
| 0x01 | Header | `visible(1) + status(1)` |
| 0x02 | Model | `model_len(2) + model` |
| 0x03 | Prompt | `prompt_len(2) + prompt + line_count(1) + cursor_line(2) + cursor_col(2) + vim_mode(1) + visible_rows(1)` |
| 0x04 | Pending | legacy pending approval banner payload. Current BEAM frames send `0` and render approvals inline as transcript message type `0x09`. |
| 0x05 | Help | `visible(1) + optional groups` |
| 0x07 | Completion | prompt completion popup state |
| 0x08 | Thinking | `level_len(2) + level`, where level is `off`, `low`, `medium`, or `high` |
| 0x09 | InputFocused | `input_focused(1)` |

Status values: 0 = idle, 1 = thinking, 2 = tool_executing, 3 = error

Pending approval payload:
```
0(1) — no pending approval
1(1) + name_len(2) + name(name_len) + summary_len(2) + summary(summary_len)
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

### 0x7B — gui_gutter (sectioned format)

Structured gutter data for native line number and sign rendering. One message is sent per editor window (split pane), each including the window's screen position. Agent chat windows are skipped. Uses sectioned envelope: `opcode(1) + section_count(1) + sections...`.

| Section ID | Name | Content |
|-----------|------|--------|
| 0x01 | Window | window_id, content_row, content_col, content_height, is_active, content_width |
| 0x02 | Config | cursor_line, line_number_style, line_number_width, sign_col_width |
| 0x03 | Entries | entry_count + entries (positional per entry) |

```
opcode(1) + window_id(2) + content_row(2) + content_col(2) + content_height(2) + is_active(1) + content_width(2)
+ cursor_line(4) + line_number_style(1) + line_number_width(1)
+ sign_col_width(1) + line_count(2) + entries...

Per entry:
  buf_line(4) + display_type(1) + sign_type(1) + fold_end_line(4)
```

`window_id` matches the `window_id` field in `gui_window_content` (0x80), enabling the frontend to correlate gutter data with semantic buffer content for the same window. `content_row` and `content_col` are the screen position of the window's content area (0-indexed). `content_height` is the height in rows. `is_active` is 1 for the focused window, 0 otherwise. `content_width` is the width in columns and lets the frontend clip gutter hover highlights to split boundaries. `cursor_line` is the 0-indexed buffer line where the cursor sits. `line_number_width` is the character column count allocated for line numbers. `sign_col_width` is the width before line numbers: 0 for no sign/fold prefix, 2 for the sign column only, or 3 when the dedicated fold column is present after the sign column. `line_count` is the number of visible line entries. `fold_end_line` is the inclusive 0-indexed buffer end line for foldable rows, or `0xFFFFFFFF` when the row has no fold range.

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
| 4 | fold open |
| 5 | blank gutter row |

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
| 8 | annotation |
| 9 | git removed |

Diagnostics take priority over git signs (same line shows only the highest-priority sign). The GUI frontend renders line numbers natively using its font engine, computing relative/absolute display from `buf_line` and `cursor_line`. Git added, modified, and deleted signs are drawn as colored bars; git removed signs are rendered as `-` text for diff-view removed lines. Fold indicators render in the dedicated fold column when `display_type` is `fold_start` or `fold_open`. Blank gutter rows and wrap continuations do not render line numbers.

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
  stream_instance(4) + entry_count(2) + entries...

Per entry:
  id(4) + level(1) + subsystem(1) + timestamp_secs(4) + path_len(2) + path(path_len) + text_len(2) + text(text_len)

Level bytes: 0=debug, 1=info, 2=warning, 3=error
Subsystem bytes: 0=editor, 1=lsp, 2=parser, 3=git, 4=render, 5=agent, 6=zig, 7=gui

Entries are sent incrementally: the BEAM tracks the last sent ID and only sends new entries each frame. `stream_instance` is a producer-assigned u32 that changes when the Messages producer is recreated, and frontends compose row identity from `(stream_instance, id)`. On first connection (or reconnect), all entries are sent.

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
| 8 | delete_confirm | `"Delete 'file.txt'? (y/n)"` | no | (empty) |
| 9 | branch_delete_confirm | `"Delete branch feature? (y/n)"` | no | (empty) |
| 10 | text_prompt | `"Add project: "` | yes | (empty) |

`cursor_pos` is the 0-indexed character position within `input` for the beam cursor. `0xFFFF` means no cursor (prompt-only modes 5-9). `context` is right-aligned supplementary text. `match_score` is 0-255 fuzzy match quality. `candidate_count == 0` naturally represents "input visible, no completions."

### 0x80 — gui_window_content (len32 sectioned format)

Semantic rendering data for a buffer window. Replaces draw_text commands for buffer content. The BEAM pre-resolves all layout (word wrap, folding, virtual text splicing, conceal ranges) and all styling (syntax highlighting colors). The frontend renders directly from this data via CoreText, with selection/search/diagnostics as overlay quads (not baked into text colors).

A full 0x80 message is sent for the first frame, epoch changes, full refreshes, and recovery frames. Cursor-only frames may use `gui_window_overlay_delta` (0xA0), while viewport and visible-row snapshots may use 0xA1 or 0xA2. Agent chat windows do not use this opcode. Uses len32 command framing and u32 section lengths: `opcode(1) + payload_len(4) + section_count(1) + sections...`. Each section is `section_id(1) + section_len(4) + payload(section_len)`.

| Section ID | Name | Content |
|-----------|------|--------|
| 0x01 | Header | window_id, flags, cursor_row, cursor_col, cursor_shape, scroll_left, content_epoch |
| 0x02 | Rows | row_count + rows (positional per row with spans) |
| 0x03 | Selection | selection_type + coordinates |
| 0x04 | SearchMatches | match_count + matches |
| 0x05 | Diagnostics | range_count + diagnostic ranges |
| 0x06 | DocumentHighlights | highlight_count + highlights |
| 0x07 | LineAnnotations | annotation_count + annotations |
| 0x08 | PaneGeometry | window-scoped pane geometry, viewport summary, gutter metrics, and hit regions |
| 0x09 | Cursorline | window-local cursorline row and background color |
| 0x0A | ScrollPresentation | metadata for safe client-local presentation scrolling and reconciliation |

```
opcode(1) + payload_len(4) + section_count(1) + sections...

Each section:
  section_id(1) + section_len(4) + payload(section_len)

Header section:
  window_id(2) + flags(1) + cursor_row(2) + cursor_col(2) + cursor_shape(1) + scroll_left(2) + content_epoch(4)

Flags:
  bit 0: full_refresh (1 = all rows changed, 0 = incremental)
  bit 1: cursor_visible (1 = show cursor, 0 = hide cursor)

Cursor shape: 0 = block, 1 = beam, 2 = underline

scroll_left: horizontal scroll offset in display columns. When > 0, the frontend
shifts line textures and overlay quads left by scroll_left * cell_width so that
content past the viewport's left edge becomes visible. The gutter stays fixed.

content_epoch: BEAM-authored version for retained frontend resources owned by this window. A frontend must discard retained row state for a window when the epoch changes or when `full_refresh` is set.

Per visual row:
  row_type(1) + row_id(8) + buf_line(4) + content_hash(4) + text_len(4) + text(text_len) + span_count(2) + spans...

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

Document highlights section:
  highlight_count(2)
  Per highlight: start_row(2) + start_col(2) + end_row(2) + end_col(2) + kind(1)
  Kind: 1=text, 2=read, 3=write

Line annotations section:
  annotation_count(2)
  Per annotation: row(2) + kind(1) + fg(3) + bg(3) + text_len(2) + text(text_len)
  Kind: 0=inline_pill, 1=inline_text, 2=gutter_icon
  fg/bg are 24-bit RGB. text is UTF-8, text_len is byte length.
  The frontend renders inline_pill as rounded-rect pills, inline_text as styled
  text after line content, and gutter_icon in the sign column.

Cursorline section:
  local_row(2) + r(1) + g(1) + b(1)

ScrollPresentation section:
  window_id(2) + flags(1) + anchor_top(4) + anchor_left(2) + anchor_visual_row_offset(2)
  + visible_start_line(4) + visible_end_line(4) + overscan_start_line(4) + overscan_end_line(4)
  + content_epoch(4) + layout_generation(4) + scroll_seq(4)

ScrollPresentation flags:
  bit 0: reset_required. The client must discard any local presentation offset, velocity, and reconciliation target before using this frame as a new anchor.

Pane geometry section:
  window_id(2)
  total_rect(8) + content_rect(8) + text_rect(8) + gutter_rect(8) + clip_rect(8)
  viewport_top(4) + viewport_left(2) + viewport_rows(2) + viewport_cols(2) + total_lines(4) + visual_row_offset(2) + total_visual_rows(4)
  line_number_width(2) + sign_col_width(2) + hit_region_count(1)
  Per hit region: kind(1) + rect(8) + window_id(2)

Rects are cell-space tuples encoded as row(2), col(2), width(2), height(2). Hit region kinds are 1=text, 2=gutter, 3=fold_control, 4=modeline, 5=divider, 6=status_bar. Swift converts these rects to pixels, but pane ownership and input targets come from the BEAM-authored geometry.
```

The `ScrollPresentation` section is the shared contract for local scroll feel (an **offset transform** in the local-presentation taxonomy; see ARCHITECTURE.md "Frontend-local interaction state"). The BEAM commits an anchor (`anchor_top`, `anchor_left`, `anchor_visual_row_offset`) and identifies the row/content/layout basis for that anchor with the frame transaction, `content_epoch`, row IDs/content hashes, and `layout_generation`. The frontend may keep ephemeral presentation state (local offset, velocity or momentum, overscan consumption, and reconciliation target) derived from this section, but that state is not editor state and may be discarded at any time. The reconciliation key for offset transforms is `{contentEpoch, layoutGeneration, anchorTop, anchorLeft}`: any change in this key means the BEAM moved the anchor and local offsets must be discarded. `visible_end_line` and `overscan_end_line` are exclusive bounds, so the visible and overscan line ranges are half-open: `start_line <= line < end_line`. Local presentation scroll is safe only inside `clip_rect` and only while the needed rows are already committed or retained inside `overscan_start_line..overscan_end_line`; when the range is only the visible range, the client must not expose blank space by extrapolating beyond cached rows.

`scroll_seq` (#2661, #2652) is a monotonic scroll-authority sequence, additive to the reconciliation key above. It advances on either of two signals: (a) the BEAM commits a viewport top that differs from both the previous committed top and the frontend-reported free-scroll top (a genuine BEAM-initiated anchor move: a cursor-must-stay-visible re-attach, or a jump that moved the top); or (b) an authoritative viewport-jump command explicitly marked the window, which bumps even when the committed top is unchanged. Always-authoritative commands (view centering `zz`/`zt`/`zb`, line/page scrolls `ctrl-e`/`ctrl-y`/`ctrl-d`/`ctrl-u`/`ctrl-f`/`ctrl-b`, document jumps `gg`/`G`, goto-line, search cancel) mark at dispatch; failable jumps (search hits `n`/`N`/`/`/`?`, mark jumps `'`/`` ` ``, bracket match `%`, the LSP goto family) mark only in their success branch, so a no-op (failed search, no matching bracket, unset mark, LSP miss) never discards a local offset. The authoritative set lives in `MingaEditor.Commands` (`@authoritative_scroll_commands`) plus those success-branch marks — that code, not this paragraph, is the source of truth. A frontend must discard its local offset whenever `scroll_seq` increases, even if `anchorTop`/`anchorLeft`/`layoutGeneration`/`contentEpoch` happen to be unchanged. This resolves the race where a BEAM-initiated jump lands on the same top the frontend was showing under its local offset (a `zz` while already centered, a search hit already on screen): the anchor-key check alone cannot tell that apart from a routine echo, but the explicit sequence bump does. A jump that also moves the top bumps `scroll_seq` exactly once. `H`/`M`/`L` are pure cursor motion within the visible screen and deliberately do not mark; they bump only through signal (a) when they move the committed top.

**Free-scroll zone (#2661).** For a window with full-document residence (#2653/#2658), the frontend applies wheel/trackpad input as an immediate local pixel offset over the resident row textures on the same frame the input arrives, with no BEAM round trip on the render path. It reports scroll intent promptly on the existing scroll-intent channel (the `scroll_batch` opcode) so the BEAM can track cursor position and resolve viewport-relative commands (`H`, `M`, `L`, `zt`, `zz`, `zb`) against the reported top; because scroll reports and key events share the same ordered input channel, later commands always resolve against the most recent report. Every wheel/trackpad report is an *echo*: the committed top matches the top the frontend already reported, so it never advances `scroll_seq`. Wheel/trackpad scrolling is VSCode-style (#2684): it moves only the viewport and never the cursor, at any distance or velocity. The cursor may scroll out of view; when it does, the caret and cursorline disappear (see the cursorline note below) and the next cursor-moving keypress re-anchors the view via the existing cursor-follow. Explicit scroll commands (`ctrl-e`/`ctrl-y`, `ctrl-d`/`ctrl-u`/`ctrl-f`/`ctrl-b`, `zz` family) keep their vim cursor semantics; only wheel/trackpad input is viewport-only. Because the committed top always equals the reported top, `scroll_seq` stays put — advancing it on every wheel frame would prescribe a frontend discard per frame during a long scroll gesture, i.e. a re-anchor storm. Only BEAM-initiated anchor moves (jumps, `ctrl-d`/`ctrl-u`, `zz`, cursor-must-stay-visible re-attach) advance `scroll_seq`. This is windowed-window- and residence-off-safe: the free-scroll zone activates only where the BEAM's overscan range already covers the motion (`overscan_start_line..overscan_end_line`), which the existing local-offset compositor already gates on, so windowed windows and residence-off configurations keep today's behavior unchanged.

**Drag-defers rule (#2661).** During an active selection drag (left mouse button held down over buffer content, not a pane-divider or scrollbar-thumb drag), local presentation scrolling defers to BEAM-authoritative anchors: the frontend suppresses its local pixel offset and renders the plain committed frame instead. Drag-autoscroll (crossing the top/bottom edge while dragging a selection) is entirely BEAM-owned. Scroll-intent reports keep going out normally during a drag; only the local offset *presentation* is suppressed, so there is no visible conflict between the two scroll mechanisms. This means scrolling while dragging a selection intentionally feels heavier than free-scroll: it waits on the BEAM round trip rather than rendering locally on the same frame. That extra latency is by design (selection extent and autoscroll are BEAM-owned, so the frontend must not layer a local offset on top), not a bug to be "fixed" by re-enabling the local offset during a drag.

Pointer input during local scroll must be normalized through the current presentation transform before it is sent to the BEAM. If a frontend cannot normalize locally, it must carry enough frame and presentation-offset information in the input path before enabling local scroll. The BEAM continues to interpret input against its committed viewport and hit regions, so there is no undefined middle state for click, drag, wheel, or hover. This includes cursorline: the 0xA0 overlay delta's `local_row` is drawn through the same offset transform as text rows, so cursorline highlighting stays visually consistent with the live local scroll. When the cursor is scrolled outside the viewport, the BEAM encodes it as not-visible (the `cursor_visible` flag is clear and the `cursorline_present` flag is clear, so no `local_row` is sent); the caret and cursorline then simply disappear rather than clamping to an edge row, and reappear when the cursor's line scrolls back into view (#2684).

The scroll compositor state machine is: start with the last clean committed frame as the anchor, apply local presentation offsets only while the clip and overscan contract can cover the motion, send scroll intent to the BEAM (the `scroll_batch` opcode), reconcile toward the next committed anchor when a valid frame arrives, and reset immediately on `reset_required`, a newer `scroll_seq`, keyframe/base-frame mismatch, resize, file switch, edit/content epoch change, font or line-spacing change, wrapping/fold change, layout generation change, or any retained-row miss. Small drift may be smoothed by the frontend; structural invalidation must snap predictably to the committed BEAM frame.

The overscan range is BEAM-sized and never requested by the frontend. For a resident window (#2653/#2679) it spans the whole document, so a scroll can never outrun cached rows and the free-scroll zone always covers the motion. For the windowed remnant (wrapped/folded buffers and the one pre-promotion arming frame) the BEAM emits the viewport plus a fixed overscan. There is no frontend-to-BEAM overscan-prefetch request and no velocity-adaptive refill: the `scroll_prefetch_hint` opcode (0x0A) and the velocity-aware overscan machinery were deleted in #2680 (epic #2652), because residence removes the runway-exhaustion problem and the surviving windowed cases either ignore overscan (wrapped/folded) or render a single idle first-paint frame (arming). A frontend that runs the windowed remnant out of cached rows still resets to the committed frame per the rules above; it just no longer asks for more overscan ahead of time. This scroll-path "no reconciliation, no prefetch" ruling is distinct from the content-addressed 0xA2 ref-miss recovery guard below, which stays in v1.

The frontend renders selection and search matches as Metal quads behind text (not baked into line textures). This enables zero re-rasterization when the selection changes. Diagnostic underlines are rendered as quads after text.

`row_id` is a BEAM-authored stable identity for the durable visual row, and each row ID must be unique within a window frame. `content_hash` is a per-row hash computed by the BEAM. The frontend keys retained CTLine textures by `window_id + content_epoch + row_id + content_hash`, so scrolling can reuse the same logical row even when its display row changes.

When `gui_window_content` is present for a window, the BEAM does not send draw_text commands for that window's buffer content. Overlays (hover popups, signature help) have dedicated GUI opcodes (0x81, 0x82) and are rendered natively by SwiftUI. Gutter data (0x7B) continues through its existing opcode, while cursor position and window-local cursorline are carried in gui_window_content section 0x09 or in overlay deltas (0xA0).

### 0xA0 - gui_window_overlay_delta

Cursor-only retained rendering update for one GUI window. The BEAM sends this when the durable rows and non-cursor overlays are unchanged but cursor position, cursor visibility, cursor shape, or cursorline changed. It may also send the same minimal payload as a per-frame liveness marker for an unchanged retained window, so the frontend does not prune valid retained content during clear-backed batches.

```
opcode(1) + window_id(2) + content_epoch(4) + flags(1) + cursor_row(2) + cursor_col(2) + cursor_shape(1) + optional_cursorline

Flags:
  bit 0: cursor_visible
  bit 1: cursorline_present

Cursor shape: 0 = block, 1 = beam, 2 = underline

If cursorline_present:
  local_row(2) + r(1) + g(1) + b(1)
```

The frontend applies the delta only when it already has `gui_window_content` for the same `window_id` and `content_epoch`. If the epoch is missing or stale, it ignores the delta and waits for the next full 0x80 refresh.

### 0xA1 - gui_window_viewport_delta and 0xA2 - gui_window_rows_delta

`gui_window_viewport_delta` (A1) remains a complete ordered row snapshot for viewport-only changes. `gui_window_rows_delta` (A2) evolves in protocol v11 to carry bounded structural splices. This is an evolution of A2, not a new opcode or semantic surface.

```
opcode(1) + section_count(1) + sections...

Each section is `section_id(1) + section_len(4) + payload(section_len)`. Decoders validate every declared section length before allocating or staging it.

Header section 0x01:
  window_id(2) + content_epoch(4) + flags(1) + cursor_row(2) + cursor_col(2) + cursor_shape(1) + scroll_left(2)

A1 Rows section 0x02 (complete snapshot):
  row_count(4) + row_entries...

Legacy protocol-v10 A2 Rows section 0x02 (complete snapshot, decode/replay only):
  row_count(4) + row_entries...

Protocol-v11 A2 RowSplices section 0x0B:
  base_row_count(4) + result_row_count(4) + splice_count(4) + splices...

Per splice:
  start_index(4) + delete_count(4) + insert_count(4) + insert_entries...

Per row or insert entry:
  entry_type(1)
  if entry_type == 0: row_id(8) + content_hash(4)
  if entry_type == 1: full row payload, same row encoding used by 0x80 section 0x02

Sections 0x03-0x0A:
  same selection, search, diagnostics, document highlights, annotations, geometry, cursorline, and scroll-presentation sections used by 0x80
```

A v11 producer emits section 0x0B for A2 and omits section 0x02. Decoders keep the v10 section 0x02 form for replay, but reject an A2 command that carries both forms. All splice coordinates address the same immutable base sequence. Splices must be strictly ascending and non-overlapping, each deletion must fit within `base_row_count`, and applying the exact arithmetic `base - deleted + inserted` must equal `result_row_count`. Empty or trailing bytes, duplicate row identities, invalid buffer-line ordering, and malformed entry tags reject the staged frame.

The frontend applies a delta only when it has retained content for the same `window_id` and `content_epoch`, and its retained row count equals `base_row_count`. It validates all splices and resolves every ref by `row_id + content_hash` against the immutable base before mutating a staged store. A missing ref retains the typed `window_ref_miss` outcome. Any malformed splice reports `invalid_row_splice`; neither failure partially publishes the frame. A1 and full 0x80 remain complete snapshots.

### 0xA5 — gui_empty_state

The zero-buffers launchpad (#2689): data-driven sections (session resume, recent files, actions, footer) with chords resolved from the user's live keymap. Frontends lay the surface out natively (SwiftUI column with the logo watermark; TUI centered block) and render it instead of window content while visible. Activation is echoed back with the `empty_state_activate` gui_action (0x07 sub-opcode 0x5B, payload string8 item id) so semantics stay BEAM-side.

```
opcode(1) + payload_len(2) + payload

Payload:
  visible(1): 0 = hidden (payload ends here), 1 = visible
  flags(1): bit 0 = crashed (previous session did not shut down cleanly)
  version: string8
  focused_id: string8 (empty = no focus)
  section_count(1), per section:
    section_id(1): 0 = session, 1 = recent, 2 = start, 3 = footer
    title: string8
    item_count(1), per item:
      kind(1): 0 = resume, 1 = recent_file, 2 = action, 3 = hint
      id: string8
      label: string16
      detail: string16
      jump_key: string8 (empty = none; single keycap chip when present)
      chord: string8 (space-separated keystroke tokens, e.g. "SPC f f"; one chip per token)
      icon: string8 (Nerd Font glyph, may be empty)
      icon_color: u32 (0xRRGGBB, 0 = theme default)
```

Input-visual classes: a non-empty `jump_key` renders as a single keycap chip, a non-empty `chord` renders chip-per-token, and a `detail` starting with `:` renders as accent text (ex command). `focused_id` is authoritative; frontends may locally echo focus movement between frames but reconcile to it.

### 0x81 — gui_hover_popup

Native hover tooltip popup for LSP hover content. Sends parsed markdown content as styled segments so the GUI frontend can render with native text layout. Positioned at the anchor token; the frontend handles above/below flip logic.

```
opcode(1) + visible(1) + anchor_row(2) + anchor_col(2) + focused(1) + scroll_offset(2) + line_count(2) + lines...

Per line:
  line_type(1) + segment_count(2) + segments...

Per segment:
  standard: style(1) + text_len(2) + text(text_len)
  syntaxHighlighted: style(1=13) + fg_r(1) + fg_g(1) + fg_b(1) + flags(1) + text_len(2) + text(text_len)

Line types: 0=text, 1=code, 2=code_header, 3=header, 4=blockquote, 5=list_item, 6=rule, 7=empty

Segment styles: 0=plain, 1=bold, 2=italic, 3=bold_italic, 4=code, 5=code_block, 6=code_content, 7=header1, 8=header2, 9=header3, 10=blockquote, 11=list_bullet, 12=rule, 13=syntaxHighlighted

`syntaxHighlighted` carries a BEAM-resolved foreground color from the active theme. Its flags byte uses bit 0 for bold, bit 1 for italic, and bit 2 for underline. Frontends should render it with the same monospaced font as code content.

When visible=0, no further fields are sent. The frontend hides the popup.
When focused=1, the popup border uses the accent color and scrolling is enabled.
```

### 0x82 — gui_signature_help

LSP signature help popup showing the active function signature with parameter highlighting. Positioned above the cursor. Supports multiple overloaded signatures with cycling.

```
opcode(1) + visible(1) + anchor_row(2) + anchor_col(2) + active_signature(1) + active_parameter(1) + signature_count(1) + signatures...

Per signature:
  label_len(2) + label(label_len) + doc_len(2) + doc(doc_len) + param_count(1) + params...

Per parameter:
  label_len(2) + label(label_len) + doc_len(2) + doc(doc_len)

When visible=0, no further fields are sent. The frontend hides the popup.
The frontend highlights the active parameter (identified by `active_parameter` index) within the active signature's label string by matching the parameter label as a substring.
```

### 0x83 — gui_float_popup

Centered float popup window for buffer content (e.g. `*Help*`). The BEAM reads the buffer content and sends it as plain text lines. The frontend renders as a centered panel with a title bar and scrollable content.

```
opcode(1) + visible(1) + width(2) + height(2) + title_len(2) + title(title_len) + line_count(2) + lines...

Per line:
  text_len(2) + text(text_len)

Width and height are in cell units. The frontend converts to points using cell dimensions.
When visible=0, no further fields are sent. The frontend hides the popup.
```

### 0x84 — gui_split_separators

Split pane separator lines for Metal rendering. Sent as a Metal-critical command bundled with gutter, cursorline, and gutter separator. One message per frame when splits are active.

Vertical separators are 1px-wide lines between split panes. Horizontal separators are 1px-high lines with a centered filename label separating horizontal splits.

```
opcode(1) + border_color_rgb(3) + vertical_count(1) + verticals... + horizontal_count(1) + horizontals...

Per vertical:
  col(2) + start_row(2) + end_row(2)

Per horizontal:
  row(2) + col(2) + width(2) + filename_len(2) + filename(filename_len)

border_color_rgb is 24-bit RGB from theme.editor.split_border_fg.
When no splits are active, the BEAM sends counts of 0 for both separator types.
```

### 0x85 — gui_git_status

Git status panel data for the native sidebar, plus remote operation feedback used by the sidebar and status bar.

```
opcode(1) + repo_state(1) + syncing(1) + ahead(2) + behind(2) + branch_len(2) + branch(branch_len) + entry_count(2) + entries... + toast_present(1) + toast? + entry_base_path_len(2) + entry_base_path(entry_base_path_len) + last_commit_message_len(2) + last_commit_message(last_commit_message_len) + stash_count(2)

Per entry:
  path_hash(4) + section(1) + status(1) + path_len(2) + path(path_len)

Toast when toast_present == 1:
  level(1) + action(1) + msg_len(2) + msg(msg_len)
```

`repo_state`: 0 = normal, 1 = not_a_repo, 2 = loading.
`entry_base_path`: absolute base path for the displayed entry paths. This is usually the project root, and can differ from the repository root in monorepos.
`syncing`: 1 while a git remote operation is in flight, otherwise 0.
`section`: 0 = staged, 1 = changed, 2 = untracked, 3 = conflicted.
`status`: 0 = unknown, 1 = modified, 2 = added, 3 = deleted, 4 = renamed, 5 = copied, 6 = untracked, 7 = conflict.
`level`: 0 = success, 1 = error.
`action`: 0 = none, 1 = pull_and_retry.
`stash_count`: number of stashes in the repository. It must fit the u16 carrier; an out-of-range value rejects the frame before any bytes reach the frontend. Frontends should show it only when greater than zero.

When the git status panel is closed, the BEAM sends `repo_state = not_a_repo`, no entries, and an empty `entry_base_path` as the hide signal. A non-git project opened in the Source Control tab also uses `repo_state = not_a_repo`, but includes the project root so the frontend can show the native "Not a git repository" empty state instead of hiding the panel. The frontend should still copy `syncing` and `toast` so remote operation feedback remains accurate while the panel is hidden.

### 0x86 — gui_agent_transcript

Resident agent-chat transcript stream (#2654). Carries the conversation as resident data so a frontend scrolls it from local state without a BEAM round-trip, decoupled from the `gui_agent_chat` (0x78) chrome model. Framing is `len32` (opcode + u32 payload length), so the payload can exceed 64KB and any frontend that recognizes the opcode sizes and skips it via the schema's generated `command_size`. Message bodies use the shared agent-chat message body codec.

The semantic-model builder scopes the resident set by `display_start_index` and bounds it with `agent_transcript_resident_max_bytes` as a contiguous most-recent suffix. It retains every selected message whole, and the `truncated` flag signals when older complete messages sit outside the window. The GUI adapter serializes that selected model exactly and never applies its own cap.

```
opcode(1) + payload_len(4) + payload

payload:
  version(1) = 1
  mode(1)              # 0 = full_replace, 1 = append
  epoch(4)
  truncated(1)         # 1 when older messages sit outside the resident window
  # full_replace (mode 0):
  count(4)
  # append (mode 1):
  trim_front(4)        # leading messages evicted from the store front this delta
  base_count(4)        # unchanged leading messages of the remainder to keep
  count(4)
  # both modes:
  count * message

message:
  id(4) + body_len(4) + body(body_len)   # body is the shared agent-chat message codec
```

Typed body payloads:
```
0x01 (user):      type(1) + text_len(4) + text
0x02 (assistant): type(1) + text_len(4) + text
0x03 (thinking):  type(1) + collapsed(1) + text_len(4) + text
0x04 (tool_call): type(1) + status(1) + error(1) + collapsed(1) + duration_ms(4) + name_len(2) + name + summary_len(2) + summary + result_len(4) + result + auto_approved(1) + optional tool_preview_payload
0x05 (system):    type(1) + level(1) + text_len(4) + text
0x06 (usage):     type(1) + input(4) + output(4) + cache_read(4) + cache_write(4) + cost_micros(4)
0x07 (styled_assistant): type(1) + line_count(2), per line: run_count(2), per run: text_len(2) + text + fg(3) + bg(3) + flags(1), and if flags bit 0x08 is set: url_len(2) + url. Link URLs are limited to http, https, and mailto.
0x08 (styled_tool_call): type(1) + status(1) + error(1) + collapsed(1) + duration_ms(4) + name_len(2) + name + summary_len(2) + summary + line_count(2), per line: run_count(2), per run: text_len(2) + text + fg(3) + bg(3) + flags(1), and if flags bit 0x08 is set: url_len(2) + url, auto_approved(1) + optional tool_preview_payload. The summary uses a UTF-8-safe preview budget so the styled payload and appended auto-approval/preview bytes still fit. Link URLs are limited to http, https, and mailto.
0x09 (approval_tool_call): type(1) + status(1) + name_len(2) + name + summary_len(2) + summary + tool_call_id_len(2) + tool_call_id + preview_kind(1) + preview_line_count(2), per line: line_len(2) + line
0x0A (assistant_markdown): type(1) + block_count(2) + blocks...
```

Markdown block payloads are BEAM-authored semantic structure. Frontends must render these blocks directly and must not infer code cards from styled-run flags, decorative rails, or all-code lines. Each block starts with `block_id(4) + kind(1) + flags(1)` and then a kind-specific payload:

- `0x01 paragraph`: `line_count(2) + styled_lines`
- `0x02 heading`: `level(1) + line_count(2) + styled_lines`
- `0x03 list_item`: `indent(1) + ordered(1) + ordinal(4) + line_count(2) + styled_lines`
- `0x04 blockquote`: `line_count(2) + styled_lines`
- `0x05 rule`: no payload
- `0x06 spacer`: `height(1)`
- `0x07 code_block`: `language_len(2) + language + label_len(2) + label + target_path_len(2) + target_path + capability_flags(1) + line_count(2) + styled_lines`

For code blocks, block flag `0x01` means complete; absence means streaming or incomplete. Capability flags are `0x01=copy`, `0x02=open`, and `0x04=apply`; frontends should only expose actions they actually implement. `block_id` is stable for a message and block index so streaming updates preserve identity.

`auto_approved`: 0=not auto-approved, 1=session trust, 2=turn trust.

`tool_preview_payload` is appended to current `tool_call` and `styled_tool_call` messages after `auto_approved`: `preview_kind(1) + preview_line_count(2) + lines...`, with each line encoded as `line_len(2) + line`. Preview kinds match approval previews: 0=args, 1=diff, 2=command, 3=target. Tool-call previews are inline context only; `approval_tool_call` keeps the same preview payload fields as part of its required approval card shape.

Styled run flags: 0x01=bold, 0x02=italic, 0x04=underline, 0x08=link URL present, 0x10=code run (monospaced, preserve whitespace). The 0x10 bit is a run-level hint only and must not be used to infer fenced block boundaries, code-card containers, or language labels.

`epoch` is an opaque change token; a frontend that receives an `epoch` different from the one its store was built under must treat the frame as authoritative for that epoch. `mode`:

- **full_replace** — clear the store, then set it to the `count` messages in order. Emitted on first frame of an epoch, on epoch change, or on a non-prefix divergence (e.g. compaction).
- **append** — an incremental delta within the current epoch. Apply in this order: drop `trim_front` messages from the **front** of the store (cap eviction of older messages); of the remainder, keep the first `base_count` messages unchanged; then upsert each of the `count` messages by `id` (a new `id` appends; a matching `id` patches the streaming last message in place).

`base_count` is the count of unchanged leading messages **of the remainder** (after the `trim_front` drop), i.e. keep `[0, base_count)` and upsert from there. It is **not** the store's resident count, and is normally less than it on every streaming patch (the patched last message is part of the upserted suffix). A frontend desyncs (drops the delta and requests / awaits the next `full_replace`) only when its resident count is **less than** `trim_front + base_count`, meaning the delta cannot be applied against what the store holds. Because eviction rides `trim_front`, an over-cap session in steady streaming keeps emitting bounded appends rather than degrading to a full replace per frame.

### 0x88 — gui_agent_context

Agent activity chrome for the native agent context bar. The BEAM owns the visible task, elapsed timestamp, approval state, progress summary, and the current todo plan snapshot.

```
opcode(1) + payload_len(2) + payload(payload_len)

Payload:
  visible(1) + task_len(2) + task(task_len) + dispatch_timestamp(8) + status(1) + can_approve(1)
  + active_action_len(2) + active_action(active_action_len)
  + tool_count(2) + file_count(2)
  + review_hint_len(2) + review_hint(review_hint_len)
  + todo_count(1) + todos...

Per todo:
  status(1) + description_len(2) + description(description_len)
```

`status`: 0 = idle, 1 = working, 2 = iterating, 3 = needs_you, 4 = done, 5 = errored.
`can_approve` means the agent is waiting on the user to approve or reject the current work. Frontends should treat it as the source of truth for the review affordance, and render the needs-you state when it is set.
`dispatch_timestamp` is Unix seconds. `review_hint` is the short review copy shown next to the progress summary.
`todo_count` is the number of visible todo items in the snapshot. The todo list is the editor's live projection of the provider plan, not a separate provider-only state. A hidden context may omit the progress and todo tail after `can_approve`; frontends must treat missing tail fields as empty progress and no todos for legacy compatibility.

### 0x98 — gui_workspaces

Canonical workspace state for native frontends. This is the source of truth for workspace headers, active-workspace file tabs, badges, and workspace view mode. The old agent-group payload is gone; frontends should not infer workspace state from tab order or legacy agent-only lists.

```
opcode(1) + payload_len(2) + payload(payload_len)

Payload:
  version(1) + active_workspace_id(2) + mode(1) + flags(1) + workspace_count(1)
  + workspaces... + visible_tab_count(2) + visible_tabs...

Per workspace:
  id(2) + kind(1) + status(1) + flags(2) + color_r(1) + color_g(1) + color_b(1)
  + tab_count(2) + draft_count(2) + conflict_count(2) + running_background_count(2)
  + label_len(1) + label(label_len) + icon_len(1) + icon(icon_len)

Per visible tab:
  id(4) + workspace_id(2) + kind(1) + flags(2) + path_hash(4)
  + icon_len(1) + icon(icon_len) + label_len(2) + label(label_len)
  + path_len(2) + path(path_len) + tint_color_rgb(4)
```

`version` is currently 2. Version 2 adds `tint_color_rgb` to each visible tab entry and bit 5 for pinned tabs. `mode`: 0 = editor, 1 = agent, 2 = file_tree, 3 = other. Workspace `kind`: 0 = manual, 1 = agent. Visible tab `kind`: 0 = file, 1 = agent. `status`: 0 = idle, 1 = thinking, 2 = tool_executing, 3 = error, 4 = plan. Workspace flags: bit 0 = attention, bit 1 = closeable. Visible tab flags: bit 0 = dirty, bit 1 = attention, bit 2 = draft, bit 3 = draft_elsewhere, bit 4 = conflict, bit 5 = pinned, bit 6 = ephemeral (file tab backed by no file on disk, e.g. Untitled-1). `tint_color_rgb` is `0` for no tint, otherwise `0xRRGGBB`.

The workspace list includes the manual project workspace and all agent workspaces. The visible tab list includes the active workspace's agent tab first when present, followed by its file tabs. Agent view remains a workspace zoom surface, so it is not encoded as a normal file tab.

### 0x99 — gui_notifications

Structured notification center state for native frontends. The BEAM owns the model and sends full snapshots. Native frontends render the stack as bottom-right chrome and send dismiss or action clicks back through `gui_action`.

```
opcode(1) + payload_len(2) + payload(payload_len)

Payload:
  version(1) + notification_count(2) + notifications...

Per notification:
  id_len(2) + id + level(1) + flags(1) + created_at(8) + updated_at(8)
  + auto_dismiss_ms(4) + title_len(2) + title + body_len(2) + body
  + source_len(2) + source + action_count(1) + actions...

Per action:
  id_len(2) + id + label_len(2) + label
```

`version` is currently 1. `level`: 0 = info, 1 = warning, 2 = error, 3 = success, 4 = progress. Flags: bit 0 = dismissable. `created_at` and `updated_at` are Unix seconds. `auto_dismiss_ms` uses `0xFFFFFFFF` for no auto-dismiss. Errors and progress notifications should normally use no auto-dismiss. Informational and success notifications may auto-dismiss after a short delay.

TUI frontends do not render this opcode. The BEAM should also log important notifications to `*Messages*` so terminal users get the same information.

### 0x9B — gui_edit_timeline

Edit timeline overlay data for native frontends. The BEAM sends the active entry list and the aggregate changed-file summaries in one payload so the frontend can switch between per-entry scrubbing and per-file review without guessing from local state.

```
opcode(1) + payload_len(2) + payload(payload_len)

Payload:
  visible(1) + viewing_index(2) + entry_count(1) + entries... + file_count(1) + files...

Per entry:
  index(1) + tool_name_len(1) + tool_name(tool_name_len) + timestamp_delta(4)

Per file:
  path_len(2) + path(path_len) + entry_count(1) + lines_added(4) + lines_removed(4) + review_status(1)
```

`viewing_index` is `0xFFFF` when the timeline is live at the latest state. When `file_count` is greater than zero, frontends should show the aggregate changed-file view and use the per-file rows for navigation and review status.
`review_status`: 0 = pending, 1 = reviewing.

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
| 0x0D | file_tree_new_file | parent_index(2) | Create new file under or near the selected entry |
| 0x0E | file_tree_new_folder | parent_index(2) | Create new folder under or near the selected entry |
| 0x0F | file_tree_collapse_all | (empty) | Collapse all directories in tree |
| 0x10 | file_tree_refresh | (empty) | Refresh file tree |
| 0x11 | tool_install | name_len(2) + name(name_len) | Install a tool by name |
| 0x12 | tool_uninstall | name_len(2) + name(name_len) | Uninstall a tool by name |
| 0x13 | tool_update | name_len(2) + name(name_len) | Update a tool by name |
| 0x14 | tool_dismiss | (empty) | Dismiss the tool manager panel |
| 0x15 | agent_tool_toggle | message_id(4) | Toggle collapse/expand of the agent tool or thinking entry with the stable transcript message ID |
| 0x16 | execute_command | name_len(2) + name(name_len) | Execute a named command from the BEAM command registry |
| 0x17 | minibuffer_select | index(2) | Select minibuffer candidate at index |
| 0x18 | git_stage_file | path_len(2) + path(path_len) | Stage a file |
| 0x19 | git_unstage_file | path_len(2) + path(path_len) | Unstage a file |
| 0x1A | git_discard_file | path_len(2) + path(path_len) | Discard working-tree changes |
| 0x1B | git_stage_all | (empty) | Stage all changes |
| 0x1C | git_unstage_all | (empty) | Unstage all |
| 0x1D | git_commit | amend(1) + msg_len(2) + msg(msg_len) | Commit with message, or amend when `amend` is 1. New frontends should use this action for both normal and amend commits. |
| 0x1E | git_open_file | path_len(2) + path(path_len) | Open file in editor |
| 0x1F | workspace_rename | id(2) + name_len(2) + name(name_len) | Rename an agent workspace group |
| 0x20 | workspace_set_icon | id(2) + icon_len(1) + icon(icon_len) | Change an agent workspace icon |
| 0x21 | workspace_close | id(2) | Close an agent workspace |
| 0x22 | space_leader_chord | codepoint(4) + modifiers(1) | Enter leader mode from a clean Space chord |
| 0x23 | space_leader_retract | codepoint(4) + modifiers(1) | Retract a literal Space and enter leader mode |
| 0x24 | find_pasteboard_search | direction(1) + text_len(2) + text(text_len) | Search from the macOS find pasteboard |
| 0x29 | agent_approve | (empty) | Approve an agent change request |
| 0x2A | agent_request_changes | (empty) | Request agent changes |
| 0x2B | agent_dismiss | (empty) | Dismiss agent review UI |
| 0x2C | change_summary_click | index(4) | Select a change summary entry |
| 0x2D | file_tree_edit_confirm | text_len(2) + text(text_len) | Confirm file tree inline edit |
| 0x2E | file_tree_edit_cancel | (empty) | Cancel file tree inline edit |
| 0x2F | scroll_to_line | line(4) | Scroll viewport to target line (from scroll indicator click/drag) |
| 0x30 | file_tree_delete | index(2) | Delete a file tree entry |
| 0x31 | file_tree_rename | index(2) | Rename a file tree entry |
| 0x32 | file_tree_duplicate | index(2) | Duplicate a file tree entry |
| 0x33 | file_tree_move | source_index(2) + target_dir_index(2) | Move a file tree entry |
| 0x40 | file_tree_drop | target_index(2) + target_path_hash(4) + target_kind(1) + modifiers(1) + target_id_len(2) + target_id + target_path_len(2) + target_path + source_count(2) + sources... | Report file tree drag/drop intent for BEAM-owned filesystem handling |
| 0x41 | fold_toggle_at_line | window_id(2) + buffer_line(4) | Toggle the fold at a gutter-targeted buffer line without moving the cursor |
| 0x43 | config_update | key_len(1) + key + type_tag(1) + value_payload | Update a typed config option from the native Settings UI |
| 0x44 | config_query | (empty) | Request the current native Settings state |
| 0x45 | notification_dismiss | id_len(2) + id | Dismiss one notification |
| 0x46 | notification_action | id_len(2) + id + action_id_len(2) + action_id | Invoke one inline notification action |
| 0x47 | power_thermal_state | low_power(1) + thermal_state(1) | Report low power mode and thermal pressure changes. `thermal_state` is 0 nominal, 1 fair, 2 serious, 3 critical, 255 unknown. |
| 0x48 | tab_reorder | tab_id(4) + new_index(2) | Move a visible tab to a zero-based visible index |
| 0x49 | tab_pin | tab_id(4) | Pin a tab by id without selecting it first |
| 0x4A | tab_unpin | tab_id(4) | Unpin a tab by id without selecting it first |
| 0x4B | tab_move_left | tab_id(4) | Move a tab one visible slot left without selecting it first |
| 0x4C | tab_move_right | tab_id(4) | Move a tab one visible slot right without selecting it first |
| 0x4D | observatory_inspect | pid_len(2) + pid | Inspect a BEAM Observatory process PID |
| 0x57 | sidebar_action | sidebar_id_len(2) + sidebar_id + kind_len(2) + kind + action_len(2) + action | Invoke a semantic sidebar host action tied to BEAM-owned sidebar identity |
| 0x58 | extension_action | extension_id_len(2) + extension_id + action_len(2) + action + extension_payload | Invoke an extension-owned frontend action through the active shell; the trailing payload is opaque to shared GUI action decoding |
| 0x59 | float_popup_dismiss | (empty) | Dismiss the active float popup |
| 0x5A | system_will_unmount | path_len(2) + path | A volume is about to unmount; BEAM protects buffers under the mount path |
| 0x5C | chat_scrolled_away_from_bottom | (empty) | Reader left the transcript bottom; pauses BEAM-side auto-follow (pin flag only, no offset move) |
| 0x5D | chat_returned_to_bottom | (empty) | Reader returned to the transcript bottom; re-pins auto-follow (pin flag only, no offset move) |
| 0x5F | picker_query_changed | generation(4) + edit_seq(4) + query_len(2) + query | Replace the native picker's complete query when the edit belongs to the active generation and is newer than the last acknowledged edit |
| 0x34 | system_will_sleep | (empty) | System is about to sleep |
| 0x35 | system_did_wake | (empty) | System woke and BEAM should refresh external state |
| 0x36 | cmd_copy | (empty) | Execute mode-aware copy from the macOS menu |
| 0x37 | cmd_cut | (empty) | Execute mode-aware cut from the macOS menu |
| 0x38 | git_push | (empty) | Push the current branch |
| 0x39 | git_pull | (empty) | Pull from the upstream branch |
| 0x3A | git_fetch | (empty) | Fetch remote refs |
| 0x3B | git_commit_amend | msg_len(2) + msg(msg_len) | Legacy compatibility action for amending the previous commit; new frontends should send `git_commit` with `amend = 1` instead |
| 0x3C | git_pull_and_retry | (empty) | Pull, then retry the failed push |
| 0x3D | file_tree_open_in_split | index(2) | Open a file tree entry in a vertical split |
| 0x3E | tab_copy_path | tab_id(4) | Copy a tab's file path |
| 0x3F | hover_open_action | (empty) | Accept the current hover popup action |
| 0x42 | git_open_diff | path_len(2) + path(path_len) + section(1) | Open a diff view for a git status file in the selected section |

Older path-only `git_open_diff` payloads are accepted as a compatibility fallback only when the path is unambiguous. Native frontends should always send the section-aware form.

For `file_tree_drop`, `target_kind` is `1` for a directory and `0` for a file. Each source is encoded as `path_len(2) + path(path_len)`. Frontends should send both the target index and stable target identity so the BEAM can reject stale drops safely; drops onto files are resolved to the file's parent directory by the BEAM.

For `extension_action`, shared decoding stops after `extension_id` and `action`; the remaining bytes are passed unchanged to the active shell or extension adapter. Frontends should use this only for extension-owned actions, not for shared chrome interactions that need a durable cross-frontend contract.

## Settings State (0x97)

`gui_config_state` uses the standard 0x90+ envelope: `opcode(1) + payload_len(2) + payload`. The payload is `option_count(2) + options + theme_preview_count(2) + theme_previews + keybinding_count(2) + keybindings`.

Each option is `name_len(1) + name + type_tag(1) + value_payload`. Type tags are `0x01` boolean, `0x02` signed integer, `0x03` string, `0x04` atom encoded as a string, and `0x05` float64. Strings use a 16-bit byte length. Theme previews are `display_name_len(1) + display_name + atom_len(1) + atom + editor_bg(3) + editor_fg(3) + accent(3)`. Keybindings are `mode_len(1) + mode + key_len(2) + key + command_len(2) + command + description_len(2) + description`.

The frontend sends `config_query` when the Settings window appears. It sends `config_update` for each changed control. The BEAM applies the option immediately and persists GUI-originated changes to `~/.config/minga/gui_settings.exs`, loaded after `config.exs` and `.minga.exs` but before `after.exs`.

## Theme Color Slots

Theme colors are sent as `{slot_id, r, g, b}` tuples in the `gui_theme` opcode. The slot IDs are organized by UI domain:

The "Source" column shows which `Theme.t()` field each slot reads from (see `lib/minga_editor/ui/theme/slots.ex`). Slots that share a source will always have the same color value. Frontends that need fallback colors before the first `gui_theme` arrives can use the Doom One defaults listed below.

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

### Popups + Breadcrumb (0x20-0x2A)

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
| 0x2A | popup_sel_fg | `popup.sel_fg` | Selected item foreground |

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

### Gutter + Git (0x50-0x58, 0x62)

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
| 0x59 | highlight_read_bg | `editor.highlight_read_bg` | Document highlight background for read references |
| 0x5A | highlight_write_bg | `editor.highlight_write_bg` | Document highlight background for write references |
| 0x5B | selection_bg | `editor.selection_bg` | Selection background and text highlight fallback |
| 0x62 | gutter_fold_fg | `gutter.fold_fg` | Fold indicator color |

## Forward-Compatibility: Skip-Length for Unknown Opcodes

Standard new opcodes >= 0x90 use a 2-byte big-endian length prefix after the opcode byte:

```
<<opcode::8, payload_length::16-big, payload::binary-size(payload_length)>>
```

This allows older frontends to skip unknown standard-envelope opcodes gracefully without crashing. When a decoder encounters an opcode >= 0x90 that it doesn't recognize, it:

1. Reads the 2-byte length field
2. Skips `length` bytes forward
3. Continues decoding the next command

For opcodes < 0x90 that are unknown, the decoder must throw an error (it cannot determine the payload size). Known opcodes may document a wider envelope when the payload can exceed 64KB. `clipboard_write` (0x90) and `gui_file_tree` (0x93) are such exceptions and use a 4-byte length field.

**Example:** A BEAM running version 0.3.0 introduces a new `OP_GUI_NEW_FEATURE = 0x91`. A macOS frontend running 0.2.0 receives this opcode. Because 0x91 >= 0x90 and uses the standard envelope, it reads the length prefix, skips that many bytes, and continues. The frontend remains functional even though it doesn't render the new feature.

This convention is enforced on the BEAM side: all new opcodes >= 0x90 must use a documented length-prefixed encoding. See `lib/minga_editor/frontend/protocol/gui.ex` for the encoder implementation.

**Current 0x90+ opcodes:**
- `OP_CLIPBOARD_WRITE (0x90)` — clipboard write command (32-bit length-prefixed)
- `OP_GUI_INDENT_GUIDES (0x91)` — indent guide positions per window (16-bit length-prefixed)
- `OP_GUI_LINE_SPACING (0x92)` — renderer line spacing multiplier (16-bit length-prefixed)
- `OP_GUI_FILE_TREE (0x93)` — semantic file tree rows (32-bit length-prefixed)
- `OP_GUI_CURSOR_ANIMATION (0x95)` — cursor movement animation preference (16-bit length-prefixed)
- `OP_GUI_HOVER_ACTION (0x96)` — optional hover popup action metadata (16-bit length-prefixed)

### 0x95 — gui_cursor_animation

Sends whether GUI renderers should animate cursor movement. The frontend must still disable animation when the platform Reduce Motion accessibility setting is active.

```
opcode(1=0x95) + payload_length(2=0x0001) + enabled(1)
```

Fields:
- `enabled`: `1` enables smooth cursor movement, `0` snaps the cursor directly to the BEAM-reported position.

### 0x96 — gui_hover_action

Optional action metadata for the currently visible hover popup. The hover content stays in `gui_hover_popup` (0x81); this sidecar tells native frontends whether to render an action button without parsing display text.

```
opcode(1) + payload_len(2) + visible(1) + action_len(2) + action(action_len)
```

When `visible` is `0`, the payload is only `visible(1)` and the frontend clears any current hover action. When `visible` is `1`, `action` is stable action metadata that tells the frontend to render an Open control. The frontend sends the generic `hover_open_action` (0x3F), and the BEAM executes the current popup's stored action.

### 0x91 — gui_indent_guides

Sends indent guide column positions and per-line indent levels for one window. Each guide is a vertical line the frontend draws at the given character column. The active guide (containing the cursor) is identified so the frontend can highlight it. Per-line indent levels let the frontend draw guide segments only in leading whitespace, preventing guides from bleeding through text content.

```
opcode(1=0x91) + payload_length(2) + window_id(2) + tab_width(1) + active_guide_col(2) + guide_count(1) + guide_cols... + line_count(2) + indent_levels...

Per guide:
  col(2)

Per line:
  indent_level(1)
```

Fields:
- `window_id`: which editor window these guides belong to
- `tab_width`: the tab width used for indent computation (for frontend reference)
- `active_guide_col`: the character column of the active guide (0xFFFF = no active guide)
- `guide_count`: number of guide columns that follow
- `col`: character column offset from content start (not screen left). The frontend converts to pixel position using `col * cellWidth + gutterPixelWidth`
- `line_count`: number of visible lines with indent level data that follow
- `indent_level`: effective indent level for this visible line (0-255, capped). A guide at column `col` should only be drawn on a line whose `indent_level > col / tab_width` (strict greater-than, so guides appear only in whitespace, not at the text-start column). Blank lines inherit the indent level of the next non-blank line below them so guides span through blank lines

The `line_count` + `indent_levels` section is optional for backward compatibility. If `payload_length` does not leave room for it after the guide columns, the frontend should fall back to drawing full-height guide columns (the pre-v0.4 behavior).

The BEAM sends this per frame as part of the atomic Metal command batch. Guides are gated by the `indent_guides` config option (default `true`). When disabled, no opcode is sent.

### 0x92 — gui_line_spacing

Sends the line spacing multiplier to the GUI frontend. Sent once during startup (alongside `set_font`) and again if the user changes the config at runtime.

```
opcode(1=0x92) + payload_length(2=0x0002) + spacing_x100(2)
```

Fields:
- `spacing_x100`: the spacing multiplier times 100 as a 16-bit unsigned integer. For example, 1.0 is 100, 1.2 is 120, 1.5 is 150.

The frontend uses this to compute `displayCellH = cellH * (spacing_x100 / 100.0)` for all row positioning. Line spacing is a **draw-time rendering hint only**: it has zero influence on BEAM-side layout, viewport, or scroll math. When the spacing changes at runtime the frontend recomputes its own rows-that-fit (`floor(content_pixels / (cell_height × line_spacing))`, one floor, where the pixels live) and sends an ordinary `resize` (0x02) carrying the new content row count. The BEAM lays out in exactly those rows and never divides by the multiplier itself. This resize does not re-trigger `0x92` (the emit is fingerprint-gated on the spacing value), so there is no feedback loop. See `docs/adr/0001-frontend-owns-row-fit.md`.

## Behavioral Contract

A GUI frontend must satisfy these requirements:

1. **Send `ready` with `frontend_type = 0x01`** (native_gui) in the capabilities payload. This tells the BEAM to send GUI chrome opcodes.

2. **Render cell-grid commands to a pixel surface** (Metal, OpenGL, Vulkan). The BEAM sends editor content (buffer text, gutter, modeline for splits, minibuffer) as cell-grid commands. The GUI frontend must maintain a cell grid and render it to a texture/surface.

3. **Render GUI chrome natively.** Tab bar, file tree, status bar, breadcrumb, which-key, completion, picker, agent chat, hover popup, and signature help should be rendered using native UI frameworks (SwiftUI, GTK4, Qt). Do not render them from the cell grid.

4. **Send `gui_action` events for user interactions with chrome.** When a user clicks a tab, selects a completion item, or toggles a panel, encode the action and send it to the BEAM on stdout.

5. **Handle missing opcodes gracefully.** New GUI opcodes may be added in the 0x70-0x8F range. Frontends should skip unknown opcodes rather than crashing. New opcodes in 0x90+ use a documented length-prefixed envelope so frontends can skip unknown standard-envelope opcodes by reading the length. See "Forward-Compatible Opcodes (0x90+)" above.

6. **Process `gui_theme` before rendering other chrome.** The theme command typically arrives early in the first frame. Apply colors before rendering chrome elements to avoid a flash of unstyled content.

## Sequencing

Within a single render cycle (one `{:packet, 4}` framed batch):

1. Cell-grid commands: `clear`, `define_region`, `draw_text` (multiple), `set_cursor`, `set_cursor_shape`, `batch_end`
2. GUI chrome commands: `gui_theme` (if changed), `gui_tab_bar`, `gui_file_tree`, `gui_which_key`, `gui_completion`, `gui_breadcrumb`, `gui_status_bar`, `gui_picker`, `gui_agent_chat`, `gui_bottom_panel`, `gui_hover_popup`, `gui_signature_help`

Note: GUI chrome commands are sent after `batch_end`. They are separate from the cell-grid frame because they update native UI state, not the pixel surface. The frontend should process them after committing the cell-grid frame to the GPU.

## Implementation References

### Schema and generation

| Component | File | Language |
|-----------|------|----------|
| Opcode schema | `docs/protocol_schema.toml` | TOML |
| Opcode generator | `mix/protocol_generator.ex` and `mix/tasks/protocol.gen.ex` | Elixir |
| Generated Elixir opcodes | `.generated/protocol/elixir/lib/minga/protocol/opcodes.ex` | Elixir |
| Generated Swift opcodes | `macos/.generated/protocol/ProtocolOpcodes.generated.swift` | Swift |
| Generated Zig opcodes | `zig/src/generated/protocol_opcodes.zig` | Zig |

`docs/protocol_schema.toml` is the source of truth. Run `mix protocol.gen` to write ignored build artifacts, refresh the generated public opcode export block in `zig/src/protocol.zig`, and run `mix protocol.gen --check` to verify those outputs are present and reproducible. Local Mix, Swift harness, and Xcode build paths run generation before compiling their protocol consumers. Direct `cd zig && zig build test` expects `zig/src/generated/protocol_opcodes.zig` and `zig/src/generated/protocol_schema_test.zig` to already exist, so run `mix protocol.gen` first or use `mix zig.lint` / `mix compile`. Generated opcode files are build artifacts, not maintained source, so normal PR review should review the schema, generator, tests, and consumer code rather than line-reviewing generated constants. The Zig public export block is maintained by the generator, so adding an opcode to the schema and regenerating makes `protocol.zig` expose the matching `OP_*` or `GUI_ACTION_*` constant without a manual re-export edit.

### BEAM GUI protocol implementation

| Component | File | Language |
|-----------|------|----------|
| Encoder | `lib/minga_editor/frontend/protocol/gui.ex` | Elixir |
| Theme slot mapping | `lib/minga_editor/ui/theme/slots.ex` | Elixir |
| Integration tests | `test/minga_editor/integration/gui_protocol_test.exs` | Elixir |

### macOS GUI

| Component | File | Language |
|-----------|------|----------|
| Decoder | `macos/Sources/Protocol/ProtocolDecoder.swift` | Swift |
| Generated opcode constants | `macos/.generated/protocol/ProtocolOpcodes.generated.swift` | Swift |
| Non-opcode constants | `macos/Sources/Protocol/ProtocolConstants.swift` | Swift |
| Test harness | `macos/TestHarness/main.swift` | Swift |

### Linux GUI (planned)

The GTK4 frontend will need its own protocol decoder implementing the same opcodes. When building it, use the BEAM encoder and integration tests as the reference, not the Swift decoder (which may have platform-specific assumptions).
