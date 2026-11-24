import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  createSandboxState,
  handleSandboxKey,
  setSandboxClient,
} from "../src/sandbox_state.ts";

describe("Lesson 02 Playable Mini-Minga Sandbox state machine", () => {
  it("opens which-key on Space, switches to Switcher on comma, pins with Ctrl+T, and closes with q", () => {
    let s = createSandboxState();
    assert.equal(s.overlay.kind, "none");

    s = handleSandboxKey(s, { key: " " });
    assert.deepEqual(s.overlay, { kind: "which_key", prefix: "SPC" });
    assert.ok(s.completed.has("which_key"));

    s = handleSandboxKey(s, { key: "," });
    assert.deepEqual(s.overlay, { kind: "switcher", selectedIndex: 0 });

    s = handleSandboxKey(s, { key: "t", ctrl: true });
    assert.equal(s.files[0]?.pinned, true);
    assert.ok(s.completed.has("pin_file"));

    s = handleSandboxKey(s, { key: "q" });
    assert.equal(s.overlay.kind, "none");
    assert.ok(s.completed.has("dismiss"));
  });

  it("opens Direction A Act Menu on g. and keeps/rejects cleanly", () => {
    let s = createSandboxState();
    s = handleSandboxKey(s, { key: "g" });
    assert.equal(s.pendingPrefix, "g");

    s = handleSandboxKey(s, { key: "." });
    assert.deepEqual(s.overlay, { kind: "act_menu", selected: "keep" });
    assert.ok(s.completed.has("act_menu"));

    s = handleSandboxKey(s, { key: "y" });
    assert.equal(s.overlay.kind, "none");
    assert.equal(s.changeStatus, "kept");
  });

  it("records parity mission when switching to Go Terminal UI", () => {
    const s = setSandboxClient(createSandboxState(), "tui");
    assert.equal(s.client, "tui");
    assert.ok(s.completed.has("parity"));
  });
});
