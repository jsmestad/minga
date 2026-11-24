/* Architecture interactive visualizers: BEAM Fault-Injection Process Map + 4-Step Staged Overlay & 3-Way Merge Stepper. */

export type ArchNodeId = "parser" | "lsp" | "mcp" | "hook" | "frontend" | "agent";

export interface ArchFaultState {
  readonly parserCrashed: boolean;
  readonly lspHung: boolean;
  readonly mcpCrashed: boolean;
  readonly hookRaised: boolean;
  readonly frontendDetached: boolean;
  readonly agentCrashed: boolean;
  readonly log: readonly string[];
}

export function createArchFaultState(): ArchFaultState {
  return {
    parserCrashed: false,
    lspHung: false,
    mcpCrashed: false,
    hookRaised: false,
    frontendDetached: false,
    agentCrashed: false,
    log: ["[BEAM] All 8 process boundaries healthy. Editor Core mailbox: <1ms latency."],
  };
}

export function toggleArchFault(state: ArchFaultState, node: ArchNodeId): ArchFaultState {
  const push = (entry: string): readonly string[] => [entry, ...state.log].slice(0, 4);

  switch (node) {
    case "parser": {
      const next = !state.parserCrashed;
      return {
        ...state,
        parserCrashed: next,
        log: push(
          next
            ? "[Supervisor] minga-parser (Zig OS port) segfaulted on malformed grammar. Supervisor respawned it in 14ms; open buffers and typing never stalled."
            : "[Supervisor] minga-parser healthy; visible lines re-highlighted cleanly.",
        ),
      };
    }
    case "lsp": {
      const next = !state.lspHung;
      return {
        ...state,
        lspHung: next,
        log: push(
          next
            ? "[LSP Isolation] ElixirLS blocked for 10s on full workspace reindex. Runs in its own BEAM process; Editor Core keystrokes stay <1ms."
            : "[LSP Isolation] ElixirLS responsive again; diagnostics stream resumed.",
        ),
      };
    }
    case "mcp": {
      const next = !state.mcpCrashed;
      return {
        ...state,
        mcpCrashed: next,
        log: push(
          next
            ? "[MCP Supervisor] GitHub MCP stdio process exited (SIGKILL). Only mcp_github__* tools dropped out; built-in file tools and open buffers stayed live."
            : "[MCP Supervisor] GitHub MCP restarted cleanly; tools re-registered.",
        ),
      };
    }
    case "hook": {
      const next = !state.hookRaised;
      return {
        ...state,
        hookRaised: next,
        log: push(
          next
            ? "[Hook Isolation] User :after_save callback raised MatchError. Exception contained in background Task; buffer save succeeded and editor kept running."
            : "[Hook Isolation] Cleared :after_save error state.",
        ),
      };
    }
    case "frontend": {
      const next = !state.frontendDetached;
      return {
        ...state,
        frontendDetached: next,
        log: push(
          next
            ? "[Client Bridge] macOS Metal UI process disconnected. BEAM core, open buffers, undo trees, and running agent turns stayed alive waiting for reattach."
            : "[Client Bridge] Reattached client; full viewport state streamed back immediately.",
        ),
      };
    }
    case "agent": {
      const next = !state.agentCrashed;
      return {
        ...state,
        agentCrashed: next,
        log: push(
          next
            ? "[Draft Durability] Agent turn process crashed mid-stream. Unpublished overlay stayed persisted in staged_drafts; open buffers and undo stayed intact."
            : "[Draft Durability] Agent session recovered with staged drafts intact.",
        ),
      };
    }
  }
}

export type StagedStep = 1 | 2 | 3 | 4;

export interface StagedPipelineState {
  readonly step: StagedStep;
  readonly conflictMode: boolean;
  readonly crashedAndRecovered: boolean;
}

export function createStagedPipelineState(): StagedPipelineState {
  return { step: 1, conflictMode: false, crashedAndRecovered: false };
}

export interface StagedViewSnapshot {
  readonly headline: string;
  readonly diskStatus: string;
  readonly diskBadge: "clean" | "published";
  readonly diskLines: readonly string[];
  readonly bufferBadge: string;
  readonly bufferLines: readonly string[];
  readonly overlayBadge: string;
  readonly overlayLines: readonly string[];
  readonly explanation: string;
}

export function computeStagedSnapshot(state: StagedPipelineState): StagedViewSnapshot {
  const baseDisk = [
    "238 def classify(status) do",
    "239   if status >= 500, do: :retry, else: :fatal",
    "240 end",
    "241 def timeout_ms, do: 5_000",
  ];

  if (state.step === 1) {
    return {
      headline: "Step 1: Revision-checked read and edit proposal",
      diskStatus: "git status: clean (0 files modified)",
      diskBadge: "clean",
      diskLines: baseDisk,
      bufferBadge: "rev: 42 · untouched",
      bufferLines: baseDisk,
      overlayBadge: "Reading rev: 42 -> proposing +3 lines",
      overlayLines: [
        "Tool call: edit_file(path: \"retry.ex\", base_rev: 42)",
        "✓ Revision matches current buffer (42 == 42)",
        "Preparing isolated overlay fork (no disk write)...",
      ],
      explanation: "Agent tools must pass the file's revision token from a full read. Stale edits reject cleanly before mutating anything.",
    };
  }

  if (state.step === 2) {
    const humanLine = state.conflictMode
      ? "239*  if status >= 500, do: :backoff, else: :fatal # yours"
      : "241* def timeout_ms, do: 15_000  # your edit";
    const bufferLines = state.conflictMode
      ? [baseDisk[0]!, humanLine, baseDisk[2]!, baseDisk[3]!]
      : [baseDisk[0]!, baseDisk[1]!, baseDisk[2]!, humanLine];

    return {
      headline: state.conflictMode
        ? "Step 2: Agent stages in overlay while you edit the SAME line"
        : "Step 2: Agent stages in overlay while you keep coding",
      diskStatus: "git status: clean (disk untouched)",
      diskBadge: "clean",
      diskLines: baseDisk,
      bufferBadge: "rev: 43 · your edit live",
      bufferLines,
      overlayBadge: "Staged fork (base rev: 42)",
      overlayLines: [
        "238 def classify(status) do",
        "+239  case status do",
        "+240    429 -> :rate_limited",
        "+241    code when code >= 500 -> :retry",
        "242 end",
      ],
      explanation: "Approved agent edits land in an isolated overlay. Your open buffer, cursor, undo stack, and disk working tree never race with the agent.",
    };
  }

  if (state.step === 3) {
    const humanLine = state.conflictMode
      ? "239*  if status >= 500, do: :backoff, else: :fatal # yours"
      : "241* def timeout_ms, do: 15_000  # your edit";
    const bufferLines = state.conflictMode
      ? [baseDisk[0]!, humanLine, baseDisk[2]!, baseDisk[3]!]
      : [baseDisk[0]!, baseDisk[1]!, baseDisk[2]!, humanLine];

    return {
      headline: state.crashedAndRecovered
        ? "Step 3: Editor restarted and restored staged draft automatically"
        : "Step 3: Syntax-highlighted review + crash-safe draft persistence",
      diskStatus: "git status: clean (still unpublished)",
      diskBadge: "clean",
      diskLines: baseDisk,
      bufferBadge: state.crashedAndRecovered ? "Restored rev: 43 · intact" : "rev: 43 · focus stays here",
      bufferLines,
      overlayBadge: state.crashedAndRecovered
        ? "Recovered from ~/.local/share/minga/staged_drafts"
        : "Persisted atomically in staged_drafts",
      overlayLines: [
        state.crashedAndRecovered
          ? "✓ Editor crashed & restarted: draft reloaded with base_rev: 42"
          : "Saved private draft: ~/.local/share/minga/staged_drafts/retry.ex",
        "Hunk 1/1: +3 -1 lines (syntax-highlighted diff viewer)",
        "Ordinary :q warns if unpublished; ready for SPC a p publish.",
      ],
      explanation: state.crashedAndRecovered
        ? "Because draft durability lives in an independent service outside the editor process, killing the editor never loses unpublished agent work."
        : "Staged diffs open quietly without stealing focus. Drafts persist atomically outside the editor process so restarts never lose work.",
    };
  }

  // Step 4: Publish / 3-way merge
  if (state.conflictMode) {
    return {
      headline: "Step 4: Overlapping edit detected -> safe conflict review",
      diskStatus: "git status: clean (publish paused for conflict)",
      diskBadge: "clean",
      diskLines: baseDisk,
      bufferBadge: "rev: 43 · protected (not overwritten)",
      bufferLines: [
        baseDisk[0]!,
        "239*  if status >= 500, do: :backoff, else: :fatal # preserved!",
        baseDisk[2]!,
        baseDisk[3]!,
      ],
      overlayBadge: "Conflict on line 239 · manual resolution",
      overlayLines: [
        "<<<<<<< your buffer (rev 43)",
        "  if status >= 500, do: :backoff, else: :fatal",
        "=======",
        "  case status do 429 -> :rate_limited; code when code >= 500 -> :retry end",
        ">>>>>>> agent overlay (base rev 42)",
      ],
      explanation: "Because both you and the agent edited line 239, 3-way merge refuses to silently overwrite your edit and opens explicit conflict review instead.",
    };
  }

  const merged = [
    "238 def classify(status) do",
    "239   case status do",
    "240     429 -> :rate_limited",
    "241     code when code >= 500 -> :retry",
    "242   end",
    "243 def timeout_ms, do: 15_000  # your edit preserved!",
  ];
  return {
    headline: "Step 4: Clean 3-way merge published via SPC a p",
    diskStatus: "git status: modified retry.ex (published cleanly)",
    diskBadge: "published",
    diskLines: merged,
    bufferBadge: "rev: 44 · merged cleanly (1 undo step)",
    bufferLines: merged,
    overlayBadge: "Overlay cleared · draft removed",
    overlayLines: [
      "✓ 3-way merge applied agent hunk (lines 238–242) + kept your line 243 edit",
      "✓ Written cleanly to buffer and working tree",
      "✓ Undo stack intact if you want to revert",
    ],
    explanation: "Non-overlapping edits merge cleanly via 3-way merge into both your open buffer and disk in one atomic step, preserving your undo history.",
  };
}

function esc(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

export function mountArchFaultMap(root: HTMLElement): void {
  let state = createArchFaultState();

  function render(): void {
    const anyFault =
      state.parserCrashed ||
      state.lspHung ||
      state.mcpCrashed ||
      state.hookRaised ||
      state.frontendDetached ||
      state.agentCrashed;

    const coreNodes = [
      {
        name: "Editor Core",
        boundary: "BEAM GenServer",
        statusLabel: "ALIVE · <1ms",
        detail: anyFault ? "Keystrokes unaffected despite downstream fault" : "Orders every keystroke, drawer, and modeline frame",
      },
      {
        name: "Open Buffers & Undo",
        boundary: "1 process / file",
        statusLabel: "100% INTACT",
        detail: "Isolated per-file heaps; zero unsaved text lost",
      },
    ];

    const faultNodes: readonly {
      readonly id: ArchNodeId;
      readonly name: string;
      readonly boundary: string;
      readonly status: "ok" | "fail" | "warn";
      readonly statusLabel: string;
      readonly detail: string;
      readonly btnLabel: string;
    }[] = [
      {
        id: "parser",
        name: "Syntax Parser (Zig)",
        boundary: "Separate OS Port",
        status: state.parserCrashed ? "fail" : "ok",
        statusLabel: state.parserCrashed ? "RESPAWNED (14ms)" : "HEALTHY",
        detail: state.parserCrashed ? "Segfault isolated to OS Port; restarted cleanly" : "50 compiled tree-sitter grammars outside BEAM",
        btnLabel: state.parserCrashed ? "Clear fault" : "Crash Zig parser",
      },
      {
        id: "lsp",
        name: "ElixirLS (LSP)",
        boundary: "Isolated BEAM Port",
        status: state.lspHung ? "warn" : "ok",
        statusLabel: state.lspHung ? "BLOCKED 10s" : "HEALTHY",
        detail: state.lspHung ? "Slow index isolated; editor mailbox never waits" : "Async diagnostics, hover, and completions",
        btnLabel: state.lspHung ? "Unblock LSP" : "Hang LSP 10s",
      },
      {
        id: "mcp",
        name: "GitHub MCP (stdio)",
        boundary: "Supervised Child",
        status: state.mcpCrashed ? "fail" : "ok",
        statusLabel: state.mcpCrashed ? "EXITED" : "HEALTHY",
        detail: state.mcpCrashed ? "Only mcp_github__* dropped; other tools alive" : "Crash-isolated tool process with prefixing",
        btnLabel: state.mcpCrashed ? "Restart MCP" : "Crash MCP",
      },
      {
        id: "hook",
        name: "User :after_save Hook",
        boundary: "Async BEAM Task",
        status: state.hookRaised ? "fail" : "ok",
        statusLabel: state.hookRaised ? "RAISED ERROR" : "HEALTHY",
        detail: state.hookRaised ? "Exception contained; file save completed cleanly" : "Runs off the editor thread in separate Task",
        btnLabel: state.hookRaised ? "Clear error" : "Raise in hook",
      },
      {
        id: "frontend",
        name: "macOS Metal / Go TUI",
        boundary: "Client OS Process",
        status: state.frontendDetached ? "warn" : "ok",
        statusLabel: state.frontendDetached ? "DETACHED" : "CONNECTED",
        detail: state.frontendDetached ? "Core & agents stay running; ready to reattach" : "Streams UI tokens over binary pipes / SSH",
        btnLabel: state.frontendDetached ? "Reattach UI" : "Disconnect UI",
      },
      {
        id: "agent",
        name: "Agent Turn & Drafts",
        boundary: "Supervised Session",
        status: state.agentCrashed ? "fail" : "ok",
        statusLabel: state.agentCrashed ? "DRAFT SAVED" : "HEALTHY",
        detail: state.agentCrashed ? "Unpublished overlay survived in staged_drafts" : "Separate session process + crash-safe draft store",
        btnLabel: state.agentCrashed ? "Recover turn" : "Crash agent turn",
      },
    ];

    const coreHtml = coreNodes
      .map(
        (n) => `
          <div class="af-node is-ok">
            <div class="af-node-top">
              <div>
                <strong>${esc(n.name)}</strong>
                <span class="af-boundary">${esc(n.boundary)}</span>
              </div>
              <span class="topo-pill is-ok">${esc(n.statusLabel)}</span>
            </div>
            <p class="af-detail">${esc(n.detail)}</p>
          </div>`,
      )
      .join("");

    const cardsHtml = faultNodes
      .map(
        (n) => `
          <div class="af-node is-${n.status}">
            <div class="af-node-top">
              <div>
                <strong>${esc(n.name)}</strong>
                <span class="af-boundary">${esc(n.boundary)}</span>
              </div>
              <span class="topo-pill is-${n.status === "ok" ? "ok" : n.status === "warn" ? "warn" : "fail"}">${esc(n.statusLabel)}</span>
            </div>
            <p class="af-detail">${esc(n.detail)}</p>
            <button type="button" class="af-btn" data-af-node="${n.id}">${esc(n.btnLabel)}</button>
          </div>`,
      )
      .join("");

    const logsHtml = state.log.map((entry) => `<div>${esc(entry)}</div>`).join("");

    root.innerHTML = `
      <div class="story-box">
        <div class="story-bar">
          <span>INTERACTIVE FAULT SIMULATOR · CLICK ANY BOUNDARY TO BREAK IT</span>
          <button type="button" class="seg-btn" data-af-reset>Reset all healthy</button>
        </div>
        <div class="af-core-strip">${coreHtml}</div>
        <div class="af-grid">${cardsHtml}</div>
        <div class="af-log" aria-live="polite">${logsHtml}</div>
      </div>
    `;
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    if (target.closest("[data-af-reset]")) {
      state = createArchFaultState();
      render();
      return;
    }

    const nodeBtn = target.closest<HTMLElement>("[data-af-node]");
    if (nodeBtn) {
      const id = nodeBtn.getAttribute("data-af-node") as ArchNodeId | null;
      if (id === "parser" || id === "lsp" || id === "mcp" || id === "hook" || id === "frontend" || id === "agent") {
        state = toggleArchFault(state, id);
        render();
      }
    }
  });

  render();
}

export function mountStagedStepper(root: HTMLElement): void {
  let state = createStagedPipelineState();

  function render(): void {
    const snap = computeStagedSnapshot(state);
    const steps: readonly { readonly n: StagedStep; readonly label: string }[] = [
      { n: 1, label: "1. Revision check" },
      { n: 2, label: "2. Overlay + your edit" },
      { n: 3, label: "3. Draft & review" },
      { n: 4, label: "4. 3-way publish" },
    ];

    const stepBtns = steps
      .map(
        (s) =>
          `<button type="button" class="seg-btn ${state.step === s.n ? "is-active" : ""}" data-st-step="${s.n}">${s.label}</button>`,
      )
      .join("");

    root.innerHTML = `
      <div class="story-box">
        <div class="story-bar">
          <span>INTERACTIVE PIPELINE · SCRUB EACH STAGE</span>
          <div class="st-toggles">
            <label class="st-check">
              <input type="checkbox" data-st-conflict ${state.conflictMode ? "checked" : ""}>
              <span>Simulate overlapping edit conflict</span>
            </label>
            <button type="button" class="seg-btn" data-st-crash>${state.crashedAndRecovered ? "Recovered ✓" : "Simulate editor crash"}</button>
          </div>
        </div>
        <div class="st-step-row" role="group" aria-label="Staged overlay pipeline steps">${stepBtns}</div>
        <div class="st-headline">
          <strong>${esc(snap.headline)}</strong>
          <p>${esc(snap.explanation)}</p>
        </div>
        <div class="st-panes">
          <div class="st-pane">
            <div class="st-pane-head">
              <strong>Working Tree (Disk)</strong>
              <span class="topo-pill ${snap.diskBadge === "clean" ? "is-ok" : "is-warn"}">${esc(snap.diskStatus)}</span>
            </div>
            <pre><code>${esc(snap.diskLines.join("\n"))}</code></pre>
          </div>
          <div class="st-pane">
            <div class="st-pane-head">
              <strong>Open Buffer (Memory)</strong>
              <span class="topo-pill is-ok">${esc(snap.bufferBadge)}</span>
            </div>
            <pre><code>${esc(snap.bufferLines.join("\n"))}</code></pre>
          </div>
          <div class="st-pane is-accent">
            <div class="st-pane-head">
              <strong>Staged Overlay &amp; Draft</strong>
              <span class="topo-pill ${state.conflictMode && state.step === 4 ? "is-fail" : "is-ok"}">${esc(snap.overlayBadge)}</span>
            </div>
            <pre><code>${esc(snap.overlayLines.join("\n"))}</code></pre>
          </div>
        </div>
      </div>
    `;
  }

  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement | null;
    if (!target) return;

    const stepBtn = target.closest<HTMLElement>("[data-st-step]");
    if (stepBtn) {
      const n = Number(stepBtn.getAttribute("data-st-step"));
      if (n === 1 || n === 2 || n === 3 || n === 4) {
        state = { ...state, step: n, crashedAndRecovered: n === 3 ? state.crashedAndRecovered : false };
        render();
      }
      return;
    }

    if (target.closest("[data-st-crash]")) {
      state = { ...state, step: 3, crashedAndRecovered: true };
      render();
    }
  });

  root.addEventListener("change", (event) => {
    const target = event.target as HTMLInputElement | null;
    if (target?.matches("[data-st-conflict]")) {
      state = { ...state, conflictMode: target.checked };
      render();
    }
  });

  render();
}
