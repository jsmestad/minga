defmodule Minga.Mode.CommandTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Mode.Command
  alias Minga.Mode.CommandState

  @enter 13
  @escape 27

  # Build a fresh command-mode state (as injected by the editor).
  defp fresh_state(input \\ ""), do: %CommandState{input: input}

  # ── Typing characters ────────────────────────────────────────────────────────

  describe "typing printable characters" do
    test "typing a letter appends it to input" do
      assert {:continue, %{input: "w"}} = Command.handle_key({?w, 0}, fresh_state())
    end

    test "successive characters accumulate in input" do
      {:continue, s1} = Command.handle_key({?w, 0}, fresh_state())
      {:continue, s2} = Command.handle_key({?q, 0}, s1)
      assert s2.input == "wq"
    end

    test "typing a space appends it to input" do
      assert {:continue, %{input: "e "}} = Command.handle_key({?\s, 0}, fresh_state("e"))
    end

    test "typing a digit appends it to input" do
      assert {:continue, %{input: "4"}} = Command.handle_key({?4, 0}, fresh_state())
    end
  end

  # ── Backspace ────────────────────────────────────────────────────────────────

  describe "Backspace (DEL 127)" do
    test "removes last character from a non-empty input" do
      assert {:continue, %{input: "w"}} = Command.handle_key({127, 0}, fresh_state("wq"))
    end

    test "transitions to normal when input becomes empty" do
      assert {:transition, :normal, _} = Command.handle_key({127, 0}, fresh_state("w"))
    end

    test "transitions to normal on backspace with already-empty input" do
      assert {:transition, :normal, _} = Command.handle_key({127, 0}, fresh_state(""))
    end
  end

  describe "Backspace (BS 8)" do
    test "removes last character from a non-empty input" do
      assert {:continue, %{input: "w"}} = Command.handle_key({8, 0}, fresh_state("wq"))
    end

    test "transitions to normal when input becomes empty" do
      assert {:transition, :normal, _} = Command.handle_key({8, 0}, fresh_state("w"))
    end
  end

  # ── Escape ───────────────────────────────────────────────────────────────────

  describe "Escape" do
    test "transitions to normal mode without executing" do
      assert {:transition, :normal, _state} = Command.handle_key({@escape, 0}, fresh_state("wq"))
    end

    test "clears the input in the returned state" do
      {:transition, :normal, state} = Command.handle_key({@escape, 0}, fresh_state("wq"))
      assert state.input == ""
    end
  end

  # ── Enter ────────────────────────────────────────────────────────────────────

  describe "Enter" do
    test ":w → execute {:save, []} then transition to normal" do
      result = Command.handle_key({@enter, 0}, fresh_state("w"))
      assert {:execute_then_transition, [{:execute_ex_command, {:save, []}}], :normal, _} = result
    end

    test ":q → execute {:quit, []} then transition to normal" do
      result = Command.handle_key({@enter, 0}, fresh_state("q"))
      assert {:execute_then_transition, [{:execute_ex_command, {:quit, []}}], :normal, _} = result
    end

    test ":q! → execute {:force_quit, []} then transition to normal" do
      result = Command.handle_key({@enter, 0}, fresh_state("q!"))

      assert {:execute_then_transition, [{:execute_ex_command, {:force_quit, []}}], :normal, _} =
               result
    end

    test ":wq → execute {:save_quit, []} then transition to normal" do
      result = Command.handle_key({@enter, 0}, fresh_state("wq"))

      assert {:execute_then_transition, [{:execute_ex_command, {:save_quit, []}}], :normal, _} =
               result
    end

    test ":e filename → execute {:edit, filename} then transition to normal" do
      result = Command.handle_key({@enter, 0}, fresh_state("e README.md"))

      assert {:execute_then_transition, [{:execute_ex_command, {:edit, "README.md"}}], :normal, _} =
               result
    end

    test ":42 → execute {:goto_line, 42} then transition to normal" do
      result = Command.handle_key({@enter, 0}, fresh_state("42"))

      assert {:execute_then_transition, [{:execute_ex_command, {:goto_line, 42}}], :normal, _} =
               result
    end

    test "unknown command → execute {:unknown, raw} then transition to normal" do
      result = Command.handle_key({@enter, 0}, fresh_state("xyz"))

      assert {:execute_then_transition, [{:execute_ex_command, {:unknown, "xyz"}}], :normal, _} =
               result
    end

    test "input is cleared in the state after enter" do
      {:execute_then_transition, _, :normal, new_state} =
        Command.handle_key({@enter, 0}, fresh_state("w"))

      assert new_state.input == ""
    end
  end

  # ── Ignored keys ─────────────────────────────────────────────────────────────

  describe "ignored keys" do
    test "control characters with modifiers are ignored" do
      assert {:continue, state} = Command.handle_key({?a, 4}, fresh_state("w"))
      assert state.input == "w"
    end

    test "arrow keys are ignored" do
      assert {:continue, state} = Command.handle_key({57_416, 0}, fresh_state("w"))
      assert state.input == "w"
    end
  end

  # ── Normal → Command integration via Mode.process ────────────────────────────

  describe "Normal → : → command mode integration" do
    test "pressing : in normal mode transitions to command mode" do
      alias Minga.Mode

      initial = Mode.initial_state()
      {new_mode, _cmds, _state} = Mode.process(:normal, {?:, 0}, initial)
      assert new_mode == :command
    end

    test "typing w then enter emits :save command" do
      alias Minga.Mode

      # Simulate editor injecting CommandState (as the editor does on : transition)
      cmd_state = %CommandState{}

      # Type "w"
      {_mode, _, state2} = Mode.process(:command, {?w, 0}, cmd_state)
      assert state2.input == "w"

      # Press Enter
      {final_mode, cmds, _} = Mode.process(:command, {@enter, 0}, state2)
      assert final_mode == :normal
      assert {:execute_ex_command, {:save, []}} in cmds
    end
  end
end
