/* Pure state machine for Lesson 02: Playable Mini-Minga Sandbox (v0.1.0 Spine design). */

export type ClientSurface = "macos" | "tui";
export type InputProfile = "vim" | "cua" | "mouse";

export interface SwitcherEntry {
  readonly id: string;
  readonly name: string;
  readonly dir: string;
  readonly section: "Pinned" | "Changed" | "Recent" | "Terminals";
  readonly pinned: boolean;
  readonly statusNote: string;
}

export type SandboxOverlay =
  | { readonly kind: "none" }
  | { readonly kind: "which_key"; readonly prefix: "SPC" | "SPC a" }
  | { readonly kind: "switcher"; readonly selectedIndex: number }
  | { readonly kind: "act_menu"; readonly selected: "keep" | "reject" }
  | { readonly kind: "hover"; readonly focused: boolean };

export type SandboxMissionId = "which_key" | "pin_file" | "act_menu" | "parity" | "dismiss";

export interface SandboxState {
  readonly client: ClientSurface;
  readonly profile: InputProfile;
  readonly activeFileId: string;
  readonly files: readonly SwitcherEntry[];
  readonly pendingPrefix: "" | "g";
  readonly overlay: SandboxOverlay;
  readonly changeStatus: "unreviewed" | "kept" | "rejected";
  readonly lastAction: string;
  readonly echoNotice: string;
  readonly completed: ReadonlySet<SandboxMissionId>;
}

export interface KeyInput {
  readonly key: string;
  readonly ctrl?: boolean;
  readonly meta?: boolean;
  readonly alt?: boolean;
}

export const SANDBOX_MISSIONS: readonly {
  readonly id: SandboxMissionId;
  readonly label: string;
  readonly hint: string;
}[] = [
  { id: "which_key", label: "Open which-key", hint: "Press Space (or click NORMAL pill)" },
  { id: "pin_file", label: "Open switcher & pin a file", hint: "SPC , then Ctrl+T (or Pin)" },
  { id: "act_menu", label: "Open the Act Menu", hint: "Press g. or right-click code" },
  { id: "parity", label: "Verify Terminal parity", hint: "Switch to Go Terminal UI" },
  { id: "dismiss", label: "Dismiss a drawer or menu", hint: "Press q or Esc" },
];

const INITIAL_FILES: readonly SwitcherEntry[] = [
  { id: "retry", name: "retry.ex", dir: "lib/minga_agent", section: "Changed", pinned: false, statusNote: "Minga · change 1/2" },
  { id: "router", name: "router.ex", dir: "lib/minga_agent", section: "Pinned", pinned: true, statusNote: "SPC 1 · pinned" },
  { id: "config", name: "config.exs", dir: "~/.config/minga", section: "Recent", pinned: false, statusNote: "2m ago" },
  { id: "term", name: "*terminal 1*", dir: "~/code/minga", section: "Terminals", pinned: false, statusNote: "mix test · Done" },
];

export function createSandboxState(initialCompleted: Iterable<SandboxMissionId> = []): SandboxState {
  return {
    client: "macos",
    profile: "vim",
    activeFileId: "retry",
    files: INITIAL_FILES,
    pendingPrefix: "",
    overlay: { kind: "none" },
    changeStatus: "unreviewed",
    lastAction: "Resting screen: plain title bar, code, one modeline.",
    echoNotice: "Click inside the viewport and press Space, SPC ,, g., K, or right-click a line.",
    completed: new Set(initialCompleted),
  };
}

function withMission(state: SandboxState, mission: SandboxMissionId): ReadonlySet<SandboxMissionId> {
  if (state.completed.has(mission)) return state.completed;
  const next = new Set(state.completed);
  next.add(mission);
  return next;
}

export function setSandboxClient(state: SandboxState, client: ClientSurface): SandboxState {
  if (state.client === client) return state;
  return {
    ...state,
    client,
    completed: client === "tui" ? withMission(state, "parity") : state.completed,
    lastAction: client === "tui"
      ? "Switched to Go Terminal UI (Lip Gloss): same layout, marks, and keys."
      : "Switched to macOS Native (Swift + Metal): CoreText and vector marks.",
    echoNotice: client === "tui"
      ? "TUI parity check: identical modeline order, drawers, and key grammar."
      : "macOS native client: holding ⌘ reveals shortcuts; every modeline segment is clickable.",
  };
}

export function setSandboxProfile(state: SandboxState, profile: InputProfile): SandboxState {
  return {
    ...state,
    profile,
    pendingPrefix: "",
    lastAction:
      profile === "cua"
        ? "CUA key profile (ADR-0007): standard desktop shortcuts honored alongside SPC leader."
        : profile === "mouse"
          ? "Mouse path mode: click NORMAL pill, any modeline segment, or right-click code."
          : "Vim modal default: mnemonic SPC leader, Vim inside files, bare keys in special buffers.",
  };
}

export function openWhichKey(state: SandboxState, prefix: "SPC" | "SPC a" = "SPC"): SandboxState {
  return {
    ...state,
    pendingPrefix: "",
    overlay: { kind: "which_key", prefix },
    completed: withMission(state, "which_key"),
    lastAction: prefix === "SPC" ? "SPC opened which-key above the modeline." : "SPC a opened the Minga group.",
    echoNotice: prefix === "SPC" ? "Press , for Switcher, a for Minga ›, or Esc to close." : "Press r Review, a Tasks, y Keep, or Esc to close.",
  };
}

export function openSwitcher(state: SandboxState): SandboxState {
  return {
    ...state,
    pendingPrefix: "",
    overlay: { kind: "switcher", selectedIndex: 0 },
    lastAction: "SPC , opened the File Switcher bottom drawer.",
    echoNotice: "Use Ctrl+J / Ctrl+K to move, Ctrl+T to pin, Enter to open, q or Esc to close.",
  };
}

export function togglePinSelected(state: SandboxState, indexOverride?: number): SandboxState {
  const idx = indexOverride ?? (state.overlay.kind === "switcher" ? state.overlay.selectedIndex : 0);
  const target = state.files[idx];
  if (!target) return state;

  const files = state.files.map((f, i) => {
    if (i !== idx) return f;
    const pinned = !f.pinned;
    return {
      ...f,
      pinned,
      section: pinned ? ("Pinned" as const) : f.id === "retry" ? ("Changed" as const) : f.id === "term" ? ("Terminals" as const) : ("Recent" as const),
      statusNote: pinned ? "Pinned · SPC 1-4" : f.id === "retry" ? "Minga · change 1/2" : "Recent",
    };
  });

  return {
    ...state,
    files,
    completed: withMission(state, "pin_file"),
    lastAction: target.pinned ? `Unpinned ${target.name}.` : `Pinned ${target.name} to SPC 1-4 (⌘1-⌘4 on macOS).`,
    echoNotice: `No tabs needed: ${target.name} is one chord away in the switcher.`,
  };
}

export function openActMenu(state: SandboxState, via: "key" | "mouse" = "key"): SandboxState {
  return {
    ...state,
    pendingPrefix: "",
    overlay: { kind: "act_menu", selected: "keep" },
    completed: withMission(state, "act_menu"),
    lastAction: via === "mouse"
      ? "Right-click opened the Direction A Act Menu (same menu as g. and Ctrl+.)."
      : "g. opened the Direction A Act Menu leading with Keep / Reject.",
    echoNotice: "Press y to Keep, n to Reject, Enter for preselected Keep, or Esc to close.",
  };
}

export function openHover(state: SandboxState): SandboxState {
  if (state.overlay.kind === "hover" && !state.overlay.focused) {
    return {
      ...state,
      overlay: { kind: "hover", focused: true },
      lastAction: "Second K moved focus into the Hover popover (Neovim K K model).",
      echoNotice: "Scroll with j/k, copy with y, or press q / Esc to return to code.",
    };
  }
  return {
    ...state,
    pendingPrefix: "",
    overlay: { kind: "hover", focused: false },
    lastAction: "K opened level-1 Hover peek (ordered: diagnostic, signature, docs, attribution).",
    echoNotice: "Press K again to focus the popover, g. for actions, or Esc to dismiss.",
  };
}

export function resolveActDecision(state: SandboxState, decision: "keep" | "reject"): SandboxState {
  return {
    ...state,
    overlay: { kind: "none" },
    changeStatus: decision === "keep" ? "kept" : "rejected",
    completed: withMission(state, "act_menu"),
    lastAction: decision === "keep"
      ? "Act Menu: y kept Minga's 4-line change (Twist fades to muted strand)."
      : "Act Menu: n rejected Minga's 4-line change (restored original 1 line).",
    echoNotice: "Direct keys without the menu: SPC a y keeps, SPC a d rejects.",
  };
}

export function dismissOverlay(state: SandboxState, keyUsed: "q" | "esc"): SandboxState {
  if (state.overlay.kind === "none") {
    return {
      ...state,
      pendingPrefix: "",
      echoNotice: keyUsed === "q"
        ? "In a code file, q stays Vim macro record. Open a drawer or menu first to dismiss it."
        : "Already on the resting screen.",
    };
  }
  const prev = state.overlay.kind;
  return {
    ...state,
    pendingPrefix: "",
    overlay: { kind: "none" },
    completed: withMission(state, "dismiss"),
    lastAction: `${keyUsed} closed ${prev.replace("_", " ")} and returned focus to ${state.files.find((f) => f.id === state.activeFileId)?.name ?? "code"}.`,
    echoNotice: "One rule everywhere: q closes special buffers and splits; Esc cancels transients.",
  };
}

export function handleSandboxKey(state: SandboxState, input: KeyInput): SandboxState {
  const key = input.key;
  const ctrl = Boolean(input.ctrl);
  const meta = Boolean(input.meta);

  if (key === "Escape") {
    return dismissOverlay(state, "esc");
  }

  if ((ctrl || meta) && key === ".") {
    return openActMenu(state, "key");
  }

  /* Overlay-specific keys first */
  if (state.overlay.kind === "which_key") {
    if (state.overlay.prefix === "SPC") {
      if (key === ",") return openSwitcher(state);
      if (key === "a") return openWhichKey(state, "SPC a");
      if (key === "q") return dismissOverlay(state, "q");
    } else {
      if (key === "y") return resolveActDecision(state, "keep");
      if (key === "d") return resolveActDecision(state, "reject");
      if (key === "q") return dismissOverlay(state, "q");
    }
    return state;
  }

  if (state.overlay.kind === "switcher") {
    const count = state.files.length;
    if (key === "q" && !ctrl) return dismissOverlay(state, "q");
    if (key === "ArrowDown" || key === "j" || (ctrl && key.toLowerCase() === "j")) {
      return {
        ...state,
        overlay: { kind: "switcher", selectedIndex: (state.overlay.selectedIndex + 1) % count },
      };
    }
    if (key === "ArrowUp" || key === "k" || (ctrl && key.toLowerCase() === "k")) {
      return {
        ...state,
        overlay: { kind: "switcher", selectedIndex: (state.overlay.selectedIndex - 1 + count) % count },
      };
    }
    if (ctrl && key.toLowerCase() === "t") {
      return togglePinSelected(state);
    }
    if (key === "Enter") {
      const chosen = state.files[state.overlay.selectedIndex];
      if (!chosen) return state;
      return {
        ...state,
        activeFileId: chosen.id,
        overlay: { kind: "none" },
        lastAction: `Opened ${chosen.name} (${chosen.dir}) from the Switcher.`,
        echoNotice: "Jump back anytime with Ctrl+O (⌘[ on macOS).",
      };
    }
    return state;
  }

  if (state.overlay.kind === "act_menu") {
    if (key === "y" || key === "Enter") return resolveActDecision(state, state.overlay.selected === "reject" && key === "Enter" ? "reject" : "keep");
    if (key === "n") return resolveActDecision(state, "reject");
    if (key === "ArrowRight" || key === "l") return { ...state, overlay: { kind: "act_menu", selected: "reject" } };
    if (key === "ArrowLeft" || key === "h") return { ...state, overlay: { kind: "act_menu", selected: "keep" } };
    if (key === "q") return dismissOverlay(state, "q");
    return state;
  }

  if (state.overlay.kind === "hover") {
    if (key === "K") return openHover(state);
    if (key === "q") return dismissOverlay(state, "q");
    if (key === "g") return { ...state, pendingPrefix: "g" };
    return state;
  }

  /* Resting screen keys */
  if (state.pendingPrefix === "g") {
    if (key === ".") return openActMenu(state, "key");
    return { ...state, pendingPrefix: "" };
  }

  if (key === " ") {
    return openWhichKey(state, "SPC");
  }
  if (key === "g") {
    return { ...state, pendingPrefix: "g", echoNotice: "Prefix g... press . to open the Act Menu." };
  }
  if (key === "K") {
    return openHover(state);
  }
  if (key === "q") {
    return dismissOverlay(state, "q");
  }

  return state;
}
