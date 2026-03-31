# Approach Comparison: Rewrite vs. Refactor to Agentic-First

A side-by-side evaluation of two paths from "text editor with an agent" to "agentic runtime with an optional editor." Includes architectural assessment from `archie` (BEAM architecture) and `swift-expert` (macOS frontend impact).

---

## The Two Approaches

**Approach A: Aggressive Rewrite** (`MINGA_REWRITE_FOR_AGENTS.md`)
Burn it down. Rebuild from scratch in 4 strict layers. No compatibility bridges, no feature flags. Delete the old code, write the new code, port nothing.

**Approach B: Incremental Refactor** (`MINGA_REFACTOR_TO_AGENTIC.md`)
Transform in place. 10 phases, ~40 PRs. Application works at every step. Move modules, sever couplings, add new systems alongside old ones, then swap.

Both target the identical architecture: Core Runtime → Agent Runtime → API Gateway → Clients. The destination is the same. Only the path differs.

---

## Timeline Comparison

### Approach A: Rewrite

| Weeks | Phase | What's Working |
|---|---|---|
| 1-4 | Core Runtime (buffer, events, config, LSP, git) | Headless buffer management, event bus. No agent, no editor. |
| 5-7 | Agent Runtime (tools, sessions, providers) | Agent sessions can execute tools against buffers. No UI. |
| 8-9 | API Gateway (WebSocket, JSON-RPC) | External clients can connect. Still no editor. |
| 10-14 | Reference Editor Client (vim FSM, rendering, chrome) | Full editing experience rebuilt on top of runtime API. |
| 15+ | Multi-agent, buffer forking, advanced features | Polish and advanced capabilities. |

**First working agentic runtime (headless):** Week 7
**First working editor:** Week 14
**Feature parity with today's Minga:** Week 16+ (optimistic)
**Realistic estimate (2-3x on rebuild):** 20-30 weeks

### Approach B: Refactor

| Weeks | Phase | What's Working |
|---|---|---|
| 1-2 | Sever upward deps (7 core refs + Agent.Events split) | Everything still works. Core modules are now independent. |
| 1-2 | Tool Registry + Executor (parallel with above) | Tools registered alongside commands. Agents use new path. |
| 3 | Buffer refcounts + Promote Agent.Supervisor | Buffers globally addressable. Agents are a peer of the editor. |
| 4-6 | Extract Editor State (domain vs. presentation) | Agent sessions can function without an editor. |
| 6-7 | Agent Runtime facade + Introspection | `Minga.Agent.Runtime` is the single API entry point. |
| 8-10 | API Gateway (WebSocket, JSON-RPC) | External clients can connect. |
| 10-11 | Self-description, runtime modification | LLMs discover and modify capabilities. |
| 12-13 | Buffer forking + three-way merge | Multi-agent concurrent editing. |
| 14 | Boundary enforcement (Credo check) | Layer rules are machine-verified. |

**First working agentic runtime (headless):** Week 7
**Editor works throughout:** Every week. Never breaks.
**Feature parity maintained:** Every PR.
**Realistic estimate:** 12-16 weeks (each PR is testable, so slippage is bounded)

### Timeline Verdict

Both approaches reach a working headless agentic runtime at roughly the same time (~7 weeks). The difference is what else works during those 7 weeks. The refactor has a functioning editor the entire time. The rewrite has nothing usable until Week 14.

---

## Agent Workforce Requirements

How many concurrent LLM coding agents can work on each approach, and what's the parallelism ceiling?

### Approach A: Rewrite

| Phase | Parallelizable? | Agent count | Why |
|---|---|---|---|
| Weeks 1-4 (Core) | Moderate | 2-3 | Buffer, Events, Config are independent. LSP and Git depend on Events. Each agent takes a subsystem. |
| Weeks 5-7 (Agent) | Limited | 1-2 | Tool system, sessions, and providers are tightly coupled. Tool.Executor needs Tool.Registry needs Tool.Spec. Sequential. |
| Weeks 8-9 (Gateway) | Moderate | 2 | WebSocket and JSON-RPC handlers are independent. |
| Weeks 10-14 (Editor) | Moderate | 2-3 | Vim FSM, rendering pipeline, chrome are somewhat independent. But they all converge on EditorState. |

**Practical parallelism: 2 agents average, 3 peak.** The rewrite's layer-by-layer build order creates sequential bottlenecks. You can't start Layer 1 until Layer 0's APIs are stable. You can't start the editor until the Runtime API exists.

### Approach B: Refactor

| Phase | Parallelizable? | Agent count | Why |
|---|---|---|---|
| Phase 1 + 2 (decouple + tools) | High | 3-4 | Phase 1 PRs are independent (each severs one coupling point). Phase 2 is entirely additive. All run in parallel. |
| Phase 3 + 4 (buffers + supervision) | Moderate | 2 | Buffer refcounts and supervision tree changes are independent. |
| Phase 5 (Editor State) | Limited | 1-2 | Extracting domain from presentation is sequential (each PR depends on the previous). |
| Phase 6 + 7 (facade + gateway) | High | 2-3 | The facade is a thin delegation layer. Gateway is independent of facade internals. |
| Phase 8 + 9 (introspection + forking) | High | 2-3 | Completely independent subsystems. |

**Practical parallelism: 2-3 agents average, 4 peak.** The refactor's PR-level granularity creates more parallel work items. Phase 1 alone has 6 independent PRs that can run on separate worktrees simultaneously.

### Agent Workforce Verdict

The refactor offers better parallelism because the work is granular (40 independent PRs vs. 4 sequential layers). The rewrite's sequential layer dependencies limit parallelism even with multiple agents.

**Optimal agent allocation:**
- Rewrite: 2 agents sustained, scaling to 3 during Core and Editor phases
- Refactor: 3 agents sustained, scaling to 4 during Phase 1 and Phases 8-9

---

## Risk Comparison

### Risks unique to the Rewrite

| Risk | Likelihood | Impact | Notes |
|---|---|---|---|
| **Rebuild takes 2-3x estimate** | High | Critical | Rewrites always do. The spec is 2,359 lines. The code is 126K lines. That 50:1 ratio represents unspecified decisions. |
| **97K lines of tests are lost** | Certain | High | Tests encode edge cases discovered over months. Can't port them because module boundaries change. Must rediscover. |
| **Protocol fidelity gap** | Medium | High | The new render pipeline must produce byte-identical output for 40+ opcodes. Any deviation corrupts the Swift frontend. 10-week gap between "spec says identical" and "code proves identical." |
| **Runtime design bugs surface late** | Medium | High | Layers 0-1 are built Weeks 1-7. The editor (first real integration client) starts Week 10. Design mistakes in the Runtime API have a 3-week feedback delay. |
| **Rebuilding already-correct code** | Certain | Medium | 24,963 lines of core modules (buffer, editing, events, config) are 92% reusable. Rewriting them adds zero architectural value but weeks of calendar time. |

### Risks unique to the Refactor

| Risk | Likelihood | Impact | Notes |
|---|---|---|---|
| **Agent.Events split (Phase 1 PR 1.4)** | Medium | Medium | 408-line module mixes domain and presentation. Incorrect split breaks agent chat rendering. Mitigation: snapshot tests, config flag fallback. |
| **Editor State extraction (Phase 5)** | Medium | Medium | 1,277-line struct decomposition while keeping everything working. Requires careful incremental extraction. |
| **Timeline stretches to 16 weeks** | Medium | Low | Maintaining backward compatibility adds overhead per PR. But you have a working product every day, so schedule slip doesn't cause a crisis. |
| **"Death by 40 PRs" fatigue** | Low | Low | Incremental refactoring is less exciting than greenfield. Agents don't get fatigued, but context maintenance across 40 PRs has overhead. |

### Risk Comparison Verdict

The rewrite has higher-likelihood, higher-impact risks. The refactor has more risks, but each is contained (one PR at a time, tests verify each step). The rewrite's failure mode is "Week 14 and things don't work together." The refactor's failure mode is "one PR is harder than expected, so it takes an extra few days."

---

## What Gets Lost in Each Approach

### Rewrite: What You Lose

- **97,125 lines of tests.** These are not trivially recreatable. They encode real edge cases (Unicode boundary conditions, gap buffer invariants under concurrent access, LSP protocol quirks, rendering pipeline timing, file watcher races). Some test files have been refined across dozens of bug fixes.
- **Implicit knowledge in code structure.** The existing `handle_info` clauses in `Editor.ex` encode real-world event orderings that were discovered through debugging. A rewrite starts from the spec, which doesn't capture "tree-sitter highlight events must be processed before the next render frame or you get stale colors."
- **Frontend protocol fidelity.** Both Swift and Zig frontends are tested against the current protocol encoder. A new encoder must produce identical bytes for all opcodes, or both frontends break simultaneously.
- **The vm.args.eex tuning.** The BEAM VM flags were profiled and tuned for the editor's specific allocation pattern (bursty IO lists, per-frame GC, long idle periods). A rewrite inherits the flags but may have different allocation patterns, making the tuning wrong.

### Refactor: What You Lose

- **Clean namespace from day one.** The refactor keeps `Minga.Buffer` instead of `Minga.Core.Buffer` until Phase 10. The module names don't reflect the layer structure during the transition. (This is cosmetic. The Credo boundary check enforces the actual rules regardless of namespace.)
- **"Clean room" feeling.** The refactored code carries artifacts of its history. Some modules will have slightly awkward APIs because they were designed for the editor-first world and adapted for the agentic-first world, rather than designed for it from scratch.
- **Some dead code and vestigial patterns.** The refactor moves and restructures but doesn't audit every line. Some helper functions, unused branches, or over-specified types will survive the transition. A cleanup pass after the refactor addresses this.

---

## What Archie Says

Archie verified the coupling claims against the actual codebase and ran the numbers:

> **The existing codebase is 93% correctly layered already.** 44 upward dependencies in 126K lines is not a "burn it down" level of coupling. It's a "fix 13 files" level of coupling.

> **~95,000 of 126K lines (75%) are directly reusable with zero or trivial changes.** Another ~25,000 (20%) need refactoring (moving modules, splitting domain/presentation, updating aliases). About 5,000 (4%) need significant rework. Essentially nothing needs ground-up rewriting.

> **The rewrite is the wrong path.** The BEAM specifically makes incremental migration safe and fast. Process isolation, hot reload, and supervision trees mean you can restructure the runtime while it's running. The rewrite throws away the one platform advantage that makes a refactor painless.

> **There is no meaningful hybrid.** The refactor document IS the hybrid. It does mechanical moves first, builds new infrastructure alongside old, and only restructures hard coupling points after the foundation is clean. The rewrite doesn't contain any architectural ideas the refactor can't incorporate.

Archie's reusability breakdown:

| Layer | Lines | Reusable as-is | Needs refactoring | Needs rewriting |
|---|---|---|---|---|
| Core (buffer, editing, config, lsp, git, etc.) | 24,963 | 92% | 7% (fix 7 upward deps) | 0% |
| Agent tools | 2,907 | 99% | 0% | 0% |
| Agent domain (session, provider, cost, etc.) | ~5,000 | 90% | 10% | 0% |
| Agent presentation (events, views, slash) | ~2,500 | 0% | 100% (move to editor layer) | 0% |
| Editor layer | 67,233 | 89% | 10% | 0% |
| Editor.ex (the hub) | 2,137 | 0% | 0% | 100% (decompose) |
| Tests | 97,125 | 93% | 7% (update refs) | 0% |

---

## What Swift-Expert Says

Swift-expert analyzed the macOS frontend impact:

> **Approach B is unambiguously better for the macOS frontend.** The Swift frontend never breaks, risk is distributed across small PRs, and you get incremental verification at every step. Approach A's 10-week gap between "protocol spec preserved" and "protocol implementation verified" is a real hazard.

> **Don't add WebSocket to the Swift frontend.** The single-transport, single-dispatcher architecture is the frontend's best property. Extend the Port protocol for agent streaming instead. One new opcode vs. a second transport with consistency problems.

> **The XcodeGen build pipeline has zero coupling to BEAM internals.** Neither approach requires build pipeline changes.

On protocol fidelity risk in the rewrite:

> The Swift `ProtocolDecoder` does unchecked positional reads. A single byte misalignment cascades into garbage for the rest of the frame. The rewrite must produce byte-identical output for 40+ render opcodes and 50+ GUI action sub-opcodes. There's a 10-week window where this can't be verified.

On opportunities both approaches enable:

> **Native tool approval dialogs** (low effort, high impact): one new opcode, one SwiftUI sheet. Possible as soon as Tool.Executor exists (Phase 2 of refactor).

> **Ghost cursors for agent edits**: Metal renderer already draws cursor quads. Adding semi-transparent agent cursors is a few new fields in the protocol and a few new quads in the render pass.

> **Surviving BEAM restarts**: With agent sessions independent of the editor, a BEAM crash and restart can re-emit full state. The user sees a brief flash, not a total reset.

---

## Speed-to-Value Comparison

What does each approach deliver at key milestones?

| Milestone | Rewrite | Refactor |
|---|---|---|
| **Core modules independent of Editor** | Week 4 (built from scratch) | Week 2 (sever 7 refs) |
| **Tool system operational** | Week 6 | Week 3 (parallel with Phase 1) |
| **Agent sessions run without editor** | Week 7 | Week 7 |
| **External clients can connect (API gateway)** | Week 9 | Week 10 |
| **Working editor on top of new architecture** | Week 14 (rebuilt from scratch) | Week 0 (never broke) |
| **Self-description for LLMs** | Week 9 | Week 11 |
| **Buffer forking for multi-agent** | Week 15+ | Week 13 |
| **Full feature parity** | Week 20+ (realistic) | Week 14 (with cleanup) |
| **97K test suite passing** | Week 20+ (tests rewritten) | Week 14 (tests updated) |

The refactor reaches feature parity 6+ weeks earlier because it doesn't rebuild working code.

---

## Cost Comparison

Measured in "agent-weeks" (one LLM agent working full-time for one week).

### Approach A: Rewrite

| Phase | Weeks | Agents | Agent-Weeks |
|---|---|---|---|
| Core Runtime | 4 | 2.5 | 10 |
| Agent Runtime | 3 | 1.5 | 4.5 |
| API Gateway | 2 | 2 | 4 |
| Editor Client | 5 | 2.5 | 12.5 |
| Advanced features | 3 | 2 | 6 |
| **Total** | **17** | | **37 agent-weeks** |

With 2-3x rewrite multiplier: **50-75 agent-weeks realistic.**

### Approach B: Refactor

| Phase | Weeks | Agents | Agent-Weeks |
|---|---|---|---|
| Phases 1-2 (decouple + tools) | 2 | 3 | 6 |
| Phases 3-4 (buffers + supervision) | 1 | 2 | 2 |
| Phase 5 (Editor State) | 3 | 1.5 | 4.5 |
| Phases 6-7 (facade + gateway) | 3 | 2.5 | 7.5 |
| Phases 8-9 (introspection + forking) | 3 | 2.5 | 7.5 |
| Phase 10 (boundaries + cleanup) | 1 | 2 | 2 |
| **Total** | **13** | | **29.5 agent-weeks** |

With 1.2x incremental overhead: **35 agent-weeks realistic.**

### Cost Verdict

The refactor costs roughly half the agent-weeks. The rewrite's cost is dominated by rebuilding the editor client (12.5 agent-weeks for code that already exists and works) and the 2-3x multiplier that rewrites consistently incur.

---

## Recommendation

**The refactor wins on every axis:**

| Criteria | Rewrite | Refactor | Winner |
|---|---|---|---|
| Time to headless runtime | 7 weeks | 7 weeks | Tie |
| Time to working editor | 14-20 weeks | 0 (never breaks) | **Refactor** |
| Time to feature parity | 20+ weeks | 14 weeks | **Refactor** |
| Agent-weeks cost | 50-75 | ~35 | **Refactor** |
| Peak parallelism | 3 agents | 4 agents | **Refactor** |
| Test suite preservation | Lost (97K lines) | Preserved (93% as-is) | **Refactor** |
| Swift frontend risk | High (10-week gap) | Low (incremental) | **Refactor** |
| Protocol fidelity risk | Medium (new encoder) | None (same code) | **Refactor** |
| Rewrite multiplier risk | 2-3x on 17 weeks | 1.2x on 13 weeks | **Refactor** |
| Architectural purity | Higher (clean-room) | Slightly lower (historical artifacts) | Rewrite |
| Clean namespace | From day one | Phase 10 | Rewrite |

The rewrite wins only on aesthetics (cleaner namespaces, no historical artifacts). The refactor wins on speed, cost, risk, test preservation, and frontend safety.

**The rewrite document is still valuable.** It's the target architecture spec. The refactor uses it as the destination and the refactor doc as the route. Think of `MINGA_REWRITE_FOR_AGENTS.md` as the blueprint and `MINGA_REFACTOR_TO_AGENTIC.md` as the construction plan.

---

## Recommended Execution Plan

1. **Start Phases 1 and 2 in parallel with 3-4 agents.** Phase 1's 6 PRs are independent. Phase 2 is additive. This is the highest-parallelism window.

2. **Phase 4 (promote Agent.Supervisor) immediately after Phase 1.** One PR, two files. This is the structural change that makes "agents run without an editor" possible at the supervision level.

3. **Phase 5 (Editor State extraction) is the critical path.** Start as soon as Phase 1 lands. This is where 1-2 agents work sequentially on the hardest decoupling. Time-box the Agent.Events split to avoid it becoming a sinkhole.

4. **After Phase 6, you have the inflection point.** `Minga.Agent.Runtime` exists as a working facade. External clients are possible. The editor is still fully functional. From here, the gateway (Phase 7) and advanced features (Phases 8-9) are additive and highly parallelizable.

5. **The rewrite doc becomes the API design guide.** When building the facade (Phase 6), gateway (Phase 7), and introspection (Phase 8), reference the rewrite doc's module specs. They're well-designed API surfaces. Just implement them against the existing codebase instead of rebuilding the codebase first.
