import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  LOCKOUT_MS,
  answerApproval,
  autoOpenTasksWithLockout,
  countNeedsYou,
  createCoAuthorState,
  reviewCurrentChange,
  stepPeekSibling,
  undoUserEdit,
} from "../src/coauthor_state.ts";

describe("Lesson 03 Co-Authoring & Parallel Agents state machine", () => {
  it("undoes only the human edit on u without dropping Minga's unreviewed changes", () => {
    const s0 = createCoAuthorState();
    assert.equal(s0.userEditPresent, true);
    assert.equal(s0.change1, "unreviewed");
    assert.equal(s0.change2, "unreviewed");

    const s1 = undoUserEdit(s0);
    assert.equal(s1.userEditPresent, false);
    assert.equal(s1.change1, "unreviewed");
    assert.equal(s1.change2, "unreviewed");
    assert.ok(s1.completed.has("per_author_undo"));
  });

  it("enforces the 300 ms anti-misfire lockout on auto-opened approvals, then approves after unlock", () => {
    const base = createCoAuthorState();
    const t0 = 10_000;
    const opened = autoOpenTasksWithLockout(base, t0);
    assert.equal(opened.activeDrawer, "tasks");
    assert.equal(countNeedsYou(opened), 1);

    const blocked = answerApproval(opened, "y", t0 + 120);
    assert.equal(countNeedsYou(blocked), 1);
    assert.ok(blocked.completed.has("lockout_guard"));
    assert.match(blocked.lastEvent, /300 ms anti-misfire guard absorbed/);

    const approved = answerApproval(blocked, "y", t0 + LOCKOUT_MS + 10);
    assert.equal(countNeedsYou(approved), 0);
    assert.match(approved.lastEvent, /Already answered/);
  });

  it("steps siblings in Subagent Peek while preserving parent draft and advances review changes", () => {
    let s = createCoAuthorState();
    const originalDraft = s.parentDraft;

    s = stepPeekSibling(s, 1);
    assert.equal(s.activeDrawer, "peek");
    assert.equal(s.parentDraft, originalDraft);
    assert.ok(s.completed.has("subagent_peek"));

    s = reviewCurrentChange(s, "kept");
    assert.equal(s.change1, "kept");
    assert.equal(s.cursorChange, 2);
    assert.ok(s.completed.has("review_change"));
  });
});
