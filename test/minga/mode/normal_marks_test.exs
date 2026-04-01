defmodule Minga.Mode.NormalMarksTest do
  @moduledoc """
  Pure function tests for mark-related key dispatch in normal mode.

  Tests the Mode FSM transitions for m (set mark), ' (jump to mark line),
  and ` (jump to mark exact) without booting any GenServers.
  """
  use ExUnit.Case, async: true

  alias Minga.Keymap.Defaults
  alias Minga.Mode
  alias Minga.Mode.Normal
  alias Minga.Mode.State, as: ModeState

  defp fresh_state do
    %{
      Mode.initial_state()
      | leader_trie: Defaults.leader_trie(),
        normal_bindings: Defaults.normal_bindings()
    }
  end

  defp pending_mark_set, do: %{fresh_state() | pending: {:mark, :set}}
  defp pending_mark_jump_line, do: %{fresh_state() | pending: {:mark, :jump_line}}
  defp pending_mark_jump_exact, do: %{fresh_state() | pending: {:mark, :jump_exact}}

  # ── m: set mark ─────────────────────────────────────────────────────────

  describe "m (set mark)" do
    test "m enters pending mark-set state" do
      assert {:continue, %ModeState{pending: {:mark, :set}}} =
               Normal.handle_key({?m, 0}, fresh_state())
    end

    test "m + lowercase letter emits set_mark command" do
      assert {:execute, {:set_mark, "a"}, %ModeState{pending: nil}} =
               Normal.handle_key({?a, 0}, pending_mark_set())
    end

    test "m + z (end of range) emits set_mark" do
      assert {:execute, {:set_mark, "z"}, %ModeState{pending: nil}} =
               Normal.handle_key({?z, 0}, pending_mark_set())
    end

    test "m + escape cancels without effect" do
      assert {:continue, %ModeState{pending: nil}} =
               Normal.handle_key({27, 0}, pending_mark_set())
    end

    test "m + digit cancels pending" do
      assert {:continue, %ModeState{pending: nil}} =
               Normal.handle_key({?1, 0}, pending_mark_set())
    end

    test "m + uppercase letter cancels pending" do
      assert {:continue, %ModeState{pending: nil}} =
               Normal.handle_key({?A, 0}, pending_mark_set())
    end
  end

  # ── ' : jump to mark (line) ────────────────────────────────────────────

  describe "' (jump to mark line)" do
    test "' enters pending jump-line state" do
      assert {:continue, %ModeState{pending: {:mark, :jump_line}}} =
               Normal.handle_key({?', 0}, fresh_state())
    end

    test "' + lowercase letter emits jump_to_mark_line" do
      assert {:execute, {:jump_to_mark_line, "b"}, %ModeState{pending: nil}} =
               Normal.handle_key({?b, 0}, pending_mark_jump_line())
    end

    test "' + ' emits jump_to_last_pos_line" do
      assert {:execute, :jump_to_last_pos_line, %ModeState{pending: nil}} =
               Normal.handle_key({?', 0}, pending_mark_jump_line())
    end

    test "' + escape cancels" do
      assert {:continue, %ModeState{pending: nil}} =
               Normal.handle_key({27, 0}, pending_mark_jump_line())
    end

    test "' + digit cancels" do
      assert {:continue, %ModeState{pending: nil}} =
               Normal.handle_key({?5, 0}, pending_mark_jump_line())
    end
  end

  # ── ` : jump to mark (exact) ───────────────────────────────────────────

  describe "` (jump to mark exact)" do
    test "` enters pending jump-exact state" do
      assert {:continue, %ModeState{pending: {:mark, :jump_exact}}} =
               Normal.handle_key({?`, 0}, fresh_state())
    end

    test "` + lowercase letter emits jump_to_mark_exact" do
      assert {:execute, {:jump_to_mark_exact, "c"}, %ModeState{pending: nil}} =
               Normal.handle_key({?c, 0}, pending_mark_jump_exact())
    end

    test "` + ` emits jump_to_last_pos_exact" do
      assert {:execute, :jump_to_last_pos_exact, %ModeState{pending: nil}} =
               Normal.handle_key({?`, 0}, pending_mark_jump_exact())
    end

    test "` + escape cancels" do
      assert {:continue, %ModeState{pending: nil}} =
               Normal.handle_key({27, 0}, pending_mark_jump_exact())
    end
  end
end
