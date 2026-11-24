/* Pure state machine for Lesson 03: Live Parallel-Agent & Twist Co-Authoring Simulator. */

export type OrbitState = "working" | "needs_you" | "waiting" | "stopped" | "failed" | "done";

export interface SubagentWorker {
  readonly id: string;
  readonly name: string;
  readonly state: OrbitState;
  readonly summary: string;
  readonly brief: string;
  readonly steps: readonly string[];
  readonly approvalRequest?: {
    readonly title: string;
    readonly detail: string;
    readonly answeredText?: string;
  };
}

export type CoAuthorMissionId = "per_author_undo" | "lockout_guard" | "subagent_peek" | "review_change";

export interface CoAuthorState {
  readonly workers: readonly SubagentWorker[];
  readonly activeDrawer: "none" | "tasks" | "peek";
  readonly peekIndex: number;
  readonly briefFolded: boolean;
  readonly parentDraft: string;
  readonly cursorChange: 1 | 2;
  readonly change1: "unreviewed" | "kept" | "rejected";
  readonly change2: "unreviewed" | "kept" | "rejected";
  readonly userEditPresent: boolean;
  readonly actMenuOpen: boolean;
  readonly lockoutUntilMs: number;
  readonly lastEvent: string;
  readonly completed: ReadonlySet<CoAuthorMissionId>;
}

export const COAUTHOR_MISSIONS: readonly {
  readonly id: CoAuthorMissionId;
  readonly label: string;
  readonly hint: string;
}[] = [
  { id: "per_author_undo", label: "Undo only your own edit", hint: "Press u Undo yours (Minga's lines stay)" },
  { id: "lockout_guard", label: "Test the 300 ms guard", hint: "Trigger auto-open approval, then tap y immediately" },
  { id: "subagent_peek", label: "Peek & step siblings", hint: "Open SPC a i Subagent Peek, then ]]" },
  { id: "review_change", label: "Keep or reject a change", hint: "Use SPC a y, SPC a d, or g. Act Menu" },
];

export const LOCKOUT_MS = 300;

const INITIAL_WORKERS: readonly SubagentWorker[] = [
  {
    id: "edge",
    name: "Edge-Case Tester",
    state: "done",
    summary: "Reported 1 missing 529 clause",
    brief: "Check retry status classification against 429, 500-599, and 529 overloaded responses.",
    steps: [
      "Read lib/minga_agent/retry.ex",
      "Added test cases for HTTP 529 overloaded responses",
      "Handed 1 finding back to parent conversation",
    ],
  },
  {
    id: "fact",
    name: "Fact-Check Auditor",
    state: "working",
    summary: "Cross-checking backoff cap in retry.ex",
    brief: "Verify Retry-After HTTP-date parsing and exponential backoff cap against RFC 9110.",
    steps: [
      "Checked HTTP 429 Retry-After parsing against RFC 9110",
      "Cross-checking 30_000 ms cap in lib/minga_agent/retry.ex",
    ],
  },
  {
    id: "usage",
    name: "Usage-Limit Tests",
    state: "needs_you",
    summary: "Create test/minga_agent/usage_limit_test.exs +86",
    brief: "Write isolated unit tests for token usage limit recovery without touching production files.",
    steps: [
      "Drafted 86 lines in test/minga_agent/usage_limit_test.exs",
      "Waiting on approval to write new test file",
    ],
    approvalRequest: {
      title: "Add usage limit tests",
      detail: "Create test/minga_agent/usage_limit_test.exs +86",
    },
  },
];

export function createCoAuthorState(initialCompleted: Iterable<CoAuthorMissionId> = []): CoAuthorState {
  return {
    workers: INITIAL_WORKERS,
    activeDrawer: "none",
    peekIndex: 1,
    briefFolded: true,
    parentDraft: "Also verify Retry-After HTTP-date headers before merge...",
    cursorChange: 1,
    change1: "unreviewed",
    change2: "unreviewed",
    userEditPresent: true,
    actMenuOpen: false,
    lockoutUntilMs: 0,
    lastEvent: "Cursor is in retry.ex (change 1/2). Line 240 has a shared blue+mauve strand from your edit.",
    completed: new Set(initialCompleted),
  };
}

function addMission(state: CoAuthorState, mission: CoAuthorMissionId): ReadonlySet<CoAuthorMissionId> {
  if (state.completed.has(mission)) return state.completed;
  const next = new Set(state.completed);
  next.add(mission);
  return next;
}

export function countNeedsYou(state: CoAuthorState): number {
  return state.workers.filter((w) => w.state === "needs_you").length;
}

export function undoUserEdit(state: CoAuthorState): CoAuthorState {
  if (state.userEditPresent && state.change1 !== "rejected") {
    return {
      ...state,
      actMenuOpen: false,
      userEditPresent: false,
      completed: addMission(state, "per_author_undo"),
      lastEvent: "u undid only your edit on line 240 (backoff_ms(2) -> backoff_ms(1)). Minga's braided Twist stayed intact.",
    };
  }
  return {
    ...state,
    actMenuOpen: false,
    lastEvent: "Nothing of yours left to undo. Minga's changes never vanish on u; use SPC a y to keep or SPC a d to reject.",
  };
}

export function editInsideTwist(state: CoAuthorState): CoAuthorState {
  if (state.change1 === "rejected") {
    return { ...state, lastEvent: "Reset the buffer to edit inside change 1 again." };
  }
  return {
    ...state,
    userEditPresent: true,
    lastEvent: "Edited line 240 inside Minga's change: one gutter strand turned blue for shared authorship.",
  };
}

export function jumpNextChange(state: CoAuthorState): CoAuthorState {
  const nextCursor: 1 | 2 = state.cursorChange === 1 ? 2 : 1;
  return {
    ...state,
    cursorChange: nextCursor,
    actMenuOpen: false,
    lastEvent: nextCursor === 1 ? "]h jumped to change 1 (lines 238 to 241)." : "]h jumped to change 2 (line 245, backoff_ms/1).",
  };
}

export function reviewCurrentChange(state: CoAuthorState, decision: "kept" | "rejected"): CoAuthorState {
  const key = state.cursorChange === 1 ? "change1" : "change2";
  if (state[key] !== "unreviewed") {
    return {
      ...state,
      actMenuOpen: false,
      lastEvent: `Change ${state.cursorChange} is already ${state[key]}. Press ]h or Reset.`,
    };
  }
  const nextCursor: 1 | 2 =
    state.cursorChange === 1 && state.change2 === "unreviewed"
      ? 2
      : state.cursorChange === 2 && state.change1 === "unreviewed"
        ? 1
        : state.cursorChange;

  return {
    ...state,
    [key]: decision,
    cursorChange: nextCursor,
    actMenuOpen: false,
    completed: addMission(state, "review_change"),
    lastEvent:
      decision === "kept"
        ? `SPC a y kept change ${state.cursorChange}. Its Twist faded to a quiet muted strand until commit.`
        : `SPC a d rejected change ${state.cursorChange}. Minga's lines left cleanly without touching your undo stack.`,
  };
}

export function toggleCoAuthorActMenu(state: CoAuthorState): CoAuthorState {
  const cur = state.cursorChange === 1 ? state.change1 : state.change2;
  if (cur !== "unreviewed") {
    return { ...state, actMenuOpen: false, lastEvent: `Change ${state.cursorChange} is already ${cur}.` };
  }
  const open = !state.actMenuOpen;
  return {
    ...state,
    actMenuOpen: open,
    lastEvent: open
      ? "g. opened the Direction A Act Menu leading with Keep / Reject and exact line consequences."
      : "Closed Act Menu.",
  };
}

export function autoOpenTasksWithLockout(state: CoAuthorState, nowMs: number): CoAuthorState {
  const workers = state.workers.map((w) =>
    w.id === "usage"
      ? {
          ...w,
          state: "needs_you" as const,
          approvalRequest: {
            title: "Add usage limit tests",
            detail: "Create test/minga_agent/usage_limit_test.exs +86",
          },
        }
      : w
  );
  return {
    ...state,
    workers,
    activeDrawer: "tasks",
    actMenuOpen: false,
    lockoutUntilMs: nowMs + LOCKOUT_MS,
    lastEvent: "Tasks drawer auto-opened from a background request: 300 ms anti-misfire lockout armed! Try pressing y right now.",
  };
}

export function openTasksDrawer(state: CoAuthorState): CoAuthorState {
  return {
    ...state,
    activeDrawer: state.activeDrawer === "tasks" ? "none" : "tasks",
    actMenuOpen: false,
    lockoutUntilMs: 0,
    lastEvent: state.activeDrawer === "tasks" ? "q closed *minga-tasks*." : "SPC a a opened *minga-tasks* (needs-you sorted first).",
  };
}

export function answerApproval(
  state: CoAuthorState,
  choice: "y" | "a" | "t" | "n",
  nowMs: number
): CoAuthorState {
  if (nowMs < state.lockoutUntilMs) {
    const remaining = Math.max(1, Math.round(state.lockoutUntilMs - nowMs));
    return {
      ...state,
      completed: addMission(state, "lockout_guard"),
      lastEvent: `300 ms anti-misfire guard absorbed "${choice}" (${remaining} ms left). A stray keystroke in flight cannot approve a destructive request.`,
    };
  }

  const labelMap: Record<"y" | "a" | "t" | "n", string> = {
    y: "Approved once",
    a: "Approved for this session",
    t: "Approved for this turn",
    n: "Denied",
  };
  const nextOrbit: OrbitState = choice === "n" ? "stopped" : "done";

  const workers = state.workers.map((w) =>
    w.id === "usage" && w.approvalRequest
      ? {
          ...w,
          state: nextOrbit,
          summary: `${labelMap[choice]} · Already answered in Minga`,
          approvalRequest: {
            ...w.approvalRequest,
            answeredText: `${labelMap[choice]} · synced as "Already answered" everywhere else`,
          },
        }
      : w
  );

  return {
    ...state,
    workers,
    lockoutUntilMs: 0,
    lastEvent: `${choice}: ${labelMap[choice]}. Modeline needs_you cleared and synced "Already answered" to notifications.`,
  };
}

export function openSubagentPeek(state: CoAuthorState): CoAuthorState {
  return {
    ...state,
    activeDrawer: "peek",
    actMenuOpen: false,
    lastEvent: "SPC a i opened Subagent Peek in a right split. Your unsent parent draft stayed untouched.",
  };
}

export function stepPeekSibling(state: CoAuthorState, delta: 1 | -1): CoAuthorState {
  const nextIndex = (state.peekIndex + delta + state.workers.length) % state.workers.length;
  const worker = state.workers[nextIndex];
  return {
    ...state,
    activeDrawer: "peek",
    peekIndex: nextIndex,
    completed: addMission(state, "subagent_peek"),
    lastEvent: `${delta > 0 ? "]]" : "[["} stepped to sibling ${nextIndex + 1} of ${state.workers.length}: ${worker?.name ?? "worker"}.`,
  };
}

export function toggleBriefFold(state: CoAuthorState): CoAuthorState {
  return {
    ...state,
    briefFolded: !state.briefFolded,
    lastEvent: state.briefFolded ? "za unfolded the subagent Brief." : "za folded the subagent Brief.",
  };
}

export function closeCoAuthorDrawer(state: CoAuthorState): CoAuthorState {
  return {
    ...state,
    activeDrawer: "none",
    actMenuOpen: false,
    lastEvent: "q closed the drawer and returned focus to retry.ex.",
  };
}
