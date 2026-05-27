# Phase 1: UI Models and GUI Adapter for UI Components

## Context

The rendering pipeline has 25+1 SwiftUI chrome builders in `Emit.GUI` (~2,320 lines) that each compute what's visible, fingerprint it, check a cache, and encode it. Steps 1-3 are rendering work that belongs upstream in a shared model; only step 4 (encoding) belongs in the emit layer.

This plan replaces those builders with three clean layers: **RenderModel types** (pure data, `lib/minga/`), **builders** (derive models from editor state, `lib/minga_editor/`), and **adapter encoders** (pure model-to-binary, `lib/minga/`). Each component swap deletes one old builder and its old encoder, replacing them with the new three-layer equivalent. The same binary opcodes are produced; Swift sees no change.

The work is structured as a Graphite PR stack: scaffolding first, then one PR per component swap, starting with the 6 simplest components to prove the pattern.

## Architecture

```
EditorState → Builder (lib/minga_editor/) → RenderModel.UI (lib/minga/) → Adapter.GUI (lib/minga/) → binary commands
```

- **Types** (`Minga.RenderModel.UI.*`): pure structs, no process calls, no MingaEditor imports. Layer 1 (default for `lib/minga/`).
- **Builders** (`MingaEditor.RenderModel.UI.*Builder`): extract data from `Emit.Context`, pre-resolve process calls. Layer 2 (default for `lib/minga_editor/`).
- **Encoders** (`Minga.Frontend.Adapter.GUI.*Encoder`): pure functions, model struct in, binary out. Layer 1. Use `Minga.Protocol.Opcodes` for opcode constants (already Layer 1).

Layer enforcement: Credo EX9001 (`credo/checks/dependency_direction_check.exs`) automatically assigns `lib/minga/` to Layer 1 and `lib/minga_editor/` to Layer 2. Layer 2 can import Layer 1; Layer 1 cannot import Layer 2. No changes to the check needed.

## Coexistence Mechanics

During migration, both the new adapter and the shrinking `sync_swiftui_chrome` produce commands. In `emit_gui/4` (`lib/minga_editor/frontend/emit.ex` line 62-98), between `send_window_bg` (line 90) and `sync_swiftui_chrome` (line 95):

```elixir
# New path: migrated components
ui_model = MingaEditor.RenderModel.UI.Builder.build_ui(ctx)
{core_cmds, adapter_caches} =
  Minga.Frontend.Adapter.GUI.encode_ui(ui_model, caches.adapter_gui_caches)
caches = %{caches | adapter_gui_caches: adapter_caches}
if core_cmds != [], do: MingaEditor.Frontend.send_commands(ctx.port_manager, core_cmds)

# Legacy path: unmigrated components (shrinks by one per swap)
{_ctx, caches} = EmitGUI.sync_swiftui_chrome(ctx, status_bar_data, minibuffer_data, caches)
```

Hard rule: a component is in exactly one path. The builder list in `sync_swiftui_chrome` (gui.ex line 142-167) shrinks by one per swap; `encode_ui` grows by one. They never overlap.

## PR Stack

### PR 1: Scaffolding

Create all infrastructure before any component swap. This PR changes no visible behavior: `encode_ui` returns `{[], caches}`, `build_ui` returns `%{}`.

**Create:**

| File | Module | Purpose |
|------|--------|---------|
| `lib/minga/render_model/ui.ex` | `Minga.RenderModel.UI` | Namespace root (empty for now) |
| `lib/minga/frontend/adapter/gui.ex` | `Minga.Frontend.Adapter.GUI` | Top-level `encode_ui/2` orchestrator |
| `lib/minga/frontend/adapter/gui/caches.ex` | `Minga.Frontend.Adapter.GUI.Caches` | Adapter fingerprint cache struct (starts empty) |
| `lib/minga/frontend/protocol/encoding.ex` | `Minga.Frontend.Protocol.Encoding` | Shared helpers: `encode_section/2`, `utf8_prefix_bytes/2`, `bool_to_byte/1`, `encode_string16/1` |
| `lib/minga_editor/render_model/ui/builder.ex` | `MingaEditor.RenderModel.UI.Builder` | Orchestrator: `build_ui(ctx) :: map()` |

**Modify:**

| File | Change |
|------|--------|
| `lib/minga_editor/renderer/caches.ex` | Add `adapter_gui_caches: Minga.Frontend.Adapter.GUI.Caches.new()` field to defstruct + @type |
| `lib/minga_editor/frontend/emit.ex` | Wire up coexistence block in `emit_gui/4` between lines 90 and 95 |

**Shared helpers to extract** (`Minga.Frontend.Protocol.Encoding`):
- `encode_section/2`: duplicated identically in `gui.ex` (line 2414) and `gui_window_content.ex` (line 127). Signature: `<<section_id::8, byte_size(payload)::16, payload::binary>>`.
- `utf8_prefix_bytes/2`: defined in `gui.ex` (line 3502), 33+ call sites. Handles UTF-8 boundary truncation with `"\n… [truncated]"` suffix. Extract with `valid_utf8_prefix/2` and `trim_invalid_utf8_suffix/1` helpers.
- `bool_to_byte/1`, `encode_string16/1`: trivial but used across multiple encoders.

Old `defp` copies in `gui.ex` and `gui_window_content.ex` remain during coexistence (deleting them would touch 33+ call sites for no immediate benefit). They get cleaned up in the final PR.

**Tests:**
- `test/minga/frontend/protocol/encoding_test.exs`: `encode_section`, `utf8_prefix_bytes` (within limit, over limit, invalid UTF-8), `bool_to_byte`
- `test/minga/frontend/adapter/gui_test.exs`: `encode_ui` with empty model returns `{[], caches}`
- `test/minga_editor/render_model/ui/builder_test.exs`: `build_ui` returns `%{}`
- Existing tests all pass (no behavior change)

**Verify:** `mix test`, `mix credo`

---

### PR 2: Theme (Group 1a)

Spec has a full worked example (spec lines 636-764). Simplest possible case: no state dependencies, trivial encoding.

**Capability inventory** (from `build_gui_theme_cmd`, gui.ex line 191):
- Inputs: `ctx.theme`
- Fingerprint: `phash2({theme.name, Slots.to_color_pairs(theme)})`
- Cache field: `last_gui_theme` in Renderer.Caches
- Skip: fingerprint match → `{nil, caches}`
- Encoding: `ProtocolGUI.encode_gui_theme(theme)` → `<<0x74, count::8, entries...>>` where each entry is `<<slot::8, r::8, g::8, b::8>>`
- State deps: none

**Create:**

| File | Module |
|------|--------|
| `lib/minga/render_model/ui/theme.ex` | `Minga.RenderModel.UI.Theme` — struct: `color_pairs: [{slot_id, rgb}]` |
| `lib/minga_editor/render_model/ui/theme_builder.ex` | `MingaEditor.RenderModel.UI.ThemeBuilder` — `build(ctx) :: Theme.t()`. Calls `Slots.to_color_pairs`, rejects nils. |
| `lib/minga/frontend/adapter/gui/theme_encoder.ex` | `Minga.Frontend.Adapter.GUI.ThemeEncoder` — `encode(Theme.t()) :: binary()`. Opcode `Opcodes.gui_theme()` (0x74). |

**Modify:**

| File | Change |
|------|--------|
| `lib/minga/frontend/adapter/gui/caches.ex` | Add `last_theme_fp: nil` |
| `lib/minga/frontend/adapter/gui.ex` | Add theme encoding to `encode_ui/2` with fingerprint check |
| `lib/minga_editor/render_model/ui/builder.ex` | Add `theme: ThemeBuilder.build(ctx)` to `build_ui/1` |
| `lib/minga_editor/frontend/emit/gui.ex` | Remove `&build_gui_theme_cmd/2` from builders list (line 143). Delete `build_gui_theme_cmd/2` (lines 191-207). |

**Tests:**
- Builder: doom_one theme → non-empty `color_pairs`, nils filtered
- Encoder: hand-built `%Theme{color_pairs: [{1, 0xFF0000}]}` → assert `<<0x74, 1, 1, 0xFF, 0x00, 0x00>>`
- Encoder: empty pairs → `<<0x74, 0>>`
- Fingerprint: same model twice → second returns nil (skip)

**Delete:** old theme tests that call `ProtocolGUI.encode_gui_theme/1` directly; replace with encoder tests.

---

### PR 3: Breadcrumb (Group 1b)

**Capability inventory** (gui.ex line 674):
- Inputs: active buffer file path + file tree root
- Fingerprint: `phash2({file_path, root})`
- Cache: `last_gui_breadcrumb_fp`
- Encoding: `<<0x75, segment_count::8, segments...>>` where each segment is `<<len::16, text::binary>>`
- State deps: `Buffer.file_path(buf)` process call in `active_buffer_path/1` (line 693) → **moves to builder**
- Nil path: `<<0x75, 0::8>>`

**Create:**

| File | Module |
|------|--------|
| `lib/minga/render_model/ui/breadcrumb.ex` | `Minga.RenderModel.UI.Breadcrumb` — `segments: [String.t()] \| nil` |
| `lib/minga_editor/render_model/ui/breadcrumb_builder.ex` | Pre-resolves `Buffer.file_path(buf)`, computes `Path.relative_to(root) \|> Path.split()` |
| `lib/minga/frontend/adapter/gui/breadcrumb_encoder.ex` | Pure binary from segments. Opcode 0x75. |

**Swap:** Remove `&build_gui_breadcrumb_cmd/2` (line 151), delete `build_gui_breadcrumb_cmd/2` (lines 673-698) including `active_buffer_path/1`.

---

### PR 4: Which-Key (Group 1c)

**Capability inventory** (gui.ex line 608):
- Inputs: `ctx.shell_state.whichkey`
- States: visible (bindings paginated at 20/page) or hidden
- Fingerprint: `phash2(wk)`
- Cache: `last_gui_which_key_fp`
- Encoding: `<<0x72, show_flag::8, prefix_len::16, prefix, page::8, page_count::8, binding_count::16, bindings...>>`. Each binding: `<<kind::8, key_len::8, key, desc_len::16, desc, icon_len::8, icon>>`.
- State deps: `WhichKey.bindings_from_node(node)` called during encoding → **moves to builder** (pagination logic too)

**Create:**

| File | Module |
|------|--------|
| `lib/minga/render_model/ui/which_key.ex` | `Minga.RenderModel.UI.WhichKey` — `visible`, `prefix`, `page`, `page_count`, `bindings` (pre-paginated) |
| `lib/minga_editor/render_model/ui/which_key_builder.ex` | Pre-resolves `bindings_from_node`, paginates at 20/page, maps to plain maps |
| `lib/minga/frontend/adapter/gui/which_key_encoder.ex` | Pure binary. Opcode 0x72. |

**Swap:** Remove `&build_gui_which_key_cmd/2` (line 149), delete function (lines 607-616).

---

### PR 5: Notifications (Group 1d)

**Capability inventory** (gui.ex line 1766):
- Inputs: `ctx.notifications` (NotificationCenter.t())
- Fingerprint: `phash2(ctx.notifications)`
- Cache: `last_gui_notifications_fp`
- Encoding: `<<0x99, payload_len::16, version::8, count::16, notifications...>>`. Each notification: id, level byte, flags byte, timestamps (u64), auto_dismiss_ms (u32), title/body/source (string16), action_count, actions.
- State deps: none
- Note: `bounded_notification_bins/1` (gui.ex line 4479) enforces u16 payload size limit. This logic moves to the encoder (it's encoding concern, not model concern).
- Level mapper: `:info→0, :warning→1, :error→2, :success→3, :progress→4`

**Create:**

| File | Module |
|------|--------|
| `lib/minga/render_model/ui/notifications.ex` | `Minga.RenderModel.UI.Notifications` — `items: [notification()]` with pre-resolved fields |
| `lib/minga_editor/render_model/ui/notifications_builder.ex` | Maps NotificationCenter items to model structs |
| `lib/minga/frontend/adapter/gui/notifications_encoder.ex` | Ports bounded_notification_bins and level_byte mapper. Opcode 0x99. |

**Swap:** Remove `&build_gui_notifications_cmd/2` (line 159), delete function (lines 1765-1774).

---

### PR 6: Search State (Group 1e)

**Capability inventory** (gui.ex line 2132):
- Inputs: `ctx.search.gui_search`, search pattern, match stats
- Fingerprint: `phash2({active?, match_count, current_index, gui_search})`
- Cache: `last_gui_search_state_fp`
- Encoding: `<<0x9E, payload_len::16, active::8, match_count::16, current_index::16, flags::8>>`. Flag bits: replace_mode=0x01, case_sensitive=0x02, whole_word=0x04, regex=0x08.
- State deps: `compute_search_stats/3` (gui.ex lines 2165-2193) calls `Buffer.content(buf)`, `Buffer.cursor(buf)`, `Editing.Search.find_all_in_range/4` → **all move to builder**

**Create:**

| File | Module |
|------|--------|
| `lib/minga/render_model/ui/search_state.ex` | `Minga.RenderModel.UI.SearchState` — `active`, `match_count`, `current_index`, `case_sensitive`, `whole_word`, `regex`, `replace_mode` |
| `lib/minga_editor/render_model/ui/search_state_builder.ex` | Pre-resolves search stats. `compute_search_stats/3` and `find_current_match_index/2` move here. |
| `lib/minga/frontend/adapter/gui/search_state_encoder.ex` | Pure binary, flag byte from booleans. Opcode 0x9E. |

**Swap:** Remove `&build_gui_search_state_cmd/2` (line 167), delete function (lines 2132-2211) including `compute_search_stats/3` and `find_current_match_index/2`.

---

### PR 7: Git Status (Group 1f)

**Capability inventory** (gui.ex line 567):
- Inputs: `ctx.shell_state.git_status_panel`, `ctx.git_syncing`, `ctx.git_toast`
- States: repo (full status) or not-a-repo
- Fingerprint: `phash2(enriched_map)` for repo, `{:no_git, syncing, toast}` for non-repo
- Cache: `last_gui_git_status_fp`
- Encoding: `<<0x85, repo_state::8, syncing::8, ahead::16, behind::16, branch_len::16, branch, entry_count::16, entries..., toast_binary, base_path, last_commit_msg, stash_count::16>>`. Each entry: `<<path_hash::32, section::8, status::8, path_len::16, path>>`.
- State deps: none (git data pre-fetched into shell state)
- Note: uses `utf8_prefix_bytes/2` for path truncation → use shared helper from `Minga.Frontend.Protocol.Encoding`
- Enum mappers: `encode_repo_state/1` (3 values), `encode_status_section/1` (4 values), `encode_file_status/1` (8 values), `encode_toast_level/1`, `encode_toast_action/1` → these map atoms to bytes, pure, live in encoder

**Create:**

| File | Module |
|------|--------|
| `lib/minga/render_model/ui/git_status.ex` | `Minga.RenderModel.UI.GitStatus` — repo_state, syncing, branch, ahead/behind, entries (pre-computed section/status bytes), toast, stash_count |
| `lib/minga_editor/render_model/ui/git_status_builder.ex` | Pre-computes entry section/status bytes (avoids encoder depending on `Minga.Git.StatusEntry` types) |
| `lib/minga/frontend/adapter/gui/git_status_encoder.ex` | Uses `Protocol.Encoding.utf8_prefix_bytes/2`. Opcode 0x85. Atom-to-byte mappers are local private functions. |

**Swap:** Remove `&build_gui_git_status_cmd/2` (line 148), delete both clauses (lines 566-603) and `git_status_panel_map/1` (lines 560-562).

---

### Groups 2-9 (PRs 8-27): Follow Established Pattern

Each PR follows the same structure: create type + builder + encoder, wire into orchestrator + adapter, remove from `sync_swiftui_chrome`, test at both boundaries.

| PR | Component | Key Complexity |
|----|-----------|----------------|
| 8 | Agent context | Proves MingaAgent boundary: builder extracts from `ctx.agent_ui`, no MingaEditor.Agent imports in encoder |
| 9 | Status bar | Largest encoder (12 section types), receives `StatusBarData` from Chrome stage. Many enum mappers. |
| 10 | Observatory | 32-bit payload length envelope, BEAM system observer data |
| 11 | Board | Card list encoding, zoomed state handling |
| 12 | Tab bar | Pre-resolves `Buffer.dirty?/1` per tab. Board shell suppresses tab bar. |
| 13 | Workspaces | Workspace summary mapping |
| 14 | Sidebars | 32-bit payload envelope, sidebar registry |
| 15 | File tree | Most complex single component: rows, diagnostics, selection, multi-state (loading/ready/error/empty). Multiple sub-commands (tree data + selection update). |
| 16 | Picker | Candidate list, preview content sub-command |
| 17 | Minibuffer | Receives `MinibufferData` from Chrome stage, content hash fingerprinting |
| 18 | Completion | Pre-resolves `Buffer.cursor/1`, `Buffer.line_count/1`, gutter width |
| 19 | Signature help | Markdown segment encoding (shared with hover) |
| 20 | Agent chat | Largest encoding of any component. Sectioned format, message history, tool calls, streaming. |
| 21 | Bottom panel | Special: returns updated `ctx` (message_store cursor advancement). Builder returns `{model, side_effects}`. |
| 22 | Change summary | Diff review state, hunks, file changes |
| 23 | Edit timeline | Simple list encoding |
| 24 | Extension overlay | Extension overlay registry |
| 25 | Extension panel | Extension panel content |
| 26 | Hover popup | Markdown content encoding |
| 27 | Float popup | Similar to hover popup |

### PR 28: Final Cleanup

- Delete `MingaEditor.Frontend.Emit.GUI` entirely (all builders migrated)
- Delete `sync_swiftui_chrome/4` and `build_gui_bottom_panel_cmd/2`
- Move all remaining `last_gui_*` fields from `MingaEditor.Renderer.Caches` to `Minga.Frontend.Adapter.GUI.Caches`; remove from Renderer.Caches
- Delete migrated `encode_gui_*` functions from `ProtocolGUI` (gui.ex)
- Delete old `defp encode_section/2` and `defp utf8_prefix_bytes/2` from gui.ex and gui_window_content.ex (replaced by shared module)
- Remove coexistence branching from `emit_gui/4`
- Delete old tests that tested the removed code paths

## Key Design Decisions

1. **Entry pre-computation in builders.** For git status, the builder pre-computes `section` and `status` as integer byte values rather than having the encoder know about `Minga.Git.StatusEntry` struct semantics. Same principle for which-key (bindings pre-resolved), breadcrumb (file_path pre-resolved), search state (stats pre-resolved). Keeps encoders Layer 1 clean.

2. **Two cache structs during coexistence.** `adapter_gui_caches` field on `Renderer.Caches` carries the core adapter's cache. Each swap removes one `last_gui_*` from Renderer.Caches and adds the equivalent to Adapter.GUI.Caches. Consolidated in PR 28.

3. **Fingerprint in the adapter, not the builder.** The adapter's `encode_ui/2` computes `phash2(model)` and compares to cached fingerprint. If unchanged, returns nil (no command). The builder always produces a model. For trivial builders (theme, breadcrumb), this is fine. For expensive builders (file tree, agent chat in later PRs), the builder itself short-circuits on unchanged inputs, returning a cached model.

4. **Shared encoding helpers in scaffolding.** `encode_section/2` and `utf8_prefix_bytes/2` are extracted to `Minga.Frontend.Protocol.Encoding` in PR 1 so they're available from the first component swap. The old `defp` copies coexist until PR 28.

5. **No partial migration.** When a component is swapped, both the old builder AND old encoder are deleted. The new path produces the same opcode and wire format. Swift sees no change.

## Verification Strategy

**Per PR:**
- `mix test` (full suite, existing tests must pass)
- `mix credo` (layer enforcement, no violations)
- Builder tests: specific inputs → assert model struct fields
- Encoder tests: hand-built model → assert binary pattern matches existing wire format
- Visual verification: launch Minga GUI, confirm the migrated component renders identically (theme colors, breadcrumb path, which-key overlay, notification toasts, search status, git status panel)

**End-to-end after Group 1 (PR 7):**
- Confirm 6 components route through the new adapter path
- Confirm the remaining 20 components still work through `sync_swiftui_chrome`
- Run full test suite
- Open a file with git changes, trigger a search, toggle which-key, trigger a notification: all 6 migrated components visible simultaneously
