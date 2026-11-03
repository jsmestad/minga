# ADR-0004: Products are root applets over a fixed engine; scripted code runs in host workers as new module generations

**Status:** Proposed (2026-11-03). Refines ADR-0003's exit clause. Implementation epic: filed after acceptance. Design record: two adversarial review rounds over three proposal drafts, summarized under "Alternatives rejected".

## Decision

Minga splits into a fixed engine and a dynamic tier.

The engine is everything a frontend has compiled knowledge of: the core services that headless boots (buffers, agent runtime, LSP, git, config), the surface host (the Editor generation and the separate Renderer process), the primitive struct set and its semantic opcodes, the frame protocol and resident store, the input router and focus tree, and the window layout opcode. The engine changes only through ordinary pull requests and activates only in a new VM generation, exactly as ADR-0003 requires.

The dynamic tier is everything expressible as data the frontends already render: products, their root view, and the applets they compose. A product is a root applet whose view is a region tree. The Editor is the first product. Agent Chat is the second. Session applets are drafted by an agent inside an agent session and scoped to it.

There is one scripting contract, `Minga.Applet`, in Layer 0:

```elixir
@callback contract_version() :: pos_integer()
@callback init(Minga.Applet.Context.t()) :: {model, [effect]}
@callback update(model, intent) :: {model, [effect]}
@callback view(model) :: Minga.RenderModel.UI.Primitive.t()
@callback subscriptions(model) :: [subscription]
@callback migrate(from :: module(), model) :: {:ok, model} | :reinit
```

Callbacks return inert data only: no funs, pids, references, or ports at any depth. Effects are a closed, versioned sum type where each tag maps to one existing operation-named host workflow. Subscriptions are declared, not performed; the host delivers matching events as intents and cancels them on unmount or redefinition. This is a scoped exception to the AGENTS.md rule against effect lists, legitimate only because the author is on the far side of a contract boundary; host internals outside the contract still never return effect lists.

Four rules make the contract provable:

1. **Scripted code never runs in the Editor or the Renderer.** Session and extension applets run as resource-serialized `MingaEditor.EffectScheduler` invocations with a deadline and a heap limit, one in flight per mount. The worker runs `update/2` over the queued intent batch, runs `view/1` once, checks inertness and tree shape, and returns `{model, tree, effects}`. The Editor installs the result only if the mount's request id still matches. A timeout or heap kill faults the mount into an error card with the last good snapshot retained. Frames carry trees as data and `view/1` never runs per frame.
2. **Redefinition adds a module; it never replaces one.** Every definition compiles as a module that was never loaded before, `Minga.Session.Applet.<Name>.G<n>`, with the generation assigned by the host. Redefinition is one Editor transition that installs the new identity together with the migrated model. In-flight frames finish on the old module. Revert remounts the previous identity, which is still loaded. Old generations are collected later with `:code.delete/1` and `:code.soft_purge/1`, retried, and only after the mount's scheduler resource is cancelled. Hard purge is never used. ADR-0003's exit clause named "a restricted extension API"; this is it, and it is provable because "add a new immutable module" is a fact the code server can confirm, where "replace a module safely" is not.
3. **Host-compiled products run inline and are not scripted.** The Editor product (today `Shell.Traditional`) implements the same `Minga.Applet` callbacks against the same data contract but runs in the Editor turn, because it co-owns the workspace synchronously and because a faulted root leaves no UI. The runner is chosen from the applet identity's source at one dispatch point. Host-compiled product code is engine code: compiled with the engine, versioned with the engine, never redefined at runtime.
4. **Safety is reversibility, not containment.** Applets are full-trust Elixir in the editor VM. Every definition is source-tagged, diffable, revertible, and recorded in `*Messages*` and the session transcript. Nothing in this design is a sandbox, and no document may imply one.

## Layout authority

The BEAM owns structure. The frontends own measurement.

The BEAM commits the tree, child order, containment, size policy, scroll ownership, focus order, and a modal flag per node. Size policy is a flex weight plus preferred and minimum size hints in structural units: `:intrinsic`, `{:chars, n}`, or `{:lines, n}`, resolved by each frontend against its own font. The BEAM owns the committed size of every user-resizable split as a unitless fraction, which the frontend drags locally and commits on release, following the existing `WindowTree` ratio and `BottomPanel.height_percent` precedents. Overlays anchor to a node id or a buffer position. There are no absolutely positioned nodes.

Frontends measure text, place nodes within a region, and hit-test their own rendered content. They send `{mount_id, node_id, event}` and never a payload or a coordinate; the host resolves the committed tree's action for that node. Drag is identity-only: a hit target declares what it can drag and what it accepts, the event names the source node and a before-or-after position the frontend derives from the target's own rect. Each scroll container reports its visible node range on settle, in the pattern ADR-0001 set for row fit, and the committed scroll anchor is a node id. Spatial focus navigation between regions is structural (move to the sibling subtree in the requested direction, then descend to the most recently focused leaf); geometric navigation by rect centers stays inside the editor grid, which really is a grid.

This generalizes the #2330 input rule already recorded in `MingaEditor.Layout.SurfaceRegistry` (frontends hit-test their own content and send semantic intents; native GUIs own final pixel placement) and the ADR-0001 pattern (the frontend reports what fits, the BEAM lays out in what it is given). A cell-based layout on the BEAM would reintroduce the unit leak that made the macOS frontend opt out of the 0xA4 surface layout opcode, and would be wrong under proportional fonts.

Hit identity is the only cross-frontend fact. Conformance is a placement-relation transcript (each frontend lays out the same committed tree in its own units and asserts containment, sibling order, minimum sizes, and weight shares within one unit) plus a hit transcript (a synthesized pointer inside each hit target emits the expected intent bytes, with the modal winner decided by committed order). Pixel equality and cell equality stay per frontend.

## Text input

An `Input` node is not an applet-rendered text field fed one intent per keystroke. Each `Input` node owns a `Minga.Buffer.Process` started and monitored by the Editor, and keys reach it through the mode FSM in the same Editor turn, exactly as the agent prompt does today. Vim modes, undo, IME composition, and bulk insert therefore come free, no applet rebuilds text editing, and a slow or faulted applet cannot stop typing. The applet sees changed or submitted intents, with repeated change intents coalesced to the latest per node, and may set text through an effect.

## Admission and versioning

A primitive or embed target enters the engine only when two catalog pieces need it; one consumer is a composition, not a primitive. A guardrail reads the real struct set, renders every catalog applet's golden model through its real `view/1`, and fails unless every primitive appears in two distinct applets' trees or carries an exemption naming the second consumer's ticket. A second guardrail requires a conformance transcript for every primitive on every active frontend.

The contract version is major.minor. A major bump refuses to mount; a minor bump is additive. Frontends advertise the primitive set version they support in the ready handshake and a product declares what it requires. Session applets re-initialize on a major bump and are never migrated across one; only catalog applets receive `migrate/2`. A committed fingerprint of the primitive tag set and callback list fails a test when the contract changes without a version bump.

## Frontends

The macOS window becomes a region host: one window input host (keys, IME client, key equivalents, ready and resize, focus-policy attachment, drop, backing scale, and the window setup that today lives in the editor view's `viewDidMoveToWindow`) that is always mounted, and an editor surface mounted only when the committed layout has an editor region. New shared layout opcodes use structural units, never cells or pixels.

The Go TUI is parked, not dropped. The region half of its layout rework (a solver for the region tree, a rect map, identity intents for wheel and divider drag, a per-region size report) lands in the same step as the window layout opcode, because consuming that opcode without it would force the BEAM to keep a second, cell-based layout emission path for one frontend. The primitive renderer half is deferred: new primitive transcripts enter the corpus marked skipped for Go with a stated reason, the skip count is the visible rot measure, and products that need primitives mount only on frontends advertising the capability. Two obligations stay on Go from the first primitive ticket: the primitive opcode is fully schema-generated including nested trees, and a layout-only measurement check asserts every primitive has a declared terminal form. The TUI is dropped only if nobody needs an interactive editor on Linux or over SSH within two quarters of acceptance; before deleting it, the cross-language golden manifest moves out of the Go tree.

A web frontend is additive and last, accepted only once the primitive set has transcripts a non-Swift, non-Go consumer can run.

## Packaging

One runtime, one monorepo. The product is chosen at boot by widening the existing `:default_shell` option and registering a second entry in the shell registry. The seams this ADR names are enforced in-tree: the dependency-direction check gains an engine tier, Chat and catalog modules are forbidden by a data-driven rule from referencing Editor-product modules, and a boot probe starts the host with the Chat product and walks its state for forbidden struct modules. Separate bundles are not precluded, but nothing in the design requires them, and the seam is proven by the checks, not by the package boundary.

## Build order

1. This ADR, docs only.
2. Host neutrality in slices, with byte-identical conformance transcripts as the oracle. The first slice makes `MingaEditor.FocusTree` shell-neutral by moving its eight Editor-product clauses behind one callback. Later slices replace the root workspace and shell runtime with a product runtime, add mounts, express the Editor product as a host-compiled root applet, shrink the shell contract, and move product-neutral `MingaEditor.*` modules into the engine tier.
3. The Chat product inside today's macOS window, proven independent by the forbidden-reference rule and the boot probe.
4. Window composition on both frontends: the window layout opcode, the macOS region host and input-host split, the Go region solver, BEAM deletion of its TUI cell geometry.
5. The applet runtime and primitive set: `Minga.Applet`, the primitive structs, mounts, the applet loader, worker invocation, the inert check, the compiler-tracer denylist, generated decode, the macOS tree renderer, the Go measurement check, one ported catalog surface, `Input` with host buffers and the focus-owner payload extension together.
6. Session applets: the agent tool pack (define, redefine, mount, unmount) under the existing approval policy, with diff, revert, and transcript record.
7. Generation restart with session restore for engine changes.
8. The TUI primitive renderer, or the drop decision.
9. A web frontend.

## Alternatives rejected

- **A fixed component vocabulary (board, list, form).** The product goal is an agent drafting ad-hoc UI and logic for the task at hand. A vocabulary of finished components is the opposite of that and is the shape of the deleted Board shell (#1965, removed in #2396).
- **Recomposing existing surfaces without dynamic logic.** A kanban needs business logic, not only placement.
- **In-place module replacement with soft purge.** Frames in flight carry the module atom, presentation code already runs in the Renderer on an asynchronously cast snapshot, the compile cache skips already-loaded modules, and a third definition would need a purge. ADR-0003 rejected this for extensions and the reasons hold for applets.
- **Inline scripted callbacks in the Editor or Renderer.** No preemption; the extension callback invoker has no timeout; the existing eval command already blocks the Editor for up to five seconds on the same pattern.
- **One long-lived process per applet.** ADR-0002: values with owners, not additional processes. It also duplicates input serialization and moves the model out of stash and restore.
- **Applet models in feature state.** Feature state is per tab, snapshotted with tabs, and silently drops unknown sources.
- **A separate shell contract beside the applet contract.** Its layout, mounts, and routing callbacks were three projections of one state that could disagree, it still needed an update callback for events, and it had no home for a session-authored shell. One tree cannot disagree with itself.
- **Cell-based layout of primitive trees on the BEAM.** See "Layout authority". Decided and closed.
- **Region sizes held only in frontend state.** They do not survive a generation restart and disagree between frontends.
- **Extending the focus tree's cell hit path or the 0xA4 opcode to primitives.** Both serve BEAM-routed cell input, which the Go layout rework deletes.
- **Per-keystroke applet intents for text input.** Two synchronous scheduler calls and a spawn per keystroke, and a slow applet stops typing.
- **Loading session applets through the extension admission ledger or compile cache.** The ledger rejects runtime redefinition on purpose (sealed generation, one artifact per source, grow-only module map) and those invariants are correct for extensions. Applets get their own loader and ledger.
- **A bytecode import lint as the inert-data gate.** It cannot see `send/2`, `apply/3`, or dynamic calls and has no line numbers. The denylist lives in the isolated compiler tracer, which sees every remote call with file and line, and the runtime deep walk in the worker is the real gate.
- **Editor windows as an applet primitive.** The Metal surface is one grid with one row-fit fact under ADR-0001. Editor embedding is a region-tree leaf.
- **Building Chat before host neutrality.** It would add a sibling Chat state clause beside every Editor-product state clause at the root, the exact branching AGENTS.md Rule 3 forbids.
- **Renaming `MingaEditor.*` first.** A namespace move proves nothing until the Editor product compiles against a neutral host; it closes the host-neutrality step instead of opening it.
- **A Chat-only or read-only TUI.** Chat becomes catalog applets, so rendering it on the legacy chat opcodes would be a third emission path, and rendering it through primitives is the catch-up itself.
- **Terminal graphics (kitty, sixel) in the first primitive set.** They bypass the cell-buffer diff renderer. Images degrade to an alt-text box; graphics are a separate ticket.

## Consequences

Agents can draft, mount, redefine, and revert UI with logic inside a session without a restart, and the engine can prove it never replaced code in place. Engine changes still require a new VM generation. The Editor product is rebuilt on the same contract it offers everyone else, which is how the platform is validated. Chat runs without the editor. Frontends gain one generic tree renderer and one region host each and no product-specific views.

The costs are real: the host-neutrality step is the largest single piece of work and touches most shell-related tests; the primitive set is the most expensive thing to change later, which the two-consumer rule and minor versioning are meant to contain; Go gains a small second layout solver that must agree with the macOS frontend on relations; and a closure created inside an applet and handed to another process is undetectable by the inert walk, which is accepted and recorded because the no-processes rule makes it unreachable in practice.
