# `MingaEditor` lifecycle and complexity audit

The editor layer has real correctness gaps hidden among several thousand lines of migration residue. The highest-risk problems are failed saves that still quit, dirty buffers that can be destroyed without confirmation, asynchronous LSP and completion results that can land in the wrong context, and frontend frame rejections that are decoded but never reach the renderer. The largest accepted reductions are the legacy 0x78 transcript payload, dead render invalidation and cell-gutter machinery, oversized legacy protocol encoders with canonical adapter replacements, no-op lifecycle hooks, and compatibility APIs whose canonical replacements are already live. Larger dormant frontend, FeatureState, and public-boundary candidates remain routed or preserved until their product, architecture, migration, or compatibility decisions are made.

This report audits every Elixir file under `lib/minga_editor/` at revision `ebc07203a`. It records evidence-backed pre-gate candidates after repository-wide caller checks, then uses the independent Ponytail gate in the final section to accept, preserve, route, or reject each candidate before implementation work is scoped.

## Scope and method

- Scope: all `lib/minga_editor/**/*.ex` files.
- Coverage: 537 of 537 files, 124,158 lines.
- Assignment: every file appeared exactly once in `/tmp/minga-editor-audit-manifest.tsv`; the manifest had no missing, extra, or duplicate paths.
- Verification surfaces: `lib/`, `extensions/`, `macos/`, `go/`, `test/`, protocol schema and documentation, extension SDK mirrors, command registries, keymaps, and dynamic dispatch sites.
- Review lens: lifecycle ownership, stale asynchronous work, process and timer identity, redundant state, impossible defensive branches, stale migrations, no-op commands, dead protocol surfaces, unnecessary abstraction, and completely removable files.
- Exclusions: generated, vendored, dependency, and build output were not audited as source, though generated protocol consumers were checked when needed to prove a wire claim.
- Evidence standard: size alone is not a finding. A deletion requires repository-wide non-use or proof that a newer owner replaced it. A correctness finding requires a concrete producer-to-consumer failure path.

| Bucket | Files | Lines | Result |
| --- | ---: | ---: | --- |
| Agent | 41 | 11,424 | Complete |
| Commands | 34 | 19,080 | Complete |
| Frontend models | 50 | 13,068 | Complete |
| Input handlers | 54 | 14,140 | Complete |
| Orchestration | 74 | 14,289 | Complete |
| Render core | 44 | 10,198 | Complete |
| State and shell | 115 | 21,007 | Complete |
| UI and services | 125 | 20,952 | Complete |

## Priority 0: lifecycle and correctness failures

### L01. Frontend rejection tuples are decoded but dropped before renderer recovery

`Frontend.Protocol.decode_event/1` returns six-element `{:frame_rejected, generation, frame_seq, last_applied, reason, disposition}` tuples, including normalized protocol-v11 frames. `MingaEditor.handle_info/2` forwards only five-element rejection tuples, so current rejection tuples fall through the generic `:minga_input` highlight dispatcher and never reach `Renderer.AckHandler`. This makes retry, terminal rejection, and adapted-retry handling unreachable from real frontend traffic. [lib/minga_editor/frontend/protocol.ex:562-576, lib/minga_editor.ex:743-750, lib/minga_editor.ex:856-860, lib/minga_editor/renderer/ack_handler.ex:27-57]

Safe action: forward the current six-element shape and retain five-element compatibility only if a real internal sender still exists. Add an end-to-end decoder-to-renderer test. Risk: high, because the current path loses frame recovery events.

### L02. `:wq` and `:wqa` exit after failed saves

`:wq` pipes the state returned by `:save` directly into close/quit, while `:wqa` ignores every `Buffer.save/1` result and always shuts down. The save API reports failures only through mutated UI state, so callers cannot distinguish success from failure. [lib/minga_editor/commands/buffer_management.ex:64-88, 308-314, 2099-2110]

Safe action: introduce one explicit save-result contract for `:save`, `:wq`, and `:wqa`; close only after every required write succeeds. Risk: high because save currently mixes formatting, conflict handling, notices, and side effects.

### L03. Quit and save-all inventory ignores inactive tab contexts

Dirty checks and save-all enumerate only `state.workspace.buffers.list`, while inactive tabs persist their own `Buffers` snapshots. `:quit_all`, wait-request disposition, and `:wqa` can therefore miss dirty buffers retained by inactive contexts. [lib/minga_editor/commands/buffer_management.ex:1921-1930, 2099-2110, lib/minga_editor/state/tab/context.ex:79-102, lib/minga_editor/state.ex:390-410]

Safe action: define one root-level de-duplicated live-buffer inventory across active and stashed contexts. Risk: high and architecture-sensitive because buffer ownership spans workspaces, tabs, windows, monitors, and process retirement.

### L04. `kill_buffer` destroys dirty buffers without confirmation

The command routes directly to process retirement, never checks `Buffer.dirty?/1`, and remains reachable from keymaps, mouse actions, GUI actions, and the command palette. Wait requests report the loss after the fact but do not prevent it. [lib/minga_editor/commands/buffer_management.ex:197-204, 1063-1143, 2122-2155]

Safe action: refuse or confirm ordinary dirty destruction and provide an explicit force-kill path. Risk: high because this is direct data loss.

### L05. Dired stores a backing PID but save and close use the active buffer

Dired state records its backing buffer, but save routing checks only `dired.active?`, and close invokes generic `:kill_buffer` rather than retiring the stored PID. A stale scope or tab switch can save or kill the wrong buffer. [lib/minga_editor/commands/buffer_management.ex:56-62, lib/minga_editor/commands/dired.ex:245-284, lib/minga_editor/state/dired.ex:12-33]

Safe action: require active-buffer identity for Dired save, explicitly retire the stored PID, and clear Dired state when that PID dies. Risk: medium-high.

### L06. Ordinary LSP responses can apply to the wrong buffer or tab

Most requests store only `request_ref => kind`; response handlers apply results against current editor state. Delayed definition, hover, rename preparation, selection range, document highlight, code-lens, and inlay-hint results can target a different context, and a definition response after the last buffer closes can call buffer APIs with `nil`. Pending request maps are also snapshotted into tabs. [lib/minga_editor/lsp_actions.ex:1843-1870, 1893-1918, lib/minga_editor/handlers/lsp_event_handler.ex:154-212]

Safe action: use one editor-global request record carrying kind, client, origin buffer, version, tab, cursor, and operation-specific data; take each response exactly once and validate its relevant identity. Risk: high.

### L07. Completion identity is incomplete before and after processing

Debounce messages lack a generation, completion responses calculate prefixes from the current active buffer, item resolve stores only an atom and updates the item selected when the response arrives, and signature-help responses lack origin identity. Moving buffers or selection can apply stale results to the wrong modal item. [lib/minga_editor/completion_trigger.ex:239-258, lib/minga_editor/completion_handling.ex:82-136, 573-588, 893-916, lib/minga_editor/handlers/lsp_event_handler.ex:43-57]

Safe action: carry debounce generation, buffer PID/version, completion generation, stable item identity, and signature cursor. Keep the existing processed-result generation check. Risk: high.

### L08. Empty and stale LSP decoration responses retain or misapply decorations

Empty code-lens and inlay-hint results return before clearing previous groups. Results are not strongly correlated by origin buffer/version, so delayed responses can decorate the current buffer with another buffer’s positions. [lib/minga_editor/lsp_decorations.ex:25-84]

Safe action: correlate by origin and explicitly clear cached values and decoration groups for current empty results. Risk: high.

### L09. Semantic-token and tree-sitter highlighting is order-dependent

Semantic spans merge into the current highlight tuple, but later tree-sitter updates replace the entire tuple. There is no guaranteed fresh semantic request on normal edits, while a late old semantic response can merge stale ranges into newer syntax spans. [lib/minga_editor/semantic_token_sync.ex:41-139, lib/minga_editor/ui/highlight.ex:137-146, lib/minga_editor/handlers/highlight_handler.ex:53-58]

Safe action: track syntax and semantic layers independently, correlate semantics to buffer version/generation, and compose accepted layers. Risk: high.

### L10. Keep-open picker refreshes retain stale scoring candidates

`PickerUI.refresh_items/1` replaces items but leaves normalized candidates unchanged before filtering. Tool Manager can show old status/IDs after an install and repeat the wrong action. [lib/minga_editor/picker_ui.ex:896-903, lib/minga_editor/ui/picker.ex:97-123]

Safe action: replace items and candidates atomically while preserving query and clamping selection. Risk: high.

### L11. Picker mode switching bypasses async lifecycle ownership

Prefix-based source switching calls source callbacks directly, bypassing loading/error state, fetch revisions, latest-wins correlation, scheduler admission, and cancellation. Project search can run synchronously on the Editor input loop. [lib/minga_editor/picker_ui.ex:950-1019, lib/minga_editor/ui/picker/file_source.ex:27-32, lib/minga_editor/ui/picker/project_search_source.ex:31-53]

Safe action: route source switching through the same async-aware opening primitive as initial open, or remove prefix switching if it is no longer a product requirement. Risk: high.

### L12. The diagnostics picker always returns no items

The source still matches full `EditorState`, but picker sources receive `Picker.Context`; the fallback returns `[]`, making both registered command routes silently do nothing. [lib/minga_editor/ui/picker/sources/diagnostics.ex:29-35, lib/minga_editor/ui/picker/context.ex:35-75, lib/minga_editor/commands/diagnostics.ex:31-38, lib/minga_editor/commands/ui.ex:48-52]

Safe action: match the current context shape and add a command-level regression test. Risk: high user-visible failure, low implementation risk.

### L13. Disabling prettify-symbols leaves old conceals installed

The effect skips all work when disabled even though the underlying service can idempotently remove the conceal group. No option-change cleanup exists. [lib/minga_editor/ui/prettify_symbols_effect.ex:50-61, lib/minga_editor/ui/prettify_symbols.ex:128-143]

Safe action: clear the buffer-scoped conceal group when disabled. Risk: medium-high visual correctness.

### L14. Git status refreshes can steal sidebar focus

Each visible Git panel registration marks itself focused, and every background data replacement re-synchronizes that registration. Visibility and focus are conflated. [lib/minga_editor/sidebar/builtin_surfaces.ex:100-123, lib/minga_editor/shell/traditional/sidebar_workflow.ex:43-52]

Safe action: only explicit activation changes focus; background refresh changes content and visibility. Risk: high keyboard instability.

### L15. Split popup sizing always falls back to 24 by 80

The split path matches a nonexistent top-level viewport instead of `state.frontend.terminal_viewport`, which the same module already uses for float hit testing. [lib/minga_editor/ui/popup/lifecycle.ex:391-392]

Safe action: read the frontend-owned viewport. Risk: medium.

### L16. Remote buffer registrations outlive buffer processes

`State.Remote` owns `{server, path} => buffer_pid`, but root buffer retirement does not remove dead PIDs from this index. Remote workflows can retrieve stale PIDs later. [lib/minga_editor/state/remote.ex:18-70, lib/minga_editor/state.ex:267-292, lib/minga_editor/commands/remote_files.ex:68-83, lib/minga_editor/agent/file_event_workflow.ex:228-289]

Safe action: add `Remote.retire_buffer/2` to the root retirement transaction. Risk: high correctness, low implementation risk.

### L17. Workspace and tab remote/session metadata are independently writable

Agent session PID, status, server, remote session ID, and connection status exist on both Workspace and Tab with public mutation paths. Some workflows update both; others update one. [lib/minga_editor/state/tab.ex:40-219, lib/minga_editor/state/workspace.ex:40-228, lib/minga_editor/state/tab_bar.ex:403-436, 618-683, 1092-1162]

Safe action: make Workspace authoritative and project display metadata into matching tabs after each transition. Risk: high reconnect and teardown drift.

### L18. “Durable” remote session identity is not persisted

Workspace persistence omits server, session ID, connection status, and `last_seen_event_id`, although `Workspace.RemoteSession` owns the reconnect cursor. Restored workspaces cannot resume the claimed lifecycle. [lib/minga_editor/state/workspace/remote_session.ex:1-47, lib/minga_editor/state/workspace.ex:377-415, lib/minga_editor/handlers/event_dispatcher.ex:696-716]

Safe action: either persist optional non-PID metadata with backward-compatible defaults or narrow the durability promise. Risk: medium-high.

### L19. Agent tool-collapse actions use a transient suffix index

Both frontends send a local resident-array index, while the BEAM applies it to the full transcript. Once the resident suffix trims the front, clicking index zero can toggle an unrelated full-transcript message. Stable message IDs already exist. [lib/minga_editor/render_model/ui/agent_chat_builder.ex:68-116, macos/Sources/Views/Agent/AgentChatView.swift:145-168, go/tui/internal/ui/model.go:1160-1166, lib/minga_editor/handlers/gui_action_handler.ex:603-614, lib/minga_agent/session.ex:1350-1364]

Safe action: send stable `message_id` and resolve it in the BEAM transcript. Risk: high correctness, medium protocol migration.

### L20. Signature Help tests the Alt bit instead of Control

Current frontends encode Control as `0x02`; Signature Help hardcodes `4`, so documented Ctrl-J/Ctrl-K clauses cannot match normal GUI input. [lib/minga_editor/input/signature_help.ex:17-39, lib/minga_editor/input.ex:307-313, lib/minga_editor/frontend/protocol.ex:86,223-224]

Safe action: use `Input.mod_ctrl/0`. Risk: low.

### L21. Ctrl-G does not clear all focus owners

Interrupt resets modal/keymap state but leaves bottom-panel focus, agent prompt focus, file-tree focus, sidebar focus, and pending TUI space-leader state. The next key can still be swallowed by stale ownership. [lib/minga_editor/input/interrupt.ex:55-179, lib/minga_editor/input/bottom_panel.ex:19-55, lib/minga_editor/input/agent_panel.ex:34-48, lib/minga_editor/input/cua/tui_space_leader.ex:120-133]

Safe action: invoke each owner’s authoritative blur/cancel transition and decide explicitly whether panels hide or only lose focus. Risk: medium.

### L22. Resize drag and release cleanup can be lost

Router bypasses normal hit routing only for text selection drags, not resize drags. If the pointer leaves the tree or the active buffer disappears, release can return before clearing drag/resize state. [lib/minga_editor/input/router.ex:357-382, lib/minga_editor/mouse.ex:185-239, 336-379]

Safe action: directly route both drag kinds and run release cleanup before the no-buffer guard. Risk: medium.

### L23. Tool-status timers can dismiss newer operations

Old bare `:clear_tool_status` messages infer ownership from message prefixes and can clear a newer install/success notice. Notifications already use reference correlation correctly. [lib/minga_editor/handlers/tool_handler.ex:52-117, lib/minga_editor/handlers/notifications.ex:58-75]

Safe action: include a generation/reference in the timer and reject stale deliveries. Risk: low.

### L24. Buffer lookup-to-use races remain in watcher and input snapshots

File watcher catches exit while searching but then performs unprotected `:sys.get_state/1`; Router catches cursor access but not `Buffer.version/1`. A buffer can die between lookup and use. [lib/minga_editor/file_watcher_helpers.ex:25-37,145-155, lib/minga_editor/input/router.ex:54-61,309-316,510-514]

Safe action: add targeted `:exit` handling only around process-backed calls. Risk: medium.

### L25. Native IPC leaks socket paths after partial initialization failure

The listener and socket path exist before descriptor publication and before a GenServer state is available; cleanup runs only in `terminate/2`. Chmod, validation, identity, or publication failure can leave the AF_UNIX path behind. [lib/minga_editor/native_ipc/server.ex:49-103]

Safe action: stage initialization with rollback for listener, socket path, temporary descriptor, and published current descriptor. Risk: medium.

### L26. Render intent silently loses Git synchronization state

`Input` snapshots `effect_scheduler`, `FrameIntent` omits it, and materialization restores `nil`; Emit then cannot compute `git_syncing`. Passing the scheduler process would also violate the narrow boundary. [lib/minga_editor/render_pipeline/input.ex:89,207, lib/minga_editor/render_pipeline/frame_intent.ex, lib/minga_editor/renderer/buffer_changes.ex:217-238, lib/minga_editor/frontend/emit/context.ex:185]

Safe action: snapshot and carry a boolean `git_syncing`. Risk: low.

### L27. Triple-click line selection bypasses authoritative hit testing

A local row-plus-scroll calculation ignores wrapping, folds, virtual blocks/text, and per-window mapping already handled by `Mouse.HitTest`. [lib/minga_editor/mouse.ex:905-941,1625-1648, lib/minga_editor/mouse/hit_test.ex:31-420]

Safe action: resolve the target through `HitTest.resolve_buffer/3`. Risk: medium; add wrapped/folded characterization tests.

### L28. Resident transcript truncation is never communicated to users

Both frontends decode and store the 0x86 `truncated` flag, but neither renders or announces it. The flag is necessary because local scroll history may be incomplete. [macos/Sources/Views/Agent/AgentChatState.swift, go/tui/internal/ui/agent_transcript.go]

Safe action: show an accessible frontend-owned “older messages omitted” indicator. Risk: low, additive.

### L29. Theme override validation omits two color fields

`editor.link_fg` and `gutter.advisory_fg` are absent from Builder color metadata, allowing invalid user values past construction. [lib/minga_editor/ui/theme/builder.ex:46-70]

Safe action: add both fields and invalid-value tests. Risk: low.

### L30. Title construction performs unused and dead-PID-unsafe buffer calls

Title context fetches `filetype` but never uses it, and most branches do not use the dead-buffer fallback common at other render metadata boundaries. [lib/minga_editor/title.ex:66-121]

Safe action: remove `filetype` and centralize the remaining process-backed reads behind one targeted exit-safe helper. Risk: low.

## Deletion candidates and dormant subsystems

| ID | Tag | Finding and evidence | Smallest safe action | Risk / estimate |
| --- | --- | --- | --- | --- |
| D01 | `delete` | FeatureState has no production writer, extension user, or SDK API, yet drives validation, cleanup, shell callbacks, tab propagation, and migration plumbing. [lib/minga_editor/feature_state.ex, lib/minga_editor/feature_state_workflow.ex] | Remove the subsystem and retain only a narrow legacy file-tree decoder if persisted contexts still need it. | Medium migration risk, about 320–450 production lines. |
| D02 | `delete` | Change Summary is permanently empty, but retains model, builder, encoder, cache, action, Swift/Go state and views, docs, and tests; clicks are unhandled. [lib/minga_editor/render_model/ui/change_summary_builder.ex, lib/minga_editor/render_model/ui/builder.ex:80, lib/minga_editor/frontend/protocol/gui.ex:2469-2470] | Delete the cross-frontend subsystem unless there is an approved near-term owner. | Low runtime, medium product risk, about 500–800 lines. |
| D03 | `delete` | Native Tool Manager has no production encoder caller or semantic model; picker workflows are the live tool UI and `tool_dismiss` is a no-op. [lib/minga_editor/frontend/protocol/gui.ex:2830-2881, lib/minga_editor/handlers/gui_action_handler.ex:597-601] | Remove native panel protocol/view/action support; keep picker workflows. | Low, about 450–750 lines. |
| D04 | `delete` | 0xA3 extension runtime has no BEAM producer; only tests manufacture frames while real extension panels/overlays/sidebars are live. [lib/minga_editor/frontend/protocol/gui.ex:890-897, macos/Sources/Extensions/FrontendExtensionRuntime.swift] | Delete opcode, encoder, client registries/store, docs, and tests after public-API check. | Low in-tree, about 350–650 lines. |
| D05 | `delete` | Both frontends use 0x86 resident transcripts, while the 0x78 messages section is still built, encoded, decoded, and retained as fallback. [lib/minga_editor/render_model/ui/agent_chat_builder.ex:61-106, macos/Sources/Renderer/CommandDispatcher.swift:932-949, go/tui/internal/ui/agent_chat_panel.go:527-535] | Remove only 0x78 section 0x06 and its slicing/fallback; keep 0x78 status, prompt, visibility, help, and focus. | Medium, about 300–500 lines. |
| D06 | `shrink` | `Protocol.GUI` remains a 3,316-line outbound parity facade; production uses only action decoding, settings projection, search flags, config state, and clipboard write. [lib/minga_editor/frontend/protocol/gui.ex] | Extract the live core and replace self-comparison tests with schema goldens and cross-frontend decode tests. | Medium, about 1,800–2,200 lines excluding D02–D04. |
| D07 | `delete` | `Frontend.Adapter` has one implementation, `shell.gui_payload/1` always returns nil, and `RenderModel.Builder.build_windows/2` has no caller. [lib/minga_editor/frontend/adapter.ex, lib/minga_editor/frontend/emit/context.ex:192-206, lib/minga_editor/render_model/builder.ex:33-43] | Call Manager directly and remove nil compatibility branches and unused helper. | Low, about 120–170 lines. |
| D08 | `delete` | RenderPipeline Invalidation and WindowDirty are referenced only by each other and tests; Stage 1 is an identity function and live invalidation belongs to WindowCache/epochs. [lib/minga_editor/render_pipeline/invalidation.ex, lib/minga_editor/render_pipeline/window_dirty.ex, lib/minga_editor/render_pipeline.ex:233-238] | Delete files/tests and update stage documentation/telemetry naming. | Low, about 170 production lines. |
| D09 | `delete` | Cell-era gutter sign/number drawing and `Gutter.SignContext` have no production consumer; only geometry helpers remain live. [lib/minga_editor/renderer/gutter.ex, lib/minga_editor/renderer/gutter/sign_context.ex] | Keep a small geometry module and delete painter code/tests. | Low, about 250–275 production lines. |
| D10 | `delete` | `Renderer.Caps` is test-only future capability adaptation. [lib/minga_editor/renderer/caps.ex] | Delete file/tests and reintroduce at adapter boundary when used. | Low, about 77 production lines. |
| D11 | `delete` | Six emit tracking maps and `block_render_cache` are write-only; several WindowCache resident/snapshot fields are unused. [lib/minga_editor/renderer/caches.ex, lib/minga_editor/frontend/emit.ex:218-263, lib/minga_editor/renderer/window_cache.ex] | Remove only proven write-only fields; retain title/background/link-cursor dedupe. | Low, about 80–110 lines. |
| D12 | `yagni` | Adapted-retry producer APIs and targeted-replacement-in-frame-rejected cannot occur with either live frontend; `window_ref_miss` is the real targeted path. [lib/minga_editor/renderer/ack_handler.ex, recovery_handler.ex, rejection_state.ex, state.ex, server.ex] | Remove local adaptation machinery without renumbering public wire enums; fail closed on unsupported dispositions. | Medium protocol risk, about 180–250 lines. |
| D13 | `delete` | `BufferLifecycle`, parser `maybe_reparse`, parser `handle_spans`, and agent highlight startup are no-op or uncalled compatibility paths replaced by buffer events and event-driven parser sync. [lib/minga_editor/buffer_lifecycle.ex, lib/minga_editor/highlight_events.ex, lib/minga_editor/agent_lifecycle.ex:115-121] | Delete functions, delegates, and callers. | Low, about 55–75 lines. |
| D14 | `delete` | FloatingWindow still carries title/footer/content/border/theme/backdrop for a removed painter, and MarkdownStyles exists only to build ignored content. [lib/minga_editor/floating_window.ex, lib/minga_editor/markdown_styles.ex] | Reduce Spec to geometry and compute dimensions from parsed content. | Medium geometry parity risk, about 150–220 lines. |
| D15 | `yagni` | BottomPanel models diagnostics and terminal tabs never created in production; `dismissed` is write-only. [lib/minga_editor/bottom_panel.ex] | Model the shipped Messages panel directly until a second tab exists. | Low-medium, about 60–100 lines. |
| D16 | `delete` | Sidebar snapshot fingerprints and `selection_only_change?/2` are consumed only by tests and SDK mirrors. [lib/minga_editor/extension/sidebar/snapshot.ex] | Remove fields/calculations/API and mirror changes. | Low-medium SDK risk, about 55–80 lines. |
| D17 | `delete` | `MingaEditor.UI` has no caller, and five `MingaEditor.Frontend` exports are unused. [lib/minga_editor/ui.ex, lib/minga_editor/frontend.ex] | Delete facade and unused exports after external API check. | Low, about 70–95 lines. |
| D18 | `delete` | Per-window modeline layout is always zero height after the global status bar migration. [lib/minga_editor/layout.ex:43-55,246-255] | Remove field and zero-height compatibility guards. | Medium fixture churn, about 25–45 lines. |
| D19 | `delete` | `session_history_source.ex` and `tab_source.ex` have no production references; AgentSessionSource supersedes the former. [lib/minga_editor/ui/picker/session_history_source.ex, lib/minga_editor/ui/picker/tab_source.ex] | Delete files and obsolete tests after extension API check. | Low internally, 146 production lines. |
| D20 | `delete` | Four UI compatibility facades are test-only or have one canonical replacement. [lib/minga_editor/ui/popup/registry.ex, popup/rule.ex, highlight/injection_range.ex, highlight/grammar.ex] | Update the one Grammar caller and tests to canonical modules, then remove facades. | Low internally, medium external compatibility, 94 lines. |
| D21 | `delete` | Theme.Picker and Theme.Minibuffer are never read at runtime; both frontends use popup colors. [lib/minga_editor/ui/theme.ex:210-278, lib/minga_editor/ui/theme/slots.ex:130-205] | Deprecate user override keys, then remove sections/builders/themes/tests. | Medium config compatibility, about 160–230 lines. |
| D22 | `delete` | `editor.tilde_fg`, `tree.modified_fg`, and `tree.git_conflict_fg` are construction-only. [lib/minga_editor/ui/theme.ex:99-121,503-534] | Remove after theme override compatibility review. | Low internally, about 10–20 lines plus fixtures. |
| D23 | `delete` | Git TUI `amend_mode` is toggled but never read by renderer, prompt, or submission. [lib/minga_editor/git_status/tui_state.ex:16-94, extensions/git_porcelain/lib/minga_git_porcelain/input/git_status.ex:209-217] | Implement amend submission now or remove field, command, binding, and tests. | Low, about 8–15 lines. |
| D24 | `delete` | Parser routing calls an explicit no-op hook although synchronization is event-driven. [lib/minga_editor/highlight_events.ex:78-83, lib/minga_editor/input/router.ex:188] | Remove call/delegate/function. | Low, about 5–8 lines. |
| D25 | `delete` | TODO source advertises generic async fetching but returns no candidates; production uses a dedicated workflow/effect. [lib/minga_editor/ui/picker/todo_search_source.ex:31-48] | Remove dormant generic callback path. | Low, about 8–12 lines. |
| D26 | `delete` | Agent.Events contains a second durable catch-up parser/replay stack used only by tests; production uses Remote.EventReplay. [lib/minga_editor/agent/events.ex:99-252, lib/minga_editor/remote/event_replay.ex] | Delete replay stack and replay-only workflow entry points, retain live tool-update handling. | Low-medium, about 210 production lines. |
| D27 | `delete` | BundledStatusNote’s GenServer/registrar lifecycle is never started; Registry seeds its static entry directly. [lib/minga_editor/agent/semantic_ui/bundled_status_note.ex, registry.ex:283-298] | Keep static contribution data and remove registrar lifecycle. | Low, about 45–50 lines. |
| D28 | `delete` | Six registered and key-bound agent commands return state unconditionally; collapse-all and expand-all both toggle. [lib/minga_editor/commands/agent.ex:1298-1353,2217-2226, lib/minga/keymap/scope/agent.ex:99-111] | Remove no-op names/bindings and implement directional collapse or keep only honest toggle. | Low-medium config compatibility, about 30–45 lines. |
| D29 | `delete` | Diagnostics provider has an unreachable `:lsp_info` branch; the registered owner is Commands.Lsp. [lib/minga_editor/commands/diagnostics.ex:52-75, lib/minga_editor/commands/lsp.ex:28-52] | Remove branch/type/aliases. | Low, about 24–28 lines. |
| D30 | `delete` | `Interaction.focus_stack` is initialized and test-maintained but never read by production routing; shell handlers and FocusTree replaced it. [lib/minga_editor/input.ex:75-113, lib/minga_editor/startup.ex:204-211, lib/minga_editor/state/interaction.ex:10-47] | Remove field, stack builders, focus/blur APIs, startup setup, and obsolete tests. | Low, about 45–70 lines. |
| D31 | `delete` | Multiple handlers implement both node-aware mouse handling and a self-hit-testing wrapper Router can never choose; key-only handlers also implement no-op mouse callbacks. [lib/minga_editor/input/router.ex:398-449 and completion.ex, picker.ex, file_tree_handler.ex, agent_mouse.ex, mode_fsm.ex, cua/dispatch.ex] | Keep node-aware callbacks and remove wrappers/helpers/no-op callbacks; test through Router. | Low, about 90–125 lines. |
| D32 | `delete` | Breadcrumb clicks, `tool_dismiss`, six-field internal mouse mailboxes, three-field hover correlation, and explicit `language_at_response` are no-op or producerless paths. [lib/minga_editor/handlers/gui_action_handler.ex:430-433,597-601, lib/minga_editor.ex:685-693, lib/minga_editor/handlers/lsp_event_handler.ex:182-195,256-273, lib/minga_editor/handlers/highlight_handler.ex:98-104] | Delete each local path, retaining current wire decoding where external client compatibility still matters. | Low, about 60–100 lines. |
| D33 | `delete` | Extension panel PID-message fallback has no in-repo receiver or documented callback; semantic registry dispatch is authoritative. [lib/minga_editor/handlers/gui_action_handler.ex:1985-2028] | Publish compatibility cutoff, then remove atomization/message fallback. | Medium unknown external extension risk, about 25–35 lines. |
| D34 | `delete` | Session window invalidation workflows return input unchanged, while renderer state owns durable observations. [lib/minga_editor/session/state.ex:215-226, lib/minga_editor/state.ex:215-228,396-410] | Delete methods and calls; retain real renderer correlation and layout invalidation. | Low, about 30–45 lines. |
| D35 | `delete` | `Workspace.active_file` is maintained and persisted but never read; Session.Snapshot owns active-file restoration separately. [lib/minga_editor/state/workspace.ex:40-68,292-415,574-598] | Remove field, maintenance, persistence, and unused setter. | Low-medium external JSON risk, about 55–75 lines. |
| D36 | `delete` | Dormant semantic Tool Manager placement is permanently invisible and has no builder. [lib/minga_editor/layout/footer_overlays.ex:93-103,218-225, lib/minga_editor/layout/surface_registry.ex] | Remove unreachable placement entries without touching any separate live picker workflow. | Low, about 8–12 lines. |
| D37 | `delete` | Several Session.State, Mouse, Window.Content, picker, theme, notification, prompt, and registry helpers are test-only or exact aliases. | Remove only after checking documented external APIs; preserve `Picker.replace_items/2` for L10. | Low internally, roughly 100–150 lines after exclusions. |
| D38 | `delete` | `Tab.Context.version` is written and parsed but never selects a migration or compatibility policy. [lib/minga_editor/state/tab/context.ex:21,80-98,144-161,446-451] | Remove version while retaining actual legacy key/field migrations. | Low, about 10–15 lines. |
| D39 | `delete` | Agent auto-scroll and transcript-highlight call chains are explicit no-ops after resident frontend scrolling. [lib/minga_editor/agent/ui_state.ex:232-234, lib/minga_editor/shell/traditional/workflow.ex:113-116] | Remove functions and calls; retain explicit pin transitions. | Low, about 12–16 lines. |
| D40 | `delete` | Render test/stub surface includes empty agent-chat prefetch, ignored parameter, test-only raster getter, unused DisplayMap queries, and unused boundary snapshot. [lib/minga_editor/render_pipeline/buffer_prefetch.ex, content.ex, display_map.ex, renderer/window_cache.ex] | Remove only APIs with no production/extension consumer. | Low, about 90–130 lines. |

## Shrink, directness, and ownership findings

| ID | Tag | Finding and evidence | Smallest safe action | Risk / estimate |
| --- | --- | --- | --- | --- |
| S01 | `archie` | Format command and format-on-save are independent engines; save path uses blocking calls, hand-written coordinate edits, no negotiated encoding, no stale check, and direct external execution. [lib/minga_editor/commands/formatting.ex, lib/minga_editor/commands/buffer_management.ex:2414-2581] | Make the stronger formatting lifecycle canonical and add an explicit save continuation after commit/failure. | High sequencing risk, about 110–170 lines removable. |
| S02 | `shrink` | Command aliases promise distinct behavior but dispatch identically: agent split/tabs, diagnostics picker names, language picker, file picker, workspace-next-agent, and kill-other-buffers. | Choose canonical names, migrate internal callers, keep temporary deprecations only if config stability requires them. | Medium compatibility, about 25–45 lines. |
| S03 | `shrink` | Agent first-edit content is stored both as a plain `diff_baselines` string and a memory/file-backed EditTimeline snapshot. [lib/minga_editor/agent/file_event_workflow.ex:98-145, lib/minga_editor/agent/ui_state/view.ex:405-427] | Make EditTimeline authoritative and remove duplicate string state/facades. | Medium ordering/file-read risk, about 30–40 lines plus memory. |
| S04 | `archie` | Workspace auto-name installation is duplicated across queued-user and first-assistant workflows. [lib/minga_editor/agent/session_event_workflow.ex:146-198, stream_event_workflow.ex:118-153] | Share only the mutation/install operation; keep trigger eligibility separate. | Medium, about 20–30 lines. |
| S05 | `shrink` | Input registry phases have no producer and built-in metadata/MapSet are rebuilt on every key. [lib/minga_editor/input.ex:47-52,140-153,243-304] | Store source/priority only and seed built-ins at initialization or explicit reload. | Medium-low hot-reload risk, about 30–45 lines. |
| S06 | `direct` | Foreground registration broadcasts `:buffer_opened` after `Buffer.ensure_for_path/3` already broadcast it; downstream services rely on idempotence. [lib/minga/buffer.ex:47-106, lib/minga_editor/handlers/buffer_registry.ex:200-218] | Make buffer creation the sole event owner. | Low, about 12–15 lines. |
| S07 | `shrink` | GUI handlers request renders internally although outer GUI housekeeping always renders. [lib/minga_editor.ex:755-767, lib/minga_editor/handlers/gui_action_handler.ex:123,168,181,796] | Return mutated/invalidated state and render once outside. | Low, about 4–8 lines plus runtime work. |
| S08 | `archie` | GUI space-leader replay calls full Router dispatch inside an outer GUI action, duplicating parser/LSP/render housekeeping. [lib/minga_editor/input/cua/space_leader.ex:134-136, lib/minga_editor/handlers/gui_action_handler.ex:731-737] | Define a raw key-routing primitive while preserving history and keyboard-specific completion. | Medium, runtime reduction. |
| S09 | `shrink` | Session restore schedules one delayed code-lens/inlay request per restored buffer, but every message acts on the then-current buffer. [lib/minga_editor/handlers/buffer_registry.ex:220-227, session_restore.ex:31-77] | Schedule once after the restore batch or correlate each message to its buffer. | Medium, line-neutral. |
| S10 | `archie` | Agent prompt and file tree both swap temporary buffers into active editor state to reuse the Vim FSM. [lib/minga_editor/input/agent_panel.ex:125-237, file_tree_handler.ex:202-442] | Share an explicit temporary-target workflow only if it preserves legitimate buffer switches, target death, and surface postprocessing; remove file-tree fake buffer only after semantic keyboard navigation exists. | High. |
| S11 | `shrink` | Terminal viewport exists in FrontendState, Session.State, Window, and tab snapshots; inactive tabs can restore stale dimensions. [lib/minga_editor/session/state.ex:45-69,561-564, lib/minga_editor/state/frontend.ex:21-61, lib/minga_editor/state/tab/context.ex:27-38] | Remove session/tab copy and pass frontend viewport explicitly where needed. | Medium, about 20–35 lines. |
| S12 | `shrink` | Agent UI exists in live Session.State, durable Workspace, and Tab.Context, but tab activation overwrites the context copy from Workspace. [lib/minga_editor/state/tab/context.ex:40-175, lib/minga_editor/state/workspace.ex:40-120, lib/minga_editor/tab_workflow.ex:73-96] | Remove tab-context copy and consistently project Workspace into active Session.State. | Medium, about 15–25 lines. |
| S13 | `archie` | Empty TabBar encodes absence as dangling `active_id: 1` and an allocator starting at 2, violating its own invariants. [lib/minga_editor/state/tab_bar.ex:1-88] | Represent absence with nil and make zero-tab consumers explicit. | Medium, near-neutral LOC. |
| S14 | `shrink` | Default-only Picker `on_cancel/1`, `preview?`, Prompt callbacks, Effect `coalesce/2`, and Input.Handler `handle_key/3` force repeated identity/passthrough boilerplate. | Make defaults optional and validated; preserve explicit restore/live-preview/custom coalescing behavior. | Low-medium API change, roughly 200–280 lines. |
| S15 | `archie` | StatusBar.Data builds nearly identical semantics for buffer and background-agent status. [lib/minga_editor/status_bar/data.ex:174-235,399-466] | Extract one shared buffer semantic builder and overlay agent-only fields. | Medium protocol parity, about 90–140 lines. |
| S16 | `archie` | Six picker sources duplicate buffer lookup/start/activate/cursor/jump/error navigation with meaningful option differences. | Introduce one narrowly parameterized navigation primitive; do not flatten root authorization or preview semantics. | Medium-high, about 100–170 lines. |
| S17 | `archie` | Prompt callbacks run before modal close and can read modal context, but cannot safely open a successor modal because PromptUI dismisses it afterward. [lib/minga_editor/prompt_ui.ex:87-104, lib/minga_editor/ui/prompt/project_remove_confirm.ex:37-44] | Capture context and pass it to callbacks, or add context-aware callbacks before changing ordering. | Medium, 10–20 lines. |
| S18 | `shrink` | Popup.Active repeats window identity already owned by the Windows map; Observatory values repeat visibility owned by shell presence. | Remove redundant value fields and use container identity/presence. | Low, about 20–30 lines. |
| S19 | `shrink` | Minibuffer command completion owns a second fuzzy matcher beside Picker.Candidate/Scorer. [lib/minga_editor/minibuffer_data.ex:343-528] | Share scoring primitives while preserving command-specific popular ordering and wire shape. | Medium ranking risk, about 50–80 lines. |
| S20 | `direct` | Completion dismissal leaves secondary pending refs, allowing unnecessary late-response processing. [lib/minga_editor/completion_trigger.ex:160-168] | Clear `pending_refs` during dismissal. | Low, 1–3 lines. |
| S21 | `archie` | DoomOne hand-builds the complete theme while maintained themes use Palette and Builder. [lib/minga_editor/ui/theme/doom_one.ex] | Derive chrome from Builder only after protocol-slot and capture-style parity tests. | Medium-high visual risk, about 100–180 lines. |
| S22 | `archie` | Effect implementations repeat queued/running/timeout/error/cancel/stale OperationFeedback transitions. [lib/minga_editor/effects/external_format.ex, git_mutation.ex, git_mutation_admission.ex] | Add a small feedback transition helper, not another scheduling framework. | Medium, about 90–140 lines. |
| S23 | `shrink` | BufferDecorations catches exits across pure composition, silently converting programming defects into empty/base decorations. [lib/minga_editor/buffer_decorations.ex:17-34] | Catch only process-backed Buffer calls. | Low, 10–20 lines changed. |
| S24 | `archie` | Shell is a broad registry/runtime/stash/workflow framework with one production implementation, two test fakes, and no SDK contract. [lib/minga_editor/shell.ex] | Decide whether pluggable shells are committed; expose and exercise the contract or collapse it incrementally into Traditional. | High, potential 600–1,000 lines, excluded from safe total. |
| S25 | `shrink` | Renderer.RenderWindow duplicates editor-window constructors, scrolling, popup, textobject, and fold APIs with no renderer consumer. [lib/minga_editor/renderer/render_window.ex, lib/minga_editor/window.ex] | Reduce it to materialized carrier and cache-facing operations. | Low-medium, about 400–475 lines. |
| S26 | `shrink` | Frame/Window/Scroll intent DTOs carry unused or duplicate fields and Input compatibility overloads remain after production converged on Intent. [lib/minga_editor/render_pipeline/frame_intent.ex, window_intent.ex, scroll.ex, renderer/buffer_changes.ex, renderer/frame_handler.ex] | Remove dead LSP/parser fields, duplicate map-key IDs/version, and unreachable overloads; retain explicit allowlist boundaries. | Low-medium, about 35–70 lines. |
| S27 | `shrink` | Protocol compatibility decoders accept unversioned ready and old key/mouse/rejection/body layouts despite exact-version handshake from both live clients. [lib/minga_editor/frontend/protocol.ex, lib/minga_editor/frontend/frame_transaction.ex] | Reject unversioned ready first, then delete layouts impossible under accepted version; keep malformed rejection. | Medium third-party frontend risk, about 80–150 lines. |
| S28 | `shrink` | Breadcrumb semantic model retains file path/root after deriving the only wire-visible field, segments. [lib/minga_editor/render_model/ui/breadcrumb_builder.ex] | Store and fingerprint segments only. | Low, about 10–20 lines. |
| S29 | `yagni` | Capabilities retain unsupported `:web`, dead query helpers, no-producer capabilities updates, and legacy forms. [lib/minga_editor/frontend/capabilities.ex] | Remove dead local helpers/web now; coordinate wire cleanup with a protocol bump. | Low to medium, about 40–120 lines. |
| S30 | `archie` | The full `EditorState -> Input -> Intent -> materialized Input` round trip exists for structural compatibility, and Input/Emit.Context duplicate 17 fields. [lib/minga_editor/render_pipeline/input.ex, intent.ex, frame_intent.ex, lib/minga_editor/frontend/emit/context.ex] | Keep cache-free process boundaries, but ask whether renderer materialization should target a smaller renderer-owned input instead of reconstructing the Editor-shaped DTO. | High architecture judgment; no estimate counted. |
| S31 | `shrink` | Remote/tab/workspace and render DTO duplication has produced manual projection functions and drift-prone dual writes. | Resolve owners first, then delete setters and copies; do not merge structs solely by field overlap. | High architecture sensitivity. |
| S32 | `direct` | Input registry includes AgentMouse in keyboard dispatch although its key callback always passes and mouse routing is independent. [lib/minga_editor/input.ex:71, input/agent_mouse.ex:47-48] | Remove keyboard registration only. | Low, one hot-path call. |
| S33 | `shrink` | Change Summary and breadcrumb UI advertise clickable semantics that have no implemented behavior. | Delete dormant surfaces/actions or implement them from a real BEAM owner; do not keep polished but inert controls. | Product decision, overlaps D02 and D32. |
| S34 | `shrink` | Renderer row ceiling is documented as a u16 wire limit although row counts encode as u32; it is actually a residence/performance policy. [lib/minga_editor/render_pipeline/buffer_prefetch.ex:557-574, lib/minga/frontend/adapter/gui/window_encoder.ex:223,273] | Rename/document the support ceiling without widening it. | Documentation-only. |
| S35 | `native` | ProductionGate is useful CI policy but lives in the runtime renderer namespace and has no runtime caller. [lib/minga_editor/renderer/production_gate.ex] | Move it to test/performance support or a Mix task namespace. | Low, net-zero lines. |

## Completely removable files accepted by Ponytail

These files have no required production behavior after the accepted local call-site or compatibility work named below:

- `lib/minga_editor/buffer_lifecycle.ex`
- `lib/minga_editor/markdown_styles.ex`, after FloatingWindow painter removal
- `lib/minga_editor/render_pipeline/invalidation.ex`
- `lib/minga_editor/render_pipeline/window_dirty.ex`
- `lib/minga_editor/renderer/caps.ex`
- `lib/minga_editor/renderer/gutter/sign_context.ex`
- `lib/minga_editor/ui/highlight/grammar.ex`, after canonical alias update
- `lib/minga_editor/ui/highlight/injection_range.ex`
- `lib/minga_editor/ui/picker/session_history_source.ex`
- `lib/minga_editor/ui/picker/tab_source.ex`
- `lib/minga_editor/ui/popup/registry.ex`
- `lib/minga_editor/ui/popup/rule.ex`

`lib/minga_editor/frontend/protocol/gui.ex` is removable only after its accepted small live decoder/settings/clipboard core is extracted. `lib/minga_editor/renderer/production_gate.ex` should move rather than disappear. FeatureState, Frontend.Adapter, MingaEditor.UI, Change Summary, Tool Manager, and other routed or preserved boundaries are deliberately excluded from this actionable list until their required architecture, product, migration, or compatibility decisions are made.

## Complexity that must remain

The audit explicitly rejects several tempting cuts:

- Resident store identity, content epochs, layout generations, changed-row deltas, payload bounds, row-splice validation, keyframe recovery, frame transactions, last-good-frame preservation, and stale receipt rejection are the minimum correctness foundation for the resident renderer.
- Buffer and session PID monitors, monitor references, targeted `catch :exit` at lookup-to-use races, timer generations, and stale-result correlation are necessary OTP behavior. The problem is missing identity in specific paths, not the existence of identity checks.
- Native IPC authentication, constant-time token checks, UID/mode checks, per-generation identity, atomic descriptors, app liveness, and completion acknowledgement are trust-boundary requirements.
- Extension callback CodeLease admission, bounded scheduler execution, timeout, unload/source cancellation, and stale snapshot rejection protect the Editor mailbox from extension code.
- Root-authorized file/TODO candidates, watcher cleanup lineage, filesystem retry, UTF-16 conversion, accessibility metadata, and popup focus restoration are not bloat.
- Shell identity generation and stash matching are required while pluggable shells remain an extension promise.
- File-backed diff snapshots are required at production size; only the duplicate plain-string baseline is removable.
- Separate GUI and TUI space-leader handling is justified because terminal input lacks native key-up/chord timing.
- WindowFocus cursor ownership checks, hover correlation, notification references, formatting version checks, and direct selection-drag routing are correct race handling.

## Idiomatic Elixir opportunities in retained complexity

An independent `elixir-architect` craftsmanship audit inspected 64 representative files plus repository-wide callers. It focused only on behavior Ponytail preserved or on complexity this report says must remain. These are behavior-preserving language-shape improvements, not deletion or architecture verdicts.

### E01. Split scheduler decisions from OTP effects

- **Priority/confidence:** high, 96/100.
- **Evidence:** `lib/minga_editor/effect_scheduler/state.ex:7-48`, `lib/minga_editor/effect_scheduler/engine.ex:230-344,388-487,574-708`.
- **Current shape:** One 837-line engine interleaves raw lane/running map updates, queue policy, cancellation, task startup, timers, messages, claims, and finalization.
- **Better Elixir shape:** Add `EffectScheduler.Lane` and `EffectScheduler.Running` structs. Make lane admission/cancellation/next-request calculations pure and return tagged actions such as `{:start, lane, request}` or `{:queued, lane, outcomes}`; keep TaskSupervisor, timers, monitors, and messaging in Engine.
- **What disappears:** Repeated raw-map rebuilding, `:queue.to_list/1` reconstruction, nested policy bookkeeping, and tests that must boot OTP merely to prove queue decisions.
- **Constraint:** Preserve bounded `:queue` storage, owner monitoring, timeout identity, `Task.Supervisor.async_nolink/2`, and the claim/finalize lease.

### E02. Give renderer attempts and acknowledgement leases first-class structs

- **Priority/confidence:** high, 95/100.
- **Evidence:** `lib/minga_editor/renderer/state.ex:21-50`, `frame_handler.ex:17-46,96-133,194-211`, `recovery_handler.ex:41-103`, `ack_handler.ex:10-96`.
- **Current shape:** Frame attempts are positional tuples; acknowledgement leases and adaptation evidence are unrelated maps; generation/sequence correlation knowledge repeats across modules.
- **Better Elixir shape:** Add `%FrameAttempt{intent, seq, pushed_at}` and `%AckLease{attempt, generation, timer_ref, output}` with owner functions for freshness, exact matching, timer cancellation, and attempt-to-lease conversion. Model adaptation evidence as a struct too.
- **What disappears:** Positional tuple matching, repeated partial identity patterns, and ad hoc “latest” selection helpers.
- **Constraint:** Generation and sequence must both match; stale deliveries remain side-effect free; terminal failure preserves last-acknowledged caches.

### E03. Normalize extension callback outcomes once

- **Priority/confidence:** high, 95/100.
- **Evidence:** `lib/minga_editor/extension/event_handler.ex:11-34`, `event_dispatcher.ex:126-253`, `event_effect.ex:113-245`.
- **Current shape:** Public callback tuples flow deep into scheduler effects, while fan-out, first-match, and unload use different tuple families and rediscover state/failure/render/reply semantics.
- **Better Elixir shape:** Normalize callback returns immediately into `%EventDispatchResult{status, state, failures}` and make both ordinary and unload paths return it.
- **What disappears:** Tuple-size inspection, parallel failure clauses, private fan-out accumulator maps, and `result_state/3`-style unpacking.
- **Constraint:** Keep CodeLease admission, callback ordering, successful intermediate state, unload tokens, and exact-base-state stale rejection.

### E04. Use one identity-bound Shell.Instance for active and stashed shells

- **Priority/confidence:** high, 93/100.
- **Evidence:** `lib/minga_editor/shell/runtime.ex:18-27,180-375,403-649`, `shell/state_stash.ex:1-45`.
- **Current shape:** Active shell stores entry plus state, while stashed shell uses a separate identity/state value, producing paired active/stashed callback routes and repeated restoration checks.
- **Better Elixir shape:** Use `%Shell.Instance{entry, identity, state}` for both active and stashed values and route lifecycle operations through one instance transition plus one collection traversal.
- **What disappears:** `StateStash`, repeated restore checks, and most `route_active_*`/`route_stashed_*` pairs.
- **Constraint:** Never restore across id/module/source/generation mismatch, and never install state from a callback that reports `handled?: false`.

### E05. Make native IPC Endpoint an idempotently closable resource owner

- **Priority/confidence:** high, 94/100.
- **Evidence:** `lib/minga_editor/native_ipc/server.ex:48-102,291-316`, `native_ipc/server/state.ex:1-27`.
- **Current shape:** Server init owns a procedural partial-acquisition chain while cleanup knowledge exists only after a complete GenServer state.
- **Better Elixir shape:** Add `%NativeIPC.Endpoint{listener, identity, descriptor_path}` with `open/1` and idempotent `close/1`; Endpoint owns reverse-order rollback, and Server starts the acceptor only after complete acquisition.
- **What disappears:** Partial-resource branches in `Server.init/1`, duplicated socket/descriptor cleanup, and flat State fields representing one resource.
- **Constraint:** Preserve lstat UID/type/mode checks, atomic descriptor replacement, identity-matched removal, listener closure, and socket unlinking.

### E06. Keep EditTimeline pure and move snapshot I/O into its workflow

- **Priority/confidence:** high, 93/100.
- **Evidence:** `lib/minga_editor/agent/diff_snapshot.ex:20-68`, `agent/edit_timeline.ex:56-77,184-205`, `agent/file_event_workflow.ex:98-148`.
- **Current shape:** An apparently immutable timeline transition reads config/time and writes temporary files; cleanup also performs filesystem effects inside the value owner.
- **Better Elixir shape:** Have FileEventWorkflow prepare timestamps and memory/file-backed snapshot references, then pass prepared values into pure `EditTimeline.record/3`; expose owned references for workflow cleanup.
- **What disappears:** Clock, config, and filesystem effects from value transitions and from most timeline tests.
- **Constraint:** Retain file-backed snapshots for large content, avoid synchronous rereads in ordinary transitions, and clean every owned file on session teardown.

### E07. Express tab-context compatibility as a versioned migration pipeline

- **Priority/confidence:** high, 92/100.
- **Evidence:** `lib/minga_editor/state/tab/context.ex:21-109,252-281,361-500`.
- **Current shape:** Version exists, but decoding is a shape-driven procedural chain of aliases, present-field filtering, file-tree migration, feature-state migration, and cleanup.
- **Better Elixir shape:** Parse the envelope, dispatch through clauses such as `migrate(:legacy, map)` and `migrate(1, map)`, then run one current-version validator. Keep an explicit tolerant fallback until format policy changes.
- **What disappears:** Chained `migrate_legacy_*` passes and hidden aliases inside otherwise current decoding.
- **Constraint:** Preserve partial restoration, direct file-tree precedence, string keys, invalid-field filtering, and tolerant persisted-context reads.

### E08. Give monitored renderer buffers one owner

- **Priority/confidence:** medium, 91/100.
- **Evidence:** `lib/minga_editor/renderer/state.ex:47-50,206-318`, `renderer/buffer_changes.ex:23-112`.
- **Current shape:** Monitor refs and observed versions are parallel root maps; reconciliation, exact `:DOWN`, version installation, and removal are split across State and BufferChanges.
- **Better Elixir shape:** Add `%Renderer.ObservedBuffers{monitors, versions}` owning `reconcile/2`, `record_version/3`, and `drop_down/3`.
- **What disappears:** Parallel root fields, direct version-map updates, and split buffer-retirement knowledge.
- **Constraint:** Monitor from Renderer, match PID and reference, demonitor with `[:flush]`, and consume each changed buffer once before window fanout.

### E09. Encode true command aliases as provider metadata

- **Priority/confidence:** medium, 88/100.
- **Evidence:** `lib/minga_editor/commands/provider.ex:1-139`, `commands/diagnostics.ex:20-42`, `commands/buffer_management.ex:136-138,2713-2715`, `commands/agent.ex:57-72`.
- **Current shape:** Public aliases are duplicate command entries plus duplicate clauses or wrappers, with no machine-readable declaration that they intentionally share behavior.
- **Better Elixir shape:** Extend the existing command DSL with an alias declaration that registers a separate public name whose execute closure targets the canonical implementation and can carry deprecation metadata.
- **What disappears:** Duplicate clauses and undocumented alias relationships while public names remain stable.
- **Constraint:** Keep aliases visible to ETS registry and command palette; do not redirect extension-owned commands or commands whose names promise different behavior.

### E10. Isolate legacy extension panel delivery behind a tagged router

- **Priority/confidence:** medium, 86/100.
- **Evidence:** `lib/minga_editor/handlers/gui_action_handler.ex:260-262,1989-2032`.
- **Current shape:** The large GUI handler owns semantic dispatch, legacy PID lookup, safe atom conversion, exact mailbox tuples, error handling, logging, and user feedback.
- **Better Elixir shape:** Move compatibility delivery into `Extension.PanelActionRouter.dispatch/4`, returning `{:handled, state}` or `:unavailable`; try semantic dispatch first and legacy mailbox delivery second.
- **What disappears:** Compatibility helpers and atom-conversion rescue logic from the GUI action module.
- **Constraint:** Use existing atoms only, preserve the exact legacy message, and keep catches narrowly scoped.

The strongest Elixir improvement is E01: deterministic Lane transitions plus a narrow OTP edge preserve the scheduler’s necessary guarantees while making its densest lifecycle logic much easier to reason about.

## Exhaustive data-shape and pattern-matching audit

The broader data-shape pass represented all 537 files through an AST inventory, including 505 files with target shapes and 32 without recorded target shapes. It found 193 struct definitions, 5,171 raw map literals or updates, 1,581 map-update expressions, 2,080 tuple literals of arity at least three, and 787 selected `Map.*` calls. The specialist deep-read 72 production modules and four tests chosen from the complete inventory. The result is 24 supported reshapes, not a claim that every map or tuple is wrong.

### ES01. Share one semantic window value across Editor and Renderer

- **Priority/confidence:** high, 97/100.
- **Evidence:** `lib/minga_editor/window.ex:23-61`, `render_pipeline/window_intent.ex:5-65`, `renderer/render_window.ex:33-72`.
- **Current shape:** Three structs repeat fourteen semantic fields; materialization depends on `Map.from_struct/1` and identical field names, while transition logic is duplicated.
- **Better Elixir shape:** Introduce one cache-free `%Window.Semantic{}`. Editor and renderer values pair it with their own bounded observations or process-owned cache.
- **Invalid states/conversions removed:** Field-ledger drift, missing materialized fields, structural map conversion, and duplicate viewport/fold/scroll APIs.
- **Constraint:** Renderer residency remains process-owned and only fixed-size observations return to Editor.

### ES02. Keep the render snapshot nested end to end

- **Priority/confidence:** high, 95/100.
- **Evidence:** `lib/minga_editor/render_pipeline/input.ex:67-231`, `intent.ex:23-49`, `frame_intent.ex:5-99`, `workspace_intent.ex:3-61`, `frontend/emit/context.ex:29-178`.
- **Current shape:** Editor state is flattened into 32-field Input, copied into intent DTOs, rebuilt into Input, and copied into a 37-field emit context. Workspace is deliberately a raw map for old access syntax.
- **Better Elixir shape:** Capture `%Intent{frame, workspace, windows}` directly, wrap it with renderer runtime values, and let Emit reference nested snapshots plus derived emit data.
- **Invalid states/conversions removed:** Incomplete workspace maps, inconsistent duplicated frame/emit values, compatibility `Map.get/3`, and most field-by-field copying.
- **Constraint:** Keep the cache-free process boundary, bounded serialization, pre-boundary option reads, and exact extension/shell snapshots.

### ES03. Represent renderer frame credit as one tagged phase

- **Priority/confidence:** high, 95/100.
- **Evidence:** `lib/minga_editor/renderer/state.ex:23-70`, `frame_handler.ex:18-57,114-223`, `ack_handler.ex:9-96`.
- **Current shape:** `rendering?`, token, retry count, in-flight, pending, and awaiting-ack fields encode one lifecycle independently.
- **Better Elixir shape:** Use `%FrameWork{}` and `%AckLease{}` under `:idle | {:scheduled, token, work, retries} | {:awaiting_ack, lease}`, with one explicit coalesced successor.
- **Invalid states removed:** Idle with in-flight work, awaiting acknowledgement while not rendering, or scheduled token without work.
- **Constraint:** Preserve one-frame credit, latest-successor coalescing, exact token/generation/sequence matching, and retry bounds.

### ES04. Partition renderer caches by actual concern

- **Priority/confidence:** medium, 93/100.
- **Evidence:** `lib/minga_editor/renderer/caches.ex:18-100`, `renderer/window_cache.ex:66-200`.
- **Current shape:** Global and window caches mix Chrome, Content, Emit, frame history, invalidation, retention, hydration, edit, identity, and scroll state in flat 22/28-field structs.
- **Better Elixir shape:** Nest focused cache values such as `%ChromeCache{}`, `%EmitCache{}`, `%FrameHistory{}`, `%Invalidation{}`, `%Retention{}`, `%Hydration{}`, and `%ScrollCorrelation{}`. Represent dirty lines as `:all | MapSet.t()`.
- **Invalid states removed:** Partial resets that retain stale sibling fields and dirty maps containing meaningless values.
- **Constraint:** Preserve epochs, production bounds, resident hydration, row retention, and acknowledgement history.

### ES05. Type the retained visual-row pipeline

- **Priority/confidence:** medium, 92/100.
- **Evidence:** `lib/minga_editor/render_model/window/builder.ex:66-104,785-812`, `renderer/window_cache.ex:46-86`, `render_pipeline/content.ex:236-240`.
- **Current shape:** Eleven-field visual rows and six-field build results are raw maps crossing builder phases and surviving in cache.
- **Better Elixir shape:** Add `%RenderModel.Window.VisualRow{}`, `%BuildResult{}`, and optionally `%RetentionMeta{}`.
- **Invalid states removed:** Cached rows without required source ranges/rows and misspelled keys silently read as nil.
- **Constraint:** Keep retention bounded and preserve row IDs, hashes, and splice validation.

### ES06. Make State.LSP the single typed correlation owner

- **Priority/confidence:** high, 96/100.
- **Evidence:** `lib/minga_editor/session/state.ex:49,541-557`, `state/lsp.ex:20-44,148-235`, `handlers/lsp_event_handler.ex:140-213`.
- **Current shape:** Generic, structured, and formatting requests occupy three stores; dispatch probes them in order; values are open-ended atoms/tuples; aggregate status is stored beside its source map.
- **Better Elixir shape:** Add `%PendingRequests{}` with typed variants and origin tab IDs, plus focused `%SelectionChain{}` and `%Debounce{}` values; derive aggregate status.
- **Invalid states removed:** Duplicate refs across stores, selection index without ranges, status disagreement, and viewport data detached from request context.
- **Constraint:** Preserve reference correlation, tab-departure retirement, stale rejection, and foreign JSON maps at the boundary.

### ES07. Turn CompletionTrigger into a struct with batch and debounce values

- **Priority/confidence:** high, 95/100.
- **Evidence:** `lib/minga_editor/completion_trigger.ex:27-55,130-174,212-258`.
- **Current shape:** A public raw map mixes primary/pending refs, trigger position, generation, and debounce timer.
- **Better Elixir shape:** Use `%CompletionTrigger{batch, debounce, generation}`, `%Batch{primary, pending, trigger_position}`, and `%Debounce{timer, clients, buffer, trigger_position}`.
- **Invalid states removed:** Primary ref absent from pending set, position without a batch/debounce, and arbitrary keys.
- **Constraint:** Preserve multi-server merge semantics, latest-wins generations, Editor-owned timers, and stale result rejection.

### ES08. Use the existing Highlight.Span struct everywhere

- **Priority/confidence:** high, 98/100.
- **Evidence:** `lib/minga_editor/semantic_token_sync.ex:116-170`, `ui/highlight.ex:22-30,138-190`, `lib/minga/language/highlight/span.ex:13-45`.
- **Current shape:** A Span struct exists, but parser and semantic paths construct maps; Highlight stores tuples or map lists and normalizes through `Map.get/3`.
- **Better Elixir shape:** Emit `%Span{}` at parser and semantic boundaries and store one tuple-of-structs representation.
- **Invalid states removed:** Missing required offsets/capture IDs and mixed representations inside one highlight value.
- **Constraint:** Preserve tuple residency, layer priority, width ordering, capture IDs, and parser correlation.

### ES09. Separate file-tree content lifecycle from interaction mode

- **Priority/confidence:** high, 96/100.
- **Evidence:** `lib/minga_editor/state/file_tree.ex:40-80,91-243,451-539`.
- **Current shape:** Tree content, visibility/focus, loading/error, editing, filtering, help, and request state are encoded through booleans, nils, and companion fields.
- **Better Elixir shape:** Use independent tagged values for content (`:closed | {:loading, ...} | {:ready, tree} | {:error, ...}`), visibility, and interaction (`:browse | {:editing, edit} | {:filtering, filter} | :help`).
- **Invalid states removed:** Hidden-focused, editing-filtering, help-editing, ready-without-tree, and detached filter request.
- **Constraint:** Hidden loaded trees retain buffers/watchers/data, and reroot/filter correlation remains exact.

### ES10. Encode file-tree refresh and watcher work as tagged correlations

- **Priority/confidence:** medium, 94/100.
- **Evidence:** `lib/minga_editor/state/file_tree/refresh.ex:14-82`, `state/file_tree/watchers.ex:12-114`, `file_tree/freshness.ex:68-147`.
- **Current shape:** Debounce/current/retry and request/token/attempt companion fields require coordinated clearing.
- **Better Elixir shape:** Use `:idle | {:debounced, token, attempt} | {:admitted, root, request}` and `:idle | {:admitted, request} | {:retry, token, attempt}` with typed request structs.
- **Invalid states removed:** Retry without token, admitted work with authoritative debounce, or request plus unrelated retry.
- **Constraint:** Preserve mailbox tokens, bounded retry, cleanup candidates, and exact target/generation matching.

### ES11. Give picker fetch, source mode, and action menu focused values

- **Priority/confidence:** medium, 93/100.
- **Evidence:** `lib/minga_editor/state/picker.ex:17-56,105-135`, `picker_ui.ex:940-1015`.
- **Current shape:** Fetch status/revision, mode prefix/original source, and `{actions, selected_index}` tuples are companion families in one struct.
- **Better Elixir shape:** Add `%FetchState{revision, status}`, `%SourceMode{current, layout, switched_from}`, and `%ActionMenu{actions, selected}`.
- **Invalid states removed:** Prefix without original source, menu index without actions, and orphan fetch revision.
- **Constraint:** Preserve latest-wins identity, extension source authorization, and source-specific layout.

### ES12. Make Effect.Outcome a genuine sum type

- **Priority/confidence:** high, 95/100.
- **Evidence:** `lib/minga_editor/effect/outcome.ex:12-75`, `ui/picker/fetch_effect.ex:78-98`, `file_tree/freshness.ex:100-147`.
- **Current shape:** Status, result, reason, and queue metadata occupy mutually exclusive nil-filled fields.
- **Better Elixir shape:** Keep request common and store `value: {:queued, queue} | :running | {:completed, result} | {:failed, reason} | {:canceled, reason} | {:stale, reason}`.
- **Invalid states removed:** Completed with reason, failed with result, terminal queue data, or incomplete queued metadata.
- **Constraint:** Keep claim/finalize identity, terminal delivery, and stale reclassification behavior.

### ES13. Separate operation identity from tagged lifecycle phase

- **Priority/confidence:** high, 94/100.
- **Evidence:** `lib/minga_editor/state/operation.ex:8-118`, `state/operation_feedback.ex:128-176`, `status_bar/data.ex:72-144`.
- **Current shape:** Status, queue, progress, cancelability, and message mix active and terminal data; internal domain representation is also the JSON wire value.
- **Better Elixir shape:** Keep stable identity and use `phase: :pending | {:queued, queue} | {:running, progress_or_nil} | {:finished, status, message}`, projected to a dedicated JSON-derived wire struct.
- **Invalid states removed:** Terminal-but-cancelable operations, terminal queue data, and unrelated progress.
- **Constraint:** Preserve IDs, deterministic order, cancellation, retention bounds, and exact JSON schema.

### ES14. Put inline ask/edit session lifecycle into tagged phases

- **Priority/confidence:** medium, 92/100.
- **Evidence:** `lib/minga_editor/state/inline_ask.ex:12-46,132-160`, `state/inline_edit.ex:14-43,112-151`.
- **Current shape:** Status, session PID, response/proposal, proposal source, and rewrite fields require synchronized updates.
- **Better Elixir shape:** Use `:input | {:running, session, accumulated} | {:answered, response} | {:failed, message}`; edits use `:none | {:stream, text} | {:tool, text}` for proposal data.
- **Invalid states removed:** Thinking without session, input with session, terminal with live session, or proposal source without text.
- **Constraint:** Session stopping remains effectful and per-buffer/session ownership remains exact.

### ES15. Replace inline-overlay callback-spec maps with a behaviour

- **Priority/confidence:** low, 84/100.
- **Evidence:** `lib/minga_editor/inline_overlay/events.ex:15-91`, `inline_ask/events.ex:26-42`, `inline_edit/events.ex:26-42`.
- **Current shape:** Each event constructs maps of closures and passes additional transition closures.
- **Better Elixir shape:** Define an internal Adapter behaviour for store lookup, replacement, session membership, event transition, and failure transition; pass the ask/edit module.
- **Invalid states removed:** Incomplete or misspelled callback-spec maps.
- **Constraint:** Keep static internal dispatch and preserve extension callback admission boundaries.

### ES16. Split mouse state into drag, resize, click, and hover values

- **Priority/confidence:** medium, 94/100.
- **Evidence:** `lib/minga_editor/state/mouse.ex:25-99,119-198`, `mouse.ex:178-229`.
- **Current shape:** Ten flat fields encode four independent concerns through booleans, nils, and tuples.
- **Better Elixir shape:** Use `%Mouse{drag, resize, clicks, hover}` with tagged idle/active sub-values.
- **Invalid states removed:** Dragging without anchor, idle drag with origin, and hover timer without position.
- **Constraint:** Preserve native click counts, TUI timing fallback, origin-window clamping, and timer cancellation.

### ES17. Move compaction transitions into a dedicated owner

- **Priority/confidence:** high, 96/100.
- **Evidence:** `lib/minga_editor/agent/ui_state/view.ex:52-94`, `agent/status_event_workflow.ex:85-225`.
- **Current shape:** Four View fields are directly updated from StatusEventWorkflow, and branch order coordinates warning, trigger, deferred fill, and execution.
- **Better Elixir shape:** Add `%Compaction{threshold, execution}` with tagged states and transitions returning actions such as `:warn` or `:schedule`.
- **Invalid states removed:** Running plus deferred work and independently reset warning/trigger flags.
- **Constraint:** Preserve event order, one request at a time, deferred idle application, and scheduler-owned execution.

### ES18. Extract transcript projection/cache from Agent Panel

- **Priority/confidence:** medium, 95/100.
- **Evidence:** `lib/minga_editor/agent/ui_state/panel.ex:22-73,137-166`, `agent_lifecycle.ex:192-233`.
- **Current shape:** Prompt/model state shares Panel with eight correlated transcript projection and cache fields.
- **Better Elixir shape:** Add `%TranscriptProjection{line_index, messages, message_pairs, styled, styled_fingerprint, display_start, provenance_jump, version}`.
- **Invalid states removed:** Styled cache with wrong fingerprint and partially cleared projection.
- **Constraint:** Keep bounded transcript storage, stable message identity, incremental styling, and no session reads in render callbacks.

### ES19. Make workspace-owned Agent UI the sole authority

- **Priority/confidence:** high, 91/100.
- **Evidence:** `lib/minga_editor/state/workspace.ex:38-110`, `session/state.ex:48-73`, `shell/traditional/workflow.ex:29-61`, `tab_workflow.ex:62-91`.
- **Current shape:** Active UIState is stored in both active Workspace and Session.State, every update writes both, and tab switch reconciles them.
- **Better Elixir shape:** Keep UIState on Workspace and expose root active-agent access/update APIs; render snapshots project it without another durable owner.
- **Invalid states removed:** Live session UI diverging from active workspace UI.
- **Constraint:** Preserve active/inactive isolation, return targets, shell fallback, and remote replay order.

### ES20. Give Tab and Workspace kind-specific payloads

- **Priority/confidence:** high, 92/100.
- **Evidence:** `lib/minga_editor/state/tab.ex:35-82,113-236`, `state/workspace.ex:20-101`.
- **Current shape:** `kind` sits beside many fields valid only for one kind, allowing file tabs to carry agent state and manual workspaces to carry remote lifecycle fields.
- **Better Elixir shape:** Keep common identity/chrome and use `%Tab.File{} | %Tab.Agent{}` plus `%Workspace.Manual{} | %Workspace.Agent{}` payloads.
- **Invalid states removed:** Cross-kind fields and broad nil-based dispatch.
- **Constraint:** Preserve persisted migration, inactive contexts, remote identity, grouping, and chrome projections.

### ES21. Replace status-bar variant maps with typed common and variant structs

- **Priority/confidence:** medium, 93/100.
- **Evidence:** `lib/minga_editor/status_bar/data.ex:35-146,151-225`.
- **Current shape:** Buffer and agent variants are large raw maps with about thirty duplicated shared fields.
- **Better Elixir shape:** Use `%StatusBar.Data{common: %Common{}, content: %Buffer{} | %Agent{}}` and one shared builder.
- **Invalid states removed:** Misspelled/omitted required keys and agent variants missing shared buffer context.
- **Constraint:** Preserve exact 0x76 bytes, GUI/TUI parity, and once-per-frame snapshots.

### ES22. Decompose frontend output pressure into backlog, retry, and acknowledgement values

- **Priority/confidence:** medium, 93/100.
- **Evidence:** `lib/minga_editor/frontend/manager/output_pressure.ex:4-231`, `frontend/manager/output_handler.ex:73-206`.
- **Current shape:** Frame backlog, retained controls, retry token/time, admission/applied sequences, and generation watermarks share one flat struct.
- **Better Elixir shape:** Use `%OutputPressure{backlog: %Backlog{}, retry: :idle | %Retry{}, acknowledgements: %AckWindow{}}`.
- **Invalid states removed:** Retry token without start time and partially reset acknowledgement windows.
- **Constraint:** Keep current plus one replacement bound, keyed control retention, `Port.command(..., [:nosuspend])`, watermarks, and keyframe recovery.

### ES23. Finish tagged-state modeling in focused UI owners

- **Priority/confidence:** medium, 91/100.
- **Evidence:** `lib/minga_editor/bottom_panel.ex:23-79`, `state/dired.ex:11-65`, `shell/traditional/observatory.ex:13-114`, `hover_popup.ex:8-91`, `agent/ui_state/view.ex:268-354`.
- **Current shape:** Existing owner modules still use boolean-plus-payload combinations for panel, Dired, Observatory, hover expansion, and agent search.
- **Better Elixir shape:** Give each owner its own tagged phases, with no shared generic abstraction.
- **Invalid states removed:** Hidden-focused panel, inactive-confirming Dired, invisible-collecting Observatory, expanded hover without alternate content, and confirmed search with input enabled.
- **Constraint:** Preserve timer tokens, dismissal semantics, pending operation confirmation, scroll reset, and saved search scroll.

### ES24. Encode editing recorder lifecycle as a phase

- **Priority/confidence:** low, 89/100.
- **Evidence:** `lib/minga_editor/change_recorder.ex:20-108`, `macro_recorder.ex:15-84`, `vim_state.ex:23-61`.
- **Current shape:** Recording and replaying are companion flags/tuples whose legal combinations depend on caller discipline.
- **Better Elixir shape:** Use `phase: :idle | {:recording, ...} | {:replaying, ...}` while retaining registers, pending count keys, and last change as data.
- **Invalid states removed:** Simultaneous recording/replaying and idle state retaining active keys.
- **Constraint:** Replayed keys must not overwrite dot-repeat or macro recordings.

### Data shapes to retain as-is

- OTP callback tuples, mailbox messages, GenServer replies, frontend opcode tuples, and public wire tuples are positional protocols and should remain tuples.
- Tab.Context’s typed fields plus `present_fields` distinguish missing legacy data from explicit nil and should remain at the migration boundary.
- VimState’s mode/mode-state short mismatch is required by execute-then-transition commands and should not be forced into a strict sum prematurely.
- Foreign LSP/JSON maps should remain string-keyed and partial at protocol edges until editor behavior needs normalization.
- Local accumulators, lookup tables, fingerprints, options maps, composite tuple keys, MapSets, and bounded `:queue` values fit their local semantics.
- ChromeState, TabSummary, WorkspaceSummary, FileTree.Row, Picker.Item, and semantic frontend models are explicit projections and should not become durable owners.
- Renderer.Context is large but coherent: one per-window pass parameter object rather than a lifecycle state.
- Focused validated values such as OperationProgress, OperationQueue, ClipboardMark, Workspace.RemoteSession, Activity, EditTimeline, and ReturnTarget already concentrate rules behind owner APIs.

The exhaustive data-shape pass found 12 high-priority, 10 medium-priority, and two low-priority opportunities. Its strongest recommendation is ES01: one cache-free semantic window value shared through Editor intents and renderer working windows.

## Independent Ponytail gate

Ponytail independently inspected all 139 findings against the repository rather than accepting this report’s conclusion. It accepted 91 findings as the smallest correct direct fix or simplification, routed 28 to Archie, preserved 11 correctness or compatibility foundations, and rejected 9 over-broad simplifications. The rejected findings remain below as an audit trail but must not become implementation tickets in their current form.

Verdicts mean:

- **ACCEPT:** smallest correct cut or direct fix;
- **PRESERVE:** current complexity is required or the proposed deletion would lower the project’s correctness or compatibility floor;
- **ROUTE:** ownership or architecture judgment belongs to Archie before implementation;
- **REJECT:** unsupported, over-broad, style-only, or unsafe.

### Lifecycle findings

| ID | Verdict | Tag | Ponytail perspective |
| --- | --- | --- | --- |
| L01 | ACCEPT | `direct` | Forward the decoded six-field rejection shape and remove five-field runtime compatibility because protocol-v11 input is already normalized. |
| L02 | ACCEPT | `direct` | Factor an internal tagged save result and short-circuit close or shutdown on failure. |
| L03 | ROUTE | `archie` | Root buffer inventory and retirement ownership across tabs and workspaces requires an explicit architecture decision. |
| L04 | ACCEPT | `direct` | Refuse ordinary dirty kills with a notice and add one explicit force path. |
| L05 | ACCEPT | `direct` | Require Dired backing-buffer identity for save, retire that PID directly, and clear Dired when it dies. |
| L06 | ROUTE | `archie` | A global identity-bearing LSP request registry changes ownership and belongs to Archie. |
| L07 | ROUTE | `archie` | Completion correlation should be designed with the LSP ownership decision rather than expanded through unrelated tuples. |
| L08 | ROUTE | `archie` | Empty-result clearing is real, but origin-safe clearing and stale rejection depend on L06. |
| L09 | ROUTE | `archie` | Splitting syntax and semantic highlight layer ownership changes the data model and belongs to Archie. |
| L10 | ACCEPT | `direct` | Use the existing `Picker.replace_items/2` atomic candidate rebuild before clamping selection. |
| L11 | ACCEPT | `direct` | Preserve prefix switching but route it through existing fetch revision and scheduler lifecycle. |
| L12 | ACCEPT | `direct` | Match the current Picker.Context shape and leave selection callbacks on full EditorState. |
| L13 | ACCEPT | `direct` | Invoke idempotent conceal cleanup on the disable transition. |
| L14 | ACCEPT | `direct` | Background Git refresh may update visibility and content but must not change focus. |
| L15 | ACCEPT | `direct` | Use `state.frontend.terminal_viewport` for initial popup window metadata. |
| L16 | ACCEPT | `direct` | Remove every matching PID from Remote inside root `remove_buffer/2`. |
| L17 | ROUTE | `archie` | Completing Workspace authority over tab session projections requires an ownership migration. |
| L18 | ROUTE | `archie` | Persisted remote fields, restored defaults, and schema evolution require a persistence-model decision. |
| L19 | ACCEPT | `direct` | Send the existing stable message ID and update the transcript by ID. |
| L20 | ACCEPT | `direct` | Replace the hardcoded Alt flag with `Input.mod_ctrl/0`. |
| L21 | ROUTE | `archie` | Whether Ctrl-G hides, blurs, or derives focus for each surface is an ownership decision. |
| L22 | ACCEPT | `direct` | Capture resize drags and clear drag state before the no-buffer guard. |
| L23 | ACCEPT | `direct` | Correlate clear timers to the exact status generation/reference. |
| L24 | ACCEPT | `direct` | Add narrow exit handling only around the process-backed lookup-to-use calls. |
| L25 | ACCEPT | `direct` | Add reverse-order partial-init rollback while preserving every IPC trust check. |
| L26 | ACCEPT | `direct` | Snapshot `git_syncing` as a boolean instead of carrying the scheduler process. |
| L27 | ACCEPT | `direct` | Resolve triple-click target line, window, and buffer through HitTest. |
| L28 | ACCEPT | `native` | Add an accessible frontend-owned “older messages omitted” indicator. |
| L29 | ACCEPT | `direct` | Add the two omitted fields to color validation metadata and tests. |
| L30 | ACCEPT | `shrink` | Remove unused filetype and consolidate only process-backed title reads behind a targeted exit-safe helper. |

Lifecycle totals: **22 ACCEPT, 8 ROUTE, 0 PRESERVE, 0 REJECT.**

### Deletion findings

| ID | Verdict | Tag | Ponytail perspective |
| --- | --- | --- | --- |
| D01 | ROUTE | `archie` | FeatureState has no in-tree writer, but the extension API and persisted contexts commit to the concept; choose completion or migrated retirement explicitly. |
| D02 | ROUTE | `archie` | Change Summary is empty, but its cross-client schema and protocol contract need an explicit product and retirement decision. |
| D03 | ROUTE | `archie` | Native Tool Manager has no emitter, but its documented cross-client contract requires an explicit replacement and migration decision. |
| D04 | PRESERVE | `archie` | 0xA3 is a documented generic extension runtime boundary; lack of a bundled producer does not justify deleting the foundation. |
| D05 | ACCEPT | `delete` | Remove the 0x78 messages section after a protocol bump while retaining the shared body codec and 0x86 conformance coverage. |
| D06 | ACCEPT | `shrink` | Shrink the parity facade only after every removed encoder has a canonical adapter and independent golden or cross-frontend test. |
| D07 | ROUTE | `archie` | Frontend.Adapter is a pluggable frontend boundary with more than one implementation; assess nil `gui_payload` and unused helper cuts separately. |
| D08 | ACCEPT | `delete` | Delete dead invalidation structs while deliberately preserving or migrating the documented telemetry stage name. |
| D09 | ACCEPT | `shrink` | Remove the cell painter and SignContext while retaining geometry and semantic gutter encoding. |
| D10 | ACCEPT | `delete` | Delete test-only Renderer.Caps; live adaptation belongs at the adapter boundary. |
| D11 | ACCEPT | `delete` | Remove only proven write-only fields and snapshots while retaining frame lineage and side-channel dedupe. |
| D12 | PRESERVE | `archie` | Adapted retry is normative schema and recovery behavior; no current producer is insufficient evidence for deletion. |
| D13 | ACCEPT | `delete` | Delete the no-op compatibility paths after updating the bundled extension and preserving save/parser regression coverage. |
| D14 | ACCEPT | `shrink` | Reduce FloatingWindow to geometry and delete MarkdownStyles after placement parity remains covered. |
| D15 | ACCEPT | `yagni` | Remove uninstantiated local tab state and write-only dismissal, but keep the committed wire contract until separately versioned. |
| D16 | PRESERVE | `archie` | Mirrored SDK snapshot fields are an extension compatibility surface and need deprecation/versioning before removal. |
| D17 | ROUTE | `archie` | MingaEditor.UI is documented and some alleged Frontend exports are live; public facade collapse needs exact scoping and a boundary decision. |
| D18 | ACCEPT | `delete` | Remove always-zero per-window modeline state with hit-tree, fixture, and documentation updates. |
| D19 | ACCEPT | `delete` | Delete both unreferenced picker sources and isolated tests while retaining AgentSessionSource. |
| D20 | ACCEPT | `direct` | Move callers to canonical modules before removing facades and publish compatibility notice if names were externally usable. |
| D21 | ACCEPT | `shrink` | Remove duplicate theme sections after deprecating accepted override keys and validating theme construction. |
| D22 | ACCEPT | `delete` | Remove the three construction-only fields while keeping deprecated override parsing compatible. |
| D23 | ACCEPT | `delete` | Remove write-only amend mode while retaining working amend prompt/protocol paths. |
| D24 | ACCEPT | `delete` | Remove identity reparse hook and keep event-driven parser tests authoritative. |
| D25 | ACCEPT | `delete` | Remove the misleading generic async advertisement, but keep behavior-required initialization and dedicated workflow. |
| D26 | ACCEPT | `delete` | Remove duplicate replay parser after proving canonical replay covers every retained event family. |
| D27 | ACCEPT | `shrink` | Remove unused registrar lifecycle while retaining static contribution and cleanup semantics. |
| D28 | ACCEPT | `delete` | Remove no-op commands and use one honest toggle, with a keymap migration notice. |
| D29 | ACCEPT | `delete` | Remove unreachable diagnostics-owned LSP info branch. |
| D30 | ACCEPT | `delete` | Remove dead focus stack state/builders and correct architecture/keymap documentation. |
| D31 | ACCEPT | `shrink` | Remove in-tree wrappers/no-ops while retaining Router’s legacy fallback for external input handlers. |
| D32 | ACCEPT | `delete` | Delete only local no-op/producerless branches; keep committed protocol and parser schema until versioned migrations. |
| D33 | PRESERVE | `archie` | External extension compatibility fallback remains until a published cutoff and semantic-registry migration. |
| D34 | ACCEPT | `delete` | Remove identity invalidation calls without touching real renderer correlation/cache/layout invalidation. |
| D35 | ACCEPT | `delete` | Remove write-only active-file state if old JSON remains tolerantly readable and restoration tests pass. |
| D36 | ACCEPT | `delete` | Remove unreachable Tool Manager placement while preserving protocol identifiers if D03 remains. |
| D37 | REJECT | `delete` | The aggregate names no exact helpers or call sites and could delete documented APIs; split it into independently evidenced candidates first. |
| D38 | PRESERVE | `archie` | Persisted context version is migration infrastructure; removal needs an explicit format-version policy. |
| D39 | ACCEPT | `delete` | Remove identity auto-scroll chain while retaining explicit pin/unpin/engage transitions. |
| D40 | ACCEPT | `delete` | Remove only the exact no-producer/test-only APIs while retaining live DisplayMap mapping and telemetry. |

Deletion totals: **29 ACCEPT, 5 ROUTE, 5 PRESERVE, 1 REJECT.**

### Shrink and ownership findings

| ID | Verdict | Tag | Ponytail perspective |
| --- | --- | --- | --- |
| S01 | ROUTE | `archie` | Formatting should converge, but the canonical async lifecycle and save continuation change sequencing ownership. |
| S02 | PRESERVE | `shrink` | Command names are public keymap/config contracts; retain meaningful aliases, deprecate only proven legacy names, and make dishonest behavior honest. |
| S03 | ACCEPT | `shrink` | Remove duplicate baseline state without synchronously rereading file-backed snapshots. |
| S04 | ACCEPT | `direct` | Move shared auto-name installation into the existing workspace owner and leave trigger eligibility local. |
| S05 | ACCEPT | `shrink` | Remove unused phase and reseed built-ins only on initialization or explicit contribution reload. |
| S06 | ACCEPT | `direct` | Let initial buffer creation own `:buffer_opened`; retain distinct LSP reattachment broadcasts. |
| S07 | ACCEPT | `direct` | Let outer GUI housekeeping submit the one authoritative render intent. |
| S08 | ROUTE | `archie` | Raw key routing versus housekeeping changes the input pipeline contract. |
| S09 | ACCEPT | `shrink` | Schedule one post-restore refresh or carry buffer identity if every buffer truly requires work. |
| S10 | ROUTE | `archie` | Temporary-buffer FSM reuse spans editor and semantic-surface ownership; keep file-tree shim until equivalent navigation exists. |
| S11 | ACCEPT | `shrink` | Keep FrontendState authoritative and pass current dimensions explicitly instead of restoring stale copies. |
| S12 | ACCEPT | `shrink` | Remove ineffective Tab.Context agent projection while keeping Workspace durable and Session.State live. |
| S13 | ROUTE | `archie` | Replacing the deliberate zero-tab sentinel with nil may add branching and changes a foundational invariant. |
| S14 | ACCEPT | `native` | Use optional callbacks only for proven identity defaults and preserve meaningful restore/coalescing behavior. |
| S15 | ACCEPT | `shrink` | Build shared buffer status semantics once and preserve tagged/protocol parity. |
| S16 | ROUTE | `archie` | Shared picker navigation would own authorization, activation, previews, and failure policy. |
| S17 | ROUTE | `archie` | Prompt callback ordering and context delivery form a modal lifecycle contract. |
| S18 | ACCEPT | `shrink` | Delete Popup.Active’s unused identity but preserve Observatory visibility as a distinct lifecycle fact. |
| S19 | REJECT | `shrink` | Command and picker matching have different ranking promises; sharing them would add abstraction or change behavior. |
| S20 | ACCEPT | `direct` | Clear primary and secondary completion refs on dismissal. |
| S21 | ACCEPT | `shrink` | Express Doom One through Palette/Builder only after exact visual and protocol parity. |
| S22 | ACCEPT | `shrink` | Extract only repeated feedback installation/terminal plumbing and keep policy/domain effects explicit. |
| S23 | ACCEPT | `direct` | Catch exits only around Buffer calls and let pure composition failures surface. |
| S24 | PRESERVE | `archie` | Pluggable shells are explicit project architecture; prune obsolete callbacks individually rather than collapsing the behavior. |
| S25 | ACCEPT | `shrink` | Remove editor-facing APIs with no renderer consumer and keep materialized carrier/cache operations. |
| S26 | ACCEPT | `shrink` | Remove unread fields and compatibility overloads while preserving the cache-free Intent allowlist. |
| S27 | ROUTE | `archie` | Decoder removal requires a version-support policy and schema bump. |
| S28 | ACCEPT | `shrink` | Keep only derived breadcrumb segments in the semantic model/fingerprint. |
| S29 | ACCEPT | `yagni` | Remove unsupported web/local helpers now and defer negotiated wire cleanup to a protocol bump. |
| S30 | ROUTE | `archie` | Keep the cache-free process boundary; a smaller renderer-owned materialization target is a data-flow decision. |
| S31 | ROUTE | `archie` | Establish owners and projection direction before removing similar fields, setters, or structs. |
| S32 | ACCEPT | `direct` | Remove AgentMouse from keyboard registration; focus-tree mouse dispatch remains authoritative. |
| S33 | ACCEPT | `delete` | Delete unowned Change Summary and inert breadcrumb click affordances while retaining display-only breadcrumbs. |
| S34 | ACCEPT | `shrink` | Document the row threshold as residence/performance policy without widening it. |
| S35 | ACCEPT | `native` | Move ProductionGate to test/performance support where its callers live. |

Shrink totals: **23 ACCEPT, 9 ROUTE, 2 PRESERVE, 1 REJECT.**

### Retained-complexity craftsmanship findings

| ID | Verdict | Tag | Ponytail perspective |
| --- | --- | --- | --- |
| E01 | ROUTE | `archie` | Ask Archie whether to extract only pure lane admission/cancellation transitions while Engine remains sole owner of tasks, timers, monitors, notifications, claims, and finalization. |
| E02 | ACCEPT | `shrink` | Introduce only FrameAttempt and AckLease owners for exact identity and timer cancellation; keep adaptation evidence in RejectionState until independent drift appears. |
| E03 | ACCEPT | `shrink` | Normalize validated callback tuples once at EventDispatcher without changing public API, ordering, CodeLease, intermediate state, or stale rejection. |
| E04 | PRESERVE | `yagni` | Keep Runtime and StateStash distinct because active state needs a resolved Entry while stashes need identity-bound restoration. |
| E05 | ACCEPT | `shrink` | Create one Endpoint owning listener, socket path, identity, descriptor acquisition, and rollback; Server.State owns Endpoint plus acceptor. |
| E06 | PRESERVE | `yagni` | Keep DiffSnapshot as the snapshot resource owner and at most inject timestamps into EditTimeline rather than splitting I/O ownership. |
| E07 | PRESERVE | `yagni` | Keep tolerant shape-driven decoding until a real second persisted version exists; handle inert version removal separately. |
| E08 | ACCEPT | `shrink` | Add ObservedBuffers only if it enforces versions as a subset of monitored PIDs and centralizes reconciliation, recording, demonitoring, and exact `:DOWN`. |
| E09 | REJECT | `direct` | Use the existing command execute option for aliases; do not extend the DSL or add speculative deprecation metadata. |
| E10 | REJECT | `direct` | Keep the narrow local legacy fallback until cutoff, then delete it rather than moving it into a new router. |

Craftsmanship totals: **4 ACCEPT, 1 ROUTE, 3 PRESERVE, 2 REJECT.**

### Exhaustive data-shape findings

| ID | Verdict | Tag | Ponytail perspective |
| --- | --- | --- | --- |
| ES01 | ROUTE | `archie` | Duplication is real, but sharing a value across Editor and Renderer changes process-boundary ownership; choose shared semantic carrier versus explicit DTO plus a smaller RenderWindow. |
| ES02 | ROUTE | `archie` | Redesigning the cache-free snapshot contract and shell/extension projections is an architecture decision. |
| ES03 | ACCEPT | `shrink` | Use one tagged frame-credit phase and AckLease; retain a local frame-work tuple unless it gains another consumer. |
| ES04 | REJECT | `yagni` | Seven cache structs would rearrange one-owner state; delete dead fields and add focused resets instead. |
| ES05 | ACCEPT | `shrink` | Add focused VisualRow and BuildResult structs; defer optional RetentionMeta until it removes a concrete conversion. |
| ES06 | ROUTE | `archie` | Consolidating LSP stores changes asynchronous request ownership and tab-snapshot lifecycle. |
| ES07 | ACCEPT | `shrink` | Replace the raw map with one trigger struct using tagged idle, debounced, and pending phases rather than three nested objects. |
| ES08 | ACCEPT | `native` | Reuse the existing Span struct, converting protocol tuples once while retaining tuple residency. |
| ES09 | ACCEPT | `shrink` | Use focused visibility and interaction phases while keeping hidden loaded tree data and watchers resident. |
| ES10 | ACCEPT | `shrink` | Tag refresh/watcher correlation phases but keep request payloads local maps/tuples instead of extra structs. |
| ES11 | REJECT | `yagni` | Three new values do not fix async bypass; keep local action tuple and move updates into direct State.Picker transitions. |
| ES12 | ACCEPT | `shrink` | One tagged outcome value removes genuinely invalid nil combinations without changing scheduler identity or delivery. |
| ES13 | PRESERVE | `direct` | Existing JSON-derived Operation is the public schema and already owns transitions; do not add an internal phase plus duplicate wire struct. |
| ES14 | ACCEPT | `shrink` | Tagged ask/edit phases remove real invalid states without a shared generic lifecycle abstraction. |
| ES15 | REJECT | `yagni` | Complete local callback maps for two variants are clearer than an internal behaviour. |
| ES16 | ACCEPT | `shrink` | Tag drag and hover invariants inside Mouse; retain cohesive click fields and existing resize tuple. |
| ES17 | ACCEPT | `shrink` | A pure compaction lifecycle owner returning actions removes contradictory flags while scheduler execution stays external. |
| ES18 | ACCEPT | `shrink` | One nested transcript projection removes partial-cache states without changing resident transcript ownership. |
| ES19 | ROUTE | `archie` | Sole Workspace Agent UI authority changes durable/live ownership and tab-switch projection order. |
| ES20 | ROUTE | `archie` | Kind-specific payloads materially change persisted Tab/Workspace models and migration behavior. |
| ES21 | ACCEPT | `shrink` | Typed common/variant status structs are justified across builder/encoder boundaries while preserving exact bytes. |
| ES22 | REJECT | `yagni` | OutputPressure already has one owner; keep fields flat and at most replace retry token/timestamp with one tagged retry. |
| ES23 | REJECT | `yagni` | This aggregates five unrelated owners; split only demonstrated invariant failures instead of broad tagged-state conversion. |
| ES24 | ACCEPT | `shrink` | Give each recorder its own phase without a shared recorder abstraction. |

Data-shape totals: **13 ACCEPT, 5 ROUTE, 1 PRESERVE, 5 REJECT.**

## Net after Ponytail gate

The bucket estimates overlap heavily, especially around protocol facades, dormant frontend subsystems, callback boilerplate, and renderer compatibility. The accepted non-overlapping program still appears capable of removing roughly **5,000 to 8,000 production lines** and **no dependencies**, while adding targeted lifecycle identity and explicit error-result handling. This estimate is lower than the pre-gate range because Ponytail preserved the 0xA3 extension runtime, adapted retry, SDK snapshot compatibility, tab-context versioning, meaningful command aliases, and the pluggable Shell boundary. It also routed protocol, persistence, request ownership, and cross-client subsystem retirement decisions instead of treating current non-use as sufficient deletion evidence.
