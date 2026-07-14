# ADR-0002: Editor state transitions have explicit behavioral owners

**Status:** Accepted (2026-07-12). Epic: #2861. First implementation slice: #2862.

## Decision

`MingaEditor` remains the single GenServer that serializes interactive editor state. Its state is decomposed into immutable values with explicit behavioral owners, not additional processes. A transition belongs to the lowest owner that contains its complete invariant, and external work belongs to the workflow that requested it.

The ownership levels are:

1. **Leaf owner:** A focused value module owns its representation and every transition that can be decided from that value alone. Its public API names user or domain intent, such as `request_debounce/2`, `dismiss/1`, or `activate/2`, rather than exposing setters or generic mappers.
2. **Aggregate owner:** An immediate parent coordinates its children through their APIs when one invariant spans those children. It may read child values, but it does not update a foreign struct directly.
3. **Workflow owner:** A focused handler coordinates value owners with process calls, timers, supervised work, rendering, logging, persistence, or services. It may accept the root Editor state when the operation crosses top-level owners, but it still calls each owner API instead of performing deep updates.
4. **Root owner:** `MingaEditor.State` retains only transitions whose atomic invariant genuinely spans at least two top-level owners. Root functions are not forwarding delegates for leaf or aggregate operations.

## One Editor mailbox

State decomposition does not create one process per substate. Ordered input, shell transitions, workspace changes, renderer feedback, and other atomic editor operations continue through one `MingaEditor` mailbox. A new process is justified only when work needs an independent failure boundary, lifecycle, or mailbox, not because a struct gained a focused owner.

The Editor process creates every timer and monitor whose result returns to the Editor mailbox. This keeps message ownership and cleanup aligned. Slow resource-bound work runs under the existing generation-owned `MingaEditor.EffectScheduler` and its supervised workers, so an old Editor generation cannot deliver authority into a replacement generation.

## External actions

An external action is work that crosses the pure value boundary: timer or monitor creation, process calls, rendering submission, frontend communication, persistence, logging, event broadcasts, filesystem or service access, and supervised asynchronous work. Mode, status, buffer, overlay, spinner, focus, and similar state changes are ordinary transitions, not effects.

Ordinary workflows return an updated value, aggregate, root state, or focused tagged result directly. Slow resource-bound workflows submit a typed `MingaEditor.Effect.Request`, receive `MingaEditor.Effect.Outcome` values, and apply them through the originating domain module. `MingaEditor.EffectScheduler` owns admission, bounded queueing, worker supervision, cancellation, and terminal delivery. It does not own domain transitions, staleness policy, rendering policy, or user feedback.

## Correlation and stale results

Every timer message and asynchronous result carries a token that can be compared with current semantic state. A value owner accepts a result only when the token and stable resource identity still match. Closing, replacing, or rerooting a value invalidates the old result even if the worker later completes successfully.

Scheduler lifecycle state is not copied into Editor values. A domain value may remember only the semantic request whose result is currently allowed to change that domain. Queued, running, canceled, failed, and completed worker facts remain in `MingaEditor.EffectScheduler`.

File-tree refresh is the first application of this rule. `MingaEditor.State.FileTree.Refresh` owns debounce and current-result correlation, `MingaEditor.State.FileTree` owns tree/root acceptance, `MingaEditor.FileTree.Freshness` owns the workflow and external ordering, and `MingaEditor.FileTree.Refresh` owns typed scan execution and outcome application. The scheduler owns the running scan and at most one coalesced follow-up.

Render correlation follows the same boundary. `MingaEditor.State.RenderCorrelation` owns the render timer token, semantic intent revisions, receipt ordering, and pending keyframe request. `MingaEditor.State` retains one atomic receipt integration transition because shell identity, workspace observations, layout, focus, and click regions must agree. Timer creation, renderer submission, frontend communication, and stale-receipt logging stay in Editor workflows. `MingaEditor.Renderer.Server` remains authoritative for resident rows, render caches, acknowledgement credit, and renderer-private state.

Buffer activation and window focus use a session aggregate plus focused workflows. `MingaEditor.Session.State.activate_buffer/3` coordinates the leaf-owned buffer selection with the active window, keymap scope, launchpad, and hover observations. `MingaEditor.Session.State.focus_window/3` commits focus only after `MingaEditor.WindowFocus` successfully saves and restores process-owned cursors; the workflow then composes Traditional bottom-panel presentation through its shell owners. `MingaEditor.BufferActivation` coordinates shell callbacks and their external effects. No buffer call, monitor, log, render request, or shell presentation effect runs inside the pure session transitions.

## Migration ledger

The epic assigns every broad ownership area to a committed convergence slice:

| Area | Destination |
|---|---|
| File-tree refresh correlation and workflow | #2862 |
| Active shell identity, implementation, current state, and stash | #2863 |
| Render scheduling and receipt correlation | #2864 |
| Buffer activation and window focus invariants | #2865 |
| Traditional feedback and overlay lifecycles | #2866 |
| Traditional sidebars, agent presentation, and input state | #2867 |
| Workflow-specific external action execution | #2868 |
| Mechanical ownership and purity checks | #2869 |
| Every remaining root field and public transition, including documented root-wide invariants | #2870 |

The detailed field-and-transition ledger is maintained through these slices and is audited in #2870. No field or transition may remain under an unspecified future-cleanup category.

## Mechanical enforcement

`Minga.Credo.EditorStateOwnershipCheck` (EX9012) carries declarative metadata for each mechanically protected Editor struct: its concrete module name, designated owner modules, unambiguous receiver paths, transition boundary, and workflow boundary. It rejects explicit foreign struct updates, clear receiver-path map updates, `put_in`, `update_in`, and `Map.put` mutations at an owned boundary. It deliberately does not infer a type from an unknown variable name.

The same metadata designates pure value and aggregate owners. Those modules may call other value-owner APIs, but the check rejects process and GenServer calls, timers, task creation, logging, rendering, filesystem and persistence work, and configured service boundaries. External work remains valid in workflow and root callers when those callers use owner transition APIs.

Public owner APIs named as generic setters, putters, mappers, accessors, lenses, mutators, or assigners are rejected when they accept an arbitrary field, key, or function instead of naming an invariant. Focused transitions remain valid even when an established API uses a `set_` prefix.

The allowlist is compiled into the check. Entries are exact module, function/MFA, violation kind, and target tuples with a migration reason and the invariant preserved at that legacy boundary. Wildcards, path exceptions, missing migration tickets, undocumented reasons, and undocumented invariants are invalid configuration. The current list contains exactly 86 #2870 convergence entries, one for each row below:

| Module and function | Violation and target | Reason |
|---|---|---|
| `MingaEditor.Session.State.update_window/3` | generic API | Existing window mapper |
| `MingaEditor.Session.State.update_snapshot_window/3` | generic API | Existing render snapshot mapper |
| `MingaEditor.Session.State.update_windows_for_buffer/3` | generic API | Existing buffer window mapper |
| `MingaEditor.Session.State.update_editing/2` | generic API | Existing editing mapper |
| `MingaEditor.Session.State.update_file_tree/2` | generic API | Existing file-tree mapper |
| `MingaEditor.Session.State.update_search/2` | generic API | Existing search mapper |
| `MingaEditor.Session.State.update_feature_state/5` | generic API | Existing extension-state mapper |
| `MingaEditor.Shell.Runtime.update_traditional_state/2` | generic API | Existing shell mapper |
| `MingaEditor.Agent.UIState.update_activity/2` | generic API | Existing agent activity mapper |
| `MingaEditor.Agent.UIState.update_edit_timeline/2` | generic API | Existing edit timeline mapper |
| `MingaEditor.Agent.UIState.update_preview/2` | generic API | Existing agent preview mapper |
| `MingaEditor.RenderPipeline.Content.update_agent_scroll_metrics/3` | direct write to `MingaEditor.Agent.UIState` | Existing render metric projection |
| `MingaEditor.Startup.agent_view_state/0` | direct write to `MingaEditor.Agent.UIState` | Existing startup projection construction |
| `MingaEditor.State.update_workspace/2` | generic API | Existing root workspace mapper |
| `MingaEditor.State.update_file_tree/2` | generic API | Existing root file-tree mapper |
| `MingaEditor.State.update_buffers/2` | generic API | Existing root buffer mapper |
| `MingaEditor.State.update_windows/2` | generic API | Existing root windows mapper |
| `MingaEditor.State.update_dired/2` | generic API | Existing root dired mapper |
| `MingaEditor.State.update_mouse/2` | generic API | Existing root mouse mapper |
| `MingaEditor.State.update_search/2` | generic API | Existing root search mapper |
| `MingaEditor.State.update_highlight/2` | generic API | Existing root highlight mapper |
| `MingaEditor.State.update_editing/2` | generic API | Existing root editing mapper |
| `MingaEditor.State.update_mode_state/2` | generic API | Existing root mode-state mapper |
| `MingaEditor.State.update_injection_ranges/2` | generic API | Existing root injection-range mapper |
| `MingaEditor.State.update_shell_state/2` | generic API | Existing root shell-state mapper |
| `MingaEditor.State.update_remote/2` | generic API | Existing root remote mapper |
| `MingaEditor.State.update_lsp/2` | generic API | Existing root LSP mapper |
| `MingaEditor.State.update_window/3` | generic API | Existing root window mapper |
| `MingaEditor.State.update_windows_for_buffer/3` | generic API | Existing root buffer-window mapper |
| `MingaEditor.State.update_feature_state/5` | generic API | Existing root extension-state mapper |
| `MingaEditor.State.sync_file_tree_sidebar/2` | pure call to `Minga.Log.warning` | Existing root logging |
| `MingaEditor.State.file_tree_state/1` | pure call to `MingaEditor.RenderPipeline.Input.file_tree_state` | Existing render-input compatibility call |
| `MingaEditor.State.find_buffer_by_path/2` | pure call to `Minga.Buffer.file_path` | Existing buffer service read |
| `MingaEditor.State.monitor_buffer/2` | pure call to `Process.monitor` | Existing root monitor creation |
| `MingaEditor.State.buffer_content_context/1` | pure call to `Minga.Buffer.file_path` | Existing buffer service read |
| `MingaEditor.State.buffer_content_context/1` | pure call to `Minga.Buffer.buffer_name` | Existing buffer service read |
| `MingaEditor.State.buffer_content_context/1` | pure call to `Minga.Buffer.dirty?` | Existing buffer service read |
| `MingaEditor.State.buffer_content_context/1` | pure call to `Minga.Buffer.filetype` | Existing buffer service read |
| `MingaEditor.State.buffer_path/1` | pure call to `Minga.Buffer.file_path` | Existing buffer service read |
| `MingaEditor.State.log_switch_tab/3` | pure call to `Minga.Log.debug` | Existing root logging |
| `MingaEditor.State.log_switch_tab_result/1` | pure call to `Minga.Log.debug` | Existing root logging |
| `MingaEditor.State.agent_snapshot/1` | pure call to `MingaAgent.Session.editor_snapshot` | Existing agent service read |
| `MingaEditor.Shell.Traditional.handle_event/3` | direct write to `MingaEditor.Shell.Traditional.State` | Existing typed shell event write |
| `MingaEditor.Shell.Traditional.handle_gui_action/3` | direct write to `MingaEditor.Shell.Traditional.State` | Existing typed GUI action write |
| `MingaEditor.Shell.Traditional.open_buffer_in_new_tab/3` | direct write to `MingaEditor.Shell.Traditional.State` | Existing typed new-tab write |
| `MingaEditor.Shell.Traditional.on_buffer_switched/2` | direct write to `MingaEditor.Shell.Traditional.State` | Existing typed buffer-switch write |
| `MingaEditor.Shell.Traditional.on_agent_event/4` | direct write to `MingaEditor.Shell.Traditional.State` | Existing typed agent-event write |
| `MingaEditor.Shell.Traditional.set_tab_session/3` | direct write to `MingaEditor.Shell.Traditional.State` | Existing typed tab-session write |
| `MingaEditor.Shell.Traditional.switch_to_buffer_tab/4` | direct write to `MingaEditor.Shell.Traditional.State` | Existing typed tab-switch write |
| `MingaEditor.Shell.Traditional.open_buffer_in_file_tab/4` | direct write to `MingaEditor.Shell.Traditional.State` | Existing typed file-tab write |
| `MingaEditor.Shell.StateStash.transform/3` | generic API | Existing stash mapper |
| `MingaEditor.Shell.StateStash.transform/4` | generic API | Existing contextual stash mapper |
| `MingaEditor.State.AgentAccess.update_panel/2` | direct write to `MingaEditor.Agent.UIState` | Existing agent panel projection write |
| `MingaEditor.State.AgentAccess.update_view/2` | direct write to `MingaEditor.Agent.UIState` | Existing agent view projection write |
| `MingaEditor.Startup.ensure_session_started/1` | direct write to `MingaEditor.State` | Existing startup session write |
| `MingaEditor.Startup.maybe_start_save_timer/1` | direct write to `MingaEditor.State` | Existing startup timer write |
| `MingaEditor.Layout.put/1` | direct write to `MingaEditor.State` | Existing layout cache write |
| `MingaEditor.Agent.Compaction.clear_ui_progress/1` | direct write to `MingaEditor.Agent.UIState` | Existing compaction projection write |
| `MingaEditor.Agent.UIState.ensure_prompt_buffer/1` | pure call to `Minga.Buffer.buffer_name` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.start_prompt_buffer/2` | pure call to `Minga.Buffer.start_link` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.prompt_text/1` | pure call to `Minga.Buffer.content` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.insert_char/2` | pure call to `Minga.Buffer.insert_text` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.insert_newline/1` | pure call to `Minga.Buffer.insert_text` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.delete_char/1` | pure call to `Minga.Buffer.cursor` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.delete_char/1` | pure call to `Minga.Buffer.delete_before` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.set_prompt_text/2` | pure call to `Minga.Buffer.replace_content` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.clear_input_without_history/1` | pure call to `Minga.Buffer.replace_content` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.clear_input/1` | pure call to `Minga.Buffer.replace_content` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.move_cursor_up/1` | pure call to `Minga.Buffer.cursor` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.move_cursor_up/1` | pure call to `Minga.Buffer.move` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.move_cursor_down/1` | pure call to `Minga.Buffer.cursor` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.move_cursor_down/1` | pure call to `Minga.Buffer.line_count` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.move_cursor_down/1` | pure call to `Minga.Buffer.move` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.insert_paste/2` | pure call to `Minga.Buffer.insert_text` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.toggle_paste_expand/1` | pure call to `Minga.Buffer.cursor` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.history_prev/1` | pure call to `Minga.Buffer.replace_content` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.history_next/1` | pure call to `Minga.Buffer.replace_content` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.insert_collapsed_paste/2` | pure call to `Minga.Buffer.cursor` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.insert_collapsed_paste/2` | pure call to `Minga.Buffer.replace_content` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.insert_collapsed_paste/2` | pure call to `Minga.Buffer.move_to` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.expand_block/2` | pure call to `Minga.Buffer.cursor` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.expand_block/2` | pure call to `Minga.Buffer.replace_content` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.expand_block/2` | pure call to `Minga.Buffer.move_to` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.collapse_block/2` | pure call to `Minga.Buffer.cursor` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.collapse_block/2` | pure call to `Minga.Buffer.replace_content` | Existing prompt buffer process call |
| `MingaEditor.Agent.UIState.collapse_block/2` | pure call to `Minga.Buffer.move_to` | Existing prompt buffer process call |

`MingaEditor.Renderer.RenderReceipt` is separately classified as a pure value module, so receipt correlation is an owner-to-owner value call rather than a rendering effect.

Ownership tickets remove their exact entries as transitions converge. #2870 removes the remaining entries or replaces them only with documented root-wide invariants. Final convergence requires an empty allowlist, so no unexplained exception can survive.

Credo loads the check through `.credo.exs`. `make lint` applies Credo to changed Elixir files, and CI runs the strict project-wide check. Focused Credo fixtures prove allowed owner writes and workflow effects as well as rejected leaf, aggregate, root, workflow, purity, generic API, exact allowlist, and malformed configuration cases.

## Convergence requirements

A migration slice is not accepted while its old root fields, forwarding delegates, bare-map compatibility clauses, generic mappers, duplicate effect variants, or direct foreign-struct writes remain. Temporary ownership-check allowlists must be bounded to named pre-existing sites and shrink as each slice lands.

The migration finishes only when `MingaEditor.State` and `MingaEditor.Shell.Traditional.State` meet the project field-count guidance, retained root transitions coordinate real top-level invariants, the universal domain effect dispatcher is gone, ownership checks run without unexplained exceptions, and architecture documentation matches the code.

## Alternatives rejected

- **One GenServer per substate:** This would replace cheap immutable transitions with mailbox coordination, introduce ordering races, and weaken the Editor's atomic input authority.
- **Move existing setters into smaller modules:** Relocated setters do not own invariants. They preserve the same invalid combinations behind more files.
- **Keep a universal root facade:** Forwarding every leaf operation through `MingaEditor.State` leaves contributors with two mutation paths and lets the root API grow without bound.
- **Use one universal action interpreter:** Domain transitions, timers, filesystem work, rendering, persistence, and agent lifecycle do not share one ordering or failure policy. The scheduler is a bounded lifecycle service, not a domain interpreter.
- **Store worker lifecycle in domain values:** Duplicating queued and running state creates contradictory authorities. The scheduler already owns those facts.

## Consequences

Contributors must locate the behavioral owner before adding a field or transition. Pure owner tests can prove invariants without processes, while workflow tests focus on ordering, correlation, and failure handling. Some root workflows remain intentionally broad when atomicity spans top-level owners, but each retained operation must document that invariant instead of acting as a compatibility delegate.
