defmodule Minga.Mode.ReplaceTest do
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.Replace
  alias Minga.Mode.ReplaceState

  defp fresh_state, do: %ReplaceState{}

  describe "escape returns to normal mode" do
    test "Escape transitions to :normal" do
      assert {:transition, :normal, _} = Replace.handle_key({27, 0}, fresh_state())
    end

    test "Escape with modifiers transitions to :normal" do
      assert {:transition, :normal, _} = Replace.handle_key({27, 1}, fresh_state())
    end
  end

  describe "printable characters overwrite" do
    test "printable char emits {:replace_overwrite, char}" do
      assert {:execute, {:replace_overwrite, "a"}, _} =
               Replace.handle_key({?a, 0}, fresh_state())
    end

    test "uppercase char emits {:replace_overwrite, char}" do
      assert {:execute, {:replace_overwrite, "Z"}, _} =
               Replace.handle_key({?Z, 0}, fresh_state())
    end

    test "digit char emits {:replace_overwrite, char}" do
      assert {:execute, {:replace_overwrite, "5"}, _} =
               Replace.handle_key({?5, 0}, fresh_state())
    end

    test "space char emits {:replace_overwrite, \" \"}" do
      assert {:execute, {:replace_overwrite, " "}, _} =
               Replace.handle_key({32, 0}, fresh_state())
    end

    test "replace_overwrite does not mutate mode state" do
      {:execute, {:replace_overwrite, _char}, returned_state} =
        Replace.handle_key({?x, 0}, fresh_state())

      # The mode state returned by handle_key is the same — original_chars
      # update happens in the editor's execute_command, not in handle_key.
      assert returned_state == fresh_state()
    end
  end

  describe "backspace restores original character" do
    test "backspace (127) emits :replace_restore" do
      assert {:execute, :replace_restore, _} = Replace.handle_key({127, 0}, fresh_state())
    end

    test "backspace (8) emits :replace_restore" do
      assert {:execute, :replace_restore, _} = Replace.handle_key({8, 0}, fresh_state())
    end
  end

  describe "arrow key movement" do
    test "up arrow emits :move_up" do
      assert {:execute, :move_up, _} = Replace.handle_key({57_352, 0}, fresh_state())
    end

    test "down arrow emits :move_down" do
      assert {:execute, :move_down, _} = Replace.handle_key({57_353, 0}, fresh_state())
    end

    test "left arrow emits :move_left" do
      assert {:execute, :move_left, _} = Replace.handle_key({57_350, 0}, fresh_state())
    end

    test "right arrow emits :move_right" do
      assert {:execute, :move_right, _} = Replace.handle_key({57_351, 0}, fresh_state())
    end
  end

  describe "unknown keys are no-ops" do
    test "printable key with modifier (not Escape/backspace) returns {:continue, state}" do
      # Keys with non-zero modifier (e.g. ctrl+a = {?a, 0x02}) don't match the
      # printable clause ({codepoint, 0}), so they fall through to {:continue, state}.
      assert {:continue, _} = Replace.handle_key({?a, 0x02}, fresh_state())
    end
  end

  describe "Mode dispatcher integration" do
    test "Mode.process/3 dispatches to Replace for :replace mode" do
      state = %ReplaceState{}
      {mode, cmds, _new_state} = Mode.process(:replace, {?a, 0}, state)
      assert mode == :replace
      assert cmds == [{:replace_overwrite, "a"}]
    end

    test "Mode.process/3 transitions :replace → :normal on Escape" do
      state = %ReplaceState{}
      {mode, cmds, _new_state} = Mode.process(:replace, {27, 0}, state)
      assert mode == :normal
      assert cmds == []
    end

    test "Mode.display/1 returns '-- REPLACE --' for :replace mode" do
      assert Mode.display(:replace) == "-- REPLACE --"
    end
  end
end
