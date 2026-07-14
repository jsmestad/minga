# ADR-0002: Editor state transitions have explicit behavioral owners

**Status:** Accepted (2026-07-12), converged by epic #2861 on 2026-07-13.

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

There is no universal action interpreter. Agent, file and Git, tool, session, parser and highlight, and LSP workflows apply their own focused outcomes. Scheduler-backed agent compaction, session save and recovery, file-tree refresh, formatting, and prettify-symbol work all return through the workflow that created the typed request.

## Correlation and stale results

Every timer message and asynchronous result carries a token that can be compared with current semantic state. A value owner accepts a result only when the token and stable resource identity still match. Closing, replacing, or rerooting a value invalidates the old result even if the worker later completes successfully.

Scheduler lifecycle state is not copied into Editor values. A domain value may remember only the semantic request whose result is currently allowed to change that domain. Queued, running, canceled, failed, and completed worker facts remain in `MingaEditor.EffectScheduler`.

File-tree refresh applies this rule through four owners. `MingaEditor.State.FileTree.Refresh` owns debounce and current-result correlation, `MingaEditor.State.FileTree` owns tree and root acceptance, `MingaEditor.FileTree.Freshness` owns workflow ordering, and `MingaEditor.FileTree.Refresh` owns typed scan execution and outcome application. The scheduler owns the running scan and at most one coalesced follow-up.

Render correlation follows the same boundary. `MingaEditor.State.RenderCorrelation` owns the render timer token, semantic intent revisions, receipt ordering, and pending keyframe request. `MingaEditor.State` retains atomic receipt integration because shell identity, workspace observations, layout, focus, and click regions must agree. Timer creation, renderer submission, frontend communication, and stale-receipt logging stay in Editor workflows. `MingaEditor.Renderer.Server` remains authoritative for resident rows, render caches, acknowledgement credit, and renderer-private state.

Buffer activation and window focus use a session aggregate plus focused workflows. `MingaEditor.Session.State.activate_buffer/3` coordinates buffer selection with the active window, keymap scope, launchpad, and hover observations. `MingaEditor.Session.State.focus_window/3` commits focus only after `MingaEditor.WindowFocus` saves and restores process-owned cursors. `MingaEditor.BufferActivation` coordinates shell callbacks and their external work. No buffer call, monitor, log, render request, or shell presentation effect runs inside the pure session transitions.

## Final root ownership ledger

The converged `MingaEditor.State` has 16 top-level values. This is the full ledger, not a partial migration list.

| Root field | Behavioral owner | Invariant |
|---|---|---|
| `workspace` | `MingaEditor.Session.State` | One tab's buffers, windows, editing state, search, file tree, mouse state, feature state, hover observation, and agent UI move together as the active editing context. |
| `shell_runtime` | `MingaEditor.Shell.Runtime` | The active shell entry, exact registry identity, implementation state, and stashed shell states remain consistent. |
| `frontend` | `MingaEditor.State.Frontend` | Backend identity, rendering policy, transport, terminal viewport, negotiated capabilities, resource pressure, and input correlation describe one frontend connection. |
| `render` | `MingaEditor.State.Render` | Renderer connection, render correlation, semantic message store, committed layout and focus observations, and cursor-line observation describe one Editor render revision. |
| `parser` | `MingaEditor.State.Parser` | Parser manager, availability, highlighting, injection ranges, and face-override registries share parser lifecycle and presentation identity. |
| `agent_connection` | `MingaEditor.State.AgentConnection` | Provider configuration and the supervised ingest connection describe the Editor's live agent integration. |
| `interaction` | `MingaEditor.State.Interaction` | Editing model, keymap and option servers, focus stack, and keystroke history define input dispatch context. |
| `extension_surfaces` | `MingaEditor.State.ExtensionSurfaces` | Event, sidebar, and semantic-agent registries define the extension surfaces visible to this Editor. |
| `buffer_lifecycle` | `MingaEditor.State.BufferLifecycle` | Buffer monitor references and add context remain aligned with Editor-owned buffer lifecycle decisions. |
| `git` | `MingaEditor.State.Git` | Remote operation correlation, commit-generation correlation, and generated diff views represent in-flight Git presentation work. |
| `session` | `MingaEditor.State.Session` | Save timer, persistence paths, startup state, pending quit, and last test command share the Editor session lifecycle. |
| `effect_scheduler` | `MingaEditor.EffectScheduler` | The root stores only the scheduler process handle; admission, workers, queues, cancellation, and delivery remain process-owned. |
| `feedback` | `MingaEditor.State.Feedback` | Notifications and operation feedback form the Editor-wide user feedback projection. |
| `lsp` | `MingaEditor.State.LSP` | Server status, lenses, hints, selection ranges, debounce tokens, formatting correlations, and request correlations share LSP lifecycle. |
| `remote` | `MingaEditor.State.Remote` | Remote sessions, server status, and remote buffers share remote workspace identity. |
| `appearance` | `MingaEditor.State.Appearance` | Theme, font-size override, and cached native settings describe one presentation configuration. |

Traditional shell state is separately decomposed into focused owners for feedback, overlays, sidebars, observatory, agent surfaces, tool prompts, input state, space-leader state, and click regions. `MingaEditor.Shell.Traditional.State` is the aggregate that coordinates those values. It is not mirrored in the root.

## Retained root invariants

Root transitions remain only where one atomic operation crosses at least two rows in the ledger:

- Applying a theme updates `appearance` and parser-owned highlight presentation together.
- Integrating a renderer receipt validates render correlation and shell identity before committing render, workspace, and Traditional click-region observations.
- Resetting frontend render state coordinates frontend connection state, render correlation and layout observations, and window render caches.
- Buffer registration, removal, and empty-state entry coordinate workspace membership, buffer monitors, shell state, and render invalidation.
- Tab snapshot, restore, and switching coordinate workspace state, Traditional tab state, active agent presentation, and retiring tab-scoped LSP operations.
- Extension feature cleanup coordinates active workspace state and stashed shell or tab contexts.

Leaf changes call their owner APIs directly. Contributors must not add a root wrapper solely to avoid naming the leaf owner.

## Mechanical enforcement

`Minga.Credo.EditorStateOwnershipCheck` (EX9012) carries declarative metadata for each protected Editor struct: its concrete module, owner modules, receiver paths, transition boundary, and workflow boundary. It rejects explicit foreign struct updates, owned-path map updates, `put_in`, `update_in`, `Map.put`, and imported generic mutation calls. A workflow may install a focused owner result into its matching top-level root field only when the replacement expression calls that declared owner directly; raw values, wrong-owner results, and mixed root updates remain violations. This permits root installation without reintroducing a root forwarding API. Typed bindings are lexical and source ordered, so the check does not infer types backward or across unrelated branches.

The same metadata designates pure value and aggregate owners. Those modules may call other value-owner APIs, but the check rejects process and GenServer calls, timers, task creation, logging, rendering, filesystem and persistence work, and configured service boundaries. External work remains valid in workflow callers when those callers use owner transition APIs.

Public owner APIs named as generic setters, putters, mappers, accessors, lenses, mutators, or assigners are rejected when they accept an arbitrary field, key, or function instead of naming an invariant. Focused transitions remain valid even when an established API uses a `set_` prefix.

The ownership allowlist is empty after #2870. The check still validates the exception schema so a future temporary exception must name an exact module, function or MFA, violation kind, target, ticket, reason, and preserved invariant. Wildcards and path-based exceptions remain invalid.

Credo loads the check through `.credo.exs`. `make lint` applies Credo to changed Elixir files, and CI runs the strict project-wide check. Focused fixtures prove allowed owner writes and workflow effects as well as rejected leaf, aggregate, root, workflow, purity, generic API, malformed configuration, and exact-exception cases.

## Migration record

Epic #2861 converged the ownership model in dependency order:

| Area | Delivered by |
|---|---|
| File-tree refresh correlation and workflow | #2862 |
| Active shell identity, implementation, current state, and stash | #2863 |
| Render scheduling and receipt correlation | #2864 |
| Buffer activation and window focus invariants | #2865 |
| Traditional feedback and overlay lifecycles | #2866 |
| Traditional sidebars, agent presentation, and input state | #2867 |
| Workflow-specific external action execution | #2868 |
| Mechanical ownership and purity checks | #2869 |
| Final root ledger, compatibility deletion, empty allowlist, and documentation | #2870 |

The migration is accepted only with no duplicate root fields, generic bags, forwarding facades, universal effect dispatcher, broad mappers, deep-update helpers, or unexplained ownership exceptions.

## Alternatives rejected

- **One GenServer per substate:** This would replace cheap immutable transitions with mailbox coordination, introduce ordering races, and weaken the Editor's atomic input authority.
- **Move existing setters into smaller modules:** Relocated setters do not own invariants. They preserve the same invalid combinations behind more files.
- **Keep a universal root facade:** Forwarding every leaf operation through `MingaEditor.State` leaves contributors with two mutation paths and lets the root API grow without bound.
- **Use one universal action interpreter:** Domain transitions, timers, filesystem work, rendering, persistence, and agent lifecycle do not share one ordering or failure policy. The scheduler is a bounded lifecycle service, not a domain interpreter.
- **Store worker lifecycle in domain values:** Duplicating queued and running state creates contradictory authorities. The scheduler already owns those facts.
- **Use a generic `misc`, `runtime`, or `ui` bag:** A field-count target does not justify hiding unrelated state behind an owner with no behavioral invariant.

## Consequences

Contributors must locate the behavioral owner before adding a field or transition. Pure owner tests can prove invariants without processes, while workflow tests focus on ordering, correlation, and failure handling. Some root workflows remain intentionally broad when atomicity spans top-level owners, but each retained operation must document that invariant instead of acting as a compatibility delegate.
