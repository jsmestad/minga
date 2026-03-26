defmodule Minga.Keymap.Scope.CUAScopeTest do
  @moduledoc """
  Trie-level unit tests for CUA keymap scope resolution.

  Verifies that every CUA scope trie contains the correct bindings,
  including Ctrl fallbacks for TUI (where Cmd is unreachable).
  These tests are fast (microseconds, no GenServer needed) and catch
  wiring bugs in the trie definitions.
  """
  use ExUnit.Case, async: true

  alias Minga.Keymap.Scope

  # Arrow keys (Kitty protocol)
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  @enter 13
  @escape 27
  @ctrl 0x02
  @cmd 0x08

  # ── File tree scope ────────────────────────────────────────────────────────

  describe "file_tree scope with :cua" do
    test "arrow up/down resolve to movement commands" do
      assert {:command, :move_up} = Scope.resolve_key(:file_tree, :cua, {@arrow_up, 0})
      assert {:command, :move_down} = Scope.resolve_key(:file_tree, :cua, {@arrow_down, 0})
    end

    test "arrow right expands directory" do
      assert {:command, :tree_expand} = Scope.resolve_key(:file_tree, :cua, {@arrow_right, 0})
    end

    test "arrow left collapses directory" do
      assert {:command, :tree_collapse} = Scope.resolve_key(:file_tree, :cua, {@arrow_left, 0})
    end

    test "Enter opens file" do
      assert {:command, :tree_open_or_toggle} = Scope.resolve_key(:file_tree, :cua, {@enter, 0})
    end

    test "Escape closes tree" do
      assert {:command, :tree_close} = Scope.resolve_key(:file_tree, :cua, {@escape, 0})
    end

    test "vim j/k are not bound in CUA mode" do
      assert :not_found = Scope.resolve_key(:file_tree, :cua, {?j, 0})
      assert :not_found = Scope.resolve_key(:file_tree, :cua, {?k, 0})
    end
  end

  # ── Agent scope ────────────────────────────────────────────────────────────

  describe "agent scope with :cua" do
    test "Enter resolves to focus-or-submit (not just focus)" do
      # Bug 2 regression: Enter must submit when input is focused,
      # not just focus the input every time
      assert {:command, :agent_focus_or_submit} = Scope.resolve_key(:agent, :cua, {@enter, 0})
    end

    test "arrow up/down resolve to agent-specific navigation" do
      assert {:command, :agent_input_up} = Scope.resolve_key(:agent, :cua, {@arrow_up, 0})
      assert {:command, :agent_input_down} = Scope.resolve_key(:agent, :cua, {@arrow_down, 0})
    end

    test "Cmd+C copies code block (GUI)" do
      assert {:command, :agent_copy_code_block} = Scope.resolve_key(:agent, :cua, {?c, @cmd})
    end

    test "Ctrl+C copies code block (TUI fallback)" do
      # Bug 4 regression: Ctrl fallback must exist for TUI
      assert {:command, :agent_copy_code_block} = Scope.resolve_key(:agent, :cua, {?c, @ctrl})
    end

    test "Ctrl+A selects all (TUI fallback)" do
      assert {:command, :select_all} = Scope.resolve_key(:agent, :cua, {?a, @ctrl})
    end

    test "Escape dismisses" do
      assert {:command, :agent_dismiss_or_noop} = Scope.resolve_key(:agent, :cua, {@escape, 0})
    end
  end

  # ── Git status scope ───────────────────────────────────────────────────────

  describe "git_status scope with :cua" do
    test "arrow up/down navigate entries" do
      assert {:command, :move_up} = Scope.resolve_key(:git_status, :cua, {@arrow_up, 0})
      assert {:command, :move_down} = Scope.resolve_key(:git_status, :cua, {@arrow_down, 0})
    end

    test "Enter opens file" do
      assert {:command, :git_status_open_file} = Scope.resolve_key(:git_status, :cua, {@enter, 0})
    end

    test "Escape closes panel" do
      assert {:command, :git_status_close} = Scope.resolve_key(:git_status, :cua, {@escape, 0})
    end

    test "s stages file (domain key shared with vim)" do
      assert {:command, :git_status_stage} = Scope.resolve_key(:git_status, :cua, {?s, 0})
    end

    test "Cmd+C starts commit (GUI)" do
      assert {:command, :git_status_start_commit} =
               Scope.resolve_key(:git_status, :cua, {?c, @cmd})
    end

    test "Ctrl+C starts commit (TUI fallback)" do
      # Bug 4 regression: Ctrl fallback for git commit
      assert {:command, :git_status_start_commit} =
               Scope.resolve_key(:git_status, :cua, {?c, @ctrl})
    end
  end

  # ── Editor scope ───────────────────────────────────────────────────────────

  describe "editor scope with :cua" do
    test "Ctrl+Z triggers undo (TUI fallback)" do
      # Bug 9 regression: undo must be reachable on TUI
      assert {:command, :undo} = Scope.resolve_key(:editor, :cua, {?z, @ctrl})
    end

    test "Ctrl+Y triggers redo (TUI fallback)" do
      assert {:command, :redo} = Scope.resolve_key(:editor, :cua, {?y, @ctrl})
    end

    test "Ctrl+V triggers paste (TUI fallback)" do
      # Bug 10 regression: paste must be reachable on TUI
      assert {:command, :paste_after} = Scope.resolve_key(:editor, :cua, {?v, @ctrl})
    end

    test "Ctrl+A triggers select all (TUI fallback)" do
      assert {:command, :select_all} = Scope.resolve_key(:editor, :cua, {?a, @ctrl})
    end

    test "Ctrl+P opens command palette (TUI)" do
      # Bug 8 regression: command palette accessible on TUI
      assert {:command, :command_palette} = Scope.resolve_key(:editor, :cua, {?p, @ctrl})
    end

    test "Cmd+Z triggers undo (GUI)" do
      assert {:command, :undo} = Scope.resolve_key(:editor, :cua, {?z, @cmd})
    end

    test "Cmd+C triggers copy (GUI)" do
      assert {:command, :yank_visual_selection} = Scope.resolve_key(:editor, :cua, {?c, @cmd})
    end

    test "printable chars are not bound (handled by CUA.Dispatch)" do
      assert :not_found = Scope.resolve_key(:editor, :cua, {?a, 0})
      assert :not_found = Scope.resolve_key(:editor, :cua, {?x, 0})
    end
  end

  # ── Trie isolation ─────────────────────────────────────────────────────────

  describe "CUA bindings do not leak into vim mode" do
    test "arrow down is not bound in agent :normal trie" do
      # Arrow down in agent :cua navigates. In :normal, j does that.
      # Arrow should not be in the :normal trie.
      assert :not_found = Scope.resolve_key(:agent, :normal, {@arrow_down, 0})
    end

    test "editor :normal has no CUA Ctrl bindings" do
      assert :not_found = Scope.resolve_key(:editor, :normal, {?z, @ctrl})
      assert :not_found = Scope.resolve_key(:editor, :normal, {?p, @ctrl})
    end
  end
end
