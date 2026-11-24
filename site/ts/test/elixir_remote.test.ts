import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { CONFIG_PRESETS, generateConfigExs } from "../src/elixir_lab.ts";
import { evaluatePreToolUse } from "../src/remote_lab.ts";

describe("Lesson 04 Elixir Config Playground & Lesson 05 PreToolUse Veto Evaluator", () => {
  it("generates valid Minga.Config snippets for presets including CUA and work safety", () => {
    const cuaText = generateConfigExs(CONFIG_PRESETS.cua!.config);
    assert.match(cuaText, /^use Minga\.Config/);
    assert.match(cuaText, /set :editing_model, :cua/);
    assert.match(cuaText, /set :theme, :catppuccin_latte/);

    const workText = generateConfigExs(CONFIG_PRESETS.work!.config);
    assert.match(workText, /set :agent_hooks/);
    assert.match(workText, /set :agent_mcp_servers/);
    assert.match(workText, /extension :minga_git_extended/);
  });

  it("blocks destructive shell commands with exit 1 and allows safe test commands with exit 0", () => {
    const veto = evaluatePreToolUse("git push --force origin main");
    assert.equal(veto.allowed, false);
    assert.equal(veto.exitCode, 1);
    assert.match(veto.stderr, /Blocked by local safety hook/);

    const safe = evaluatePreToolUse("mix test test/minga_agent/retry_test.exs");
    assert.equal(safe.allowed, true);
    assert.equal(safe.exitCode, 0);
    assert.equal(safe.stderr, "");
  });
});
