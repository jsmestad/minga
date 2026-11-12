# ADR-0004: Minga is a programmable editor with shared definitions

**Status:** Accepted product and release direction in [#3542](https://github.com/jsmestad/minga/issues/3542). Supersedes the 2026-11-03 decision at this path. This reconciliation does not approve a production restricted live-source contract.

## Why this decision changed

Minga must let engineers improve their working environment without turning each customization into a fork of the editor. The previous decision made a neutral product host, a separate Chat product, fresh executable module names for every revision and deferred Go rendering prerequisites for that goal. Those mechanisms are no longer the approved direction.

The product is a programmable editor. Existing editor-oriented services may remain editor-oriented until a concrete supported capability needs a different boundary. A repository-wide coupling count, namespace rewrite or second application does not prove that customization works.

[#3542](https://github.com/jsmestad/minga/issues/3542) defines the full v0.1.0 outcome. The requirements below describe that accepted outcome, not an inventory of features that already ship.

## Two ways to develop the environment

1. **Customize Minga:** discover supported capabilities, reuse them, author missing behavior in ordinary readable source, Save to attempt activation, inspect the result and Keep useful definitions. A task expressible with installed capabilities must not require a native rebuild.
2. **Develop Minga itself:** add a missing runtime or native capability through ordinary source changes, tests, builds and a pull request. This does not imply that arbitrary Swift, Go, Zig, dependency or engine code hot-reloads.

The release workload exercises both paths. An engineer uses Minga's real editor and built-in agent to develop a reusable interactive graph component, inspect and edit source, steer architecture, request independent adversarial reviews, inspect actual checks and prepare the PR. During that work, the agent authors a meaningful review-workflow and interface improvement, Keeps it, restarts or reopens it, and reuses it on a different change without regenerating its definition. The graph capability must be merged into the release candidate, not left only in the demonstration PR.

The workflow must control actual review/check behavior. Prompt wording, a decorative dashboard, a static graph picture or a supplied completed application does not satisfy the promise. Existing build tools, Git and a browser remain usable; Minga does not need replacements for them.

The main conversation and one retained editor group stay independently usable while task-local views are created, changed, hidden and reopened. Inspecting a worker must not retarget the main conversation, lose its reading position or discard an unsent draft. Supported authored text inputs offer Vim and CUA; chat defaults to CUA with Vim opt-in, help uses active bindings and native OS dialogs remain native.

## Keep the existing authorities

Programmability changes policy and composition through supported contracts. It does not create a second owner for facts Minga already owns.

| Owner | Responsibility that remains authoritative |
|---|---|
| Buffer, document and history owners | Canonical text, edits, undo, revisions, selection and editing semantics. A view over a document edits that document, not a competing task database. Rebuildable indexes are allowed. |
| Agent, Session, tool and permission owners | Conversations, admitted turns, execution, cancellation, permissions and observed execution evidence. Authored UI does not gain its own scheduler, conversation store or execution journal. |
| Authored workflow policy | Context selection, delegation, check/review strategy and the domain decision that work is ready, using actual correlated outcomes from existing execution owners. |
| Proposed definition/admission owner | Shared source identity, trusted snapshots, namespace ownership, installed revision and bounded activation. This is not an all-instance migration transaction. |
| Application/record owner, where needed | Domain state not already owned by documents or runtime resources, named transitions, independent instance upgrades and truthful per-record persistence. Not a process per visual widget or Editor-generation state. |
| Composition and native presentation owners | Stable structure, bindings, action offers and semantic focus upstream; measurement, drawing, accessibility, native input and discardable presentation in each client. |

Built-in review behavior must use the same supported workflow capabilities as an authored replacement. Session lifecycle, arbitrary native code and permission enforcement do not become dynamically replaceable as a consequence.

Preserve [ADR-0001](0001-frontend-owns-row-fit.md), [ADR-0002](0002-editor-state-transitions-have-explicit-owners.md) and [ADR-0003](0003-extension-code-updates-require-a-new-vm-generation.md). The BEAM remains the semantic authority. Frontends report measurements and row fit; the BEAM must not derive row counts from pixel math or line spacing. Resident models and stable identities remain the navigation contract, with only discardable local presentation in frontends.

When a surface moves into shared composition, delete its superseded placement, visibility and input-routing authority. Do not leave two writable layout or input paths. Preserve canonical parser and native input owners rather than removing them to obtain a neutral host.

## Save source, then report activation separately

A shared definition has one current executable revision. Named extensions are shared across instances, with local instance data and settings. Saving an improvement must not silently fork its code for each workspace or keep historical executables permanently pinned per instance. Explicit variants remain possible.

An ordinary Save attempts one immutable source-unit snapshot. A grouped save has explicit membership and begin/complete/abort ownership; completion attempts exactly one snapshot. An interrupted group stays visibly pending or aborted, never inferred complete from elapsed time. Source-save success and activation success are separate outcomes. There is no additional Apply command for every revision.

Preparation, including compilation, requires an explicit revocable session grant as well as installation authority. The grant identifies the source unit, editing/execution scope and attribution. Check it before preparation and again before installation/publication, without prompting for every saved revision within its scope. Revocation closes new admission; it does not undo prior effects.

Trusted Elixir runs with OS-user privileges, including during disposable compilation. This is not a sandbox. Supported inspection and execution APIs still carry explicit permitted subjects: access to shared source is not permission to include unrelated workspaces' private content. Those API rules are not OS-level containment of full-trust code.

Keep makes useful source discoverable in future sessions, tabs and workspaces. It does not copy private task data or implicitly install an autostart policy. Preserve readable source and original instance data when code is missing or incompatible. Demonstrate missing-source inspection, restart/reopen and live authoring separately. Historical extension API compatibility is not promised, but wire negotiation and schema identification remain necessary for safe decoding.

Other Minga OS processes adopt shared-source changes by explicit reload or a later start, not a synchronized global hot update. An older process must not overwrite newer incompatible stored state.

## Definition, instance and record have different outcomes

Coupling source activation to every dormant saved record would make one incompatible instance block all users of a shared definition. The accepted contract separates those decisions.

| Operation | Required outcome |
|---|---|
| Definition activation | Admit one coherent current shared revision. Account for active executable consumers, in-flight work and publication, not an inventory and migration of every dormant record. |
| Instance upgrade | On open or use, upgrade that instance's data under the current definition. A failure preserves its original source/data and reports unavailability without reverting the shared definition or blocking unrelated instances. Do not silently reinitialize it. |
| Record commit | Report committed, conflict, definite failure or uncertain settlement truthfully. Identify the record, expected stored revision/schema, producing definition revision and operation identity; reject stale writers across Minga OS processes. |

A preparation or admission failure is not an instance-upgrade failure. Rejected candidates need a proved unchanged or restored accepted executable artifact before callbacks reopen; an uncertain restoration or interrupted authority must not be reported as successful activation. No force purge may be used to make replacement progress.

Source replacement must reconcile or fence active migration callbacks and pending writes without involving dormant records. An unavailable instance still accepts host-owned settlement evidence. An uncertain write stays uncertain until reconciled; do not claim rollback or automatically replay an uncertain external operation. Executable restoration cannot undo compilation or external effects; the supported definition-validation contract must be effect-free.

## What R0 establishes, and what remains a gate

The merged [R0 investigation](../investigations/3547_live_definition.md) demonstrates a bounded stable-name replacement sequence with helper-dependent calls, rejected-candidate restoration and independent instance failure/recovery. All four admission-owner interruption schedules remain explicitly unavailable. The fixture does not demonstrate automatic production recovery, arbitrary-source confinement, durable storage, grants, grouped Save, packaged compilation or native interaction.

That evidence enables the next restricted-source specification, not a production loader. ADR-0003 still requires a new VM generation for arbitrary extension code and dependency updates. Its restricted-API exit clause needs a separately reviewed boundary and real proof; this document grants no global loader exemption.

The candidate lanes in #3542 retain their own promotion contracts:

- **B0/L0:** specify the eligible source family, complete namespace inventory and admission owner, trusted preparation, grants/revocation, grouped Save, bounded callback/drain behavior, installer lifetime, restoration and publication authority before production implementation.
- **S0/S1/K0:** specify independent instance envelopes, per-record concurrency, durable commit/fencing, restart reconciliation, settlement after instance failure and retained-source discovery/reuse. Do not reuse the superseded all-record transaction.
- **D0/W0:** provide scoped capability/source discovery and an execution-facing check-plus-independent-review seam through the existing runtime. Results identify the assessed source/worktree revision; idleness, session handles and text are not completion evidence. Closing a view does not end admitted work. Stop closes new dependent-work admission before targeted cancellation; cancellation is not undo. Restart restores data without automatically resuming uncertain work.
- **H0/H1:** prove shared placement and input ownership through actual native interaction while preserving the retained editor and main conversation. Remove old authorities at cutover.
- **X0:** demonstrate real graph development and the agent-authored, kept review-workflow/UI improvement reused on a second change, through Swift and Go.
- **REL0/REL1:** qualify installed candidate artifacts without a source checkout or build caches, including provider access, editing, parser/helpers, live preparation and retained-source reuse. Development builds are not packaged-runtime proof.

Retain the canonical [runtime recovery gate #3441](https://github.com/jsmestad/minga/issues/3441), [delegation gate #3442](https://github.com/jsmestad/minga/issues/3442) and [real workspace gate #3454](https://github.com/jsmestad/minga/issues/3454), including their approved dependencies. Required bounded TLA+/PlusCal models and implementation-linked regressions belong at the affected admission, record, workflow and composition protocols. Model checking does not replace actual loader, filesystem, process or native evidence.

## Language and frontend direction

Elixir/BEAM remains the programmable editor and agent core. Swift remains the native macOS presentation/input/accessibility client. Go remains the maintained single production TUI. Required shared surfaces ship through both clients; terminal presentation may differ, but graph nodes, edges, targets and supported actions cannot disappear or remain indefinitely skipped.

Zig retains parser/query/grammar integration and the agent-hook process-group helper, not terminal rendering. The sibling Rust workspace is research, not a production dependency or a commitment to replace the core, Swift, parser or Go TUI. Any later adoption requires a separately authorized complete-cutover decision, concrete benefit, full-path compatibility evidence and deletion of the replaced implementation. Do not maintain two production TUIs indefinitely.

A real release consumer and a tested contract justify a required capability. There is no mandatory two-catalog-consumer prerequisite. A prebuilt factory board, universal workflow/effect interpreter, second long-lived authoring BEAM, automatic source forks and default webview escape hatch are not the implementation plan.

## Release checkpoint

Live authoring, composition, Keep, independent upgrades and second-change reuse remain inside the full v0.1.0 scope, including installed Swift GUI and production Go TUI proof. Optional Rust adoption, Linux GUI and richer post-release systems are not authorized by the current factory run.

Freeze an exact candidate with assets/checksums, toolchains, channel side effects, evidence and limitations. The current execution grant stops before creating or pushing any release tag or publishing any release, including a prerelease. Publication requires explicit candidate approval; post-v0.1 work requires a separate scope decision.
