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
