defmodule Minga.EditingModel.VimTest do
  use ExUnit.Case, async: true

  alias Minga.EditingModel.Vim
  alias Minga.Mode

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Key constants matching libvaxis/terminal encoding
  defp key_j, do: {?j, 0}
  defp key_k, do: {?k, 0}
  defp key_i, do: {?i, 0}
  defp key_d, do: {?d, 0}
  defp key_3, do: {?3, 0}
  defp key_escape, do: {0x1B, 0}
  defp key_x, do: {?x, 0}

  # ── initial_state/0 ─────────────────────────────────────────────────────────

  describe "initial_state/0" do
    test "returns a Vim state in normal mode" do
      state = Vim.initial_state()
      assert %Vim{} = state
      assert Vim.mode(state) == :normal
    end

    test "mode_display shows NORMAL" do
      state = Vim.initial_state()
      assert Vim.mode_display(state) == "-- NORMAL --"
    end
  end

  # ── process_key/2 ──────────────────────────────────────────────────────────

  describe "process_key/2 produces same results as Mode.process/3" do
    test "j in normal mode produces :move_down" do
      state = Vim.initial_state()
      {mode, commands, _new_state} = Vim.process_key(state, key_j())
      assert mode == :normal
      assert commands == [:move_down]
    end

    test "k in normal mode produces :move_up" do
      state = Vim.initial_state()
      {mode, commands, _new_state} = Vim.process_key(state, key_k())
      assert mode == :normal
      assert commands == [:move_up]
    end

    test "matches Mode.process/3 exactly" do
      vim_state = Vim.initial_state()
      mode_state = Mode.initial_state()

      {vim_mode, vim_cmds, _vim_new} = Vim.process_key(vim_state, key_j())
      {mode_mode, mode_cmds, _mode_new} = Mode.process(:normal, key_j(), mode_state)

      assert vim_mode == mode_mode
      assert vim_cmds == mode_cmds
    end
  end

  # ── Mode transitions ──────────────────────────────────────────────────────

  describe "mode transitions" do
    test "i transitions to insert mode" do
      state = Vim.initial_state()
      {mode, _commands, new_state} = Vim.process_key(state, key_i())
      assert mode == :insert
      assert Vim.mode(new_state) == :insert
      assert Vim.mode_display(new_state) == "-- INSERT --"
    end

    test "escape in insert mode returns to normal" do
      state = Vim.initial_state()
      {_mode, _commands, insert_state} = Vim.process_key(state, key_i())
      assert Vim.mode(insert_state) == :insert

      {mode, _commands, normal_state} = Vim.process_key(insert_state, key_escape())
      assert mode == :normal
      assert Vim.mode(normal_state) == :normal
    end

    test "d enters operator-pending mode" do
      state = Vim.initial_state()
      {mode, commands, new_state} = Vim.process_key(state, key_d())
      assert mode == :operator_pending
      assert commands == []
      assert Vim.mode(new_state) == :operator_pending
    end
  end

  # ── Count prefix ───────────────────────────────────────────────────────────

  describe "count prefix" do
    test "3j produces three :move_down commands" do
      state = Vim.initial_state()
      {_mode, _commands, state} = Vim.process_key(state, key_3())
      {mode, commands, _state} = Vim.process_key(state, key_j())
      assert mode == :normal
      assert commands == [:move_down, :move_down, :move_down]
    end
  end

  # ── from_editor/2 and to_editor/1 ─────────────────────────────────────────

  describe "from_editor/2 and to_editor/1" do
    test "round-trip preserves mode and mode_state" do
      state = Vim.initial_state()
      {_mode, _commands, insert_state} = Vim.process_key(state, key_i())

      {mode, mode_state} = Vim.to_editor(insert_state)
      assert mode == :insert

      restored = Vim.from_editor(mode, mode_state)
      assert Vim.mode(restored) == :insert
    end

    test "from_editor with normal mode and fresh state" do
      state = Vim.from_editor(:normal, Mode.initial_state())
      assert Vim.mode(state) == :normal
      assert Vim.mode_display(state) == "-- NORMAL --"
    end
  end

  # ── New behaviour callbacks (Phase B) ──────────────────────────────────────

  describe "inserting?/1" do
    test "false in normal mode" do
      refute Vim.inserting?(Vim.initial_state())
    end

    test "true in insert mode" do
      {_, _, state} = Vim.process_key(Vim.initial_state(), key_i())
      assert Vim.inserting?(state)
    end
  end

  describe "selecting?/1" do
    test "false in normal mode" do
      refute Vim.selecting?(Vim.initial_state())
    end

    test "false in insert mode" do
      {_, _, state} = Vim.process_key(Vim.initial_state(), key_i())
      refute Vim.selecting?(state)
    end
  end

  describe "cursor_shape/1" do
    test "block in normal mode" do
      assert Vim.cursor_shape(Vim.initial_state()) == :block
    end

    test "beam in insert mode" do
      {_, _, state} = Vim.process_key(Vim.initial_state(), key_i())
      assert Vim.cursor_shape(state) == :beam
    end
  end

  describe "key_sequence_pending?/1" do
    test "false in normal mode at rest" do
      refute Vim.key_sequence_pending?(Vim.initial_state())
    end

    test "true in operator-pending mode" do
      {_, _, state} = Vim.process_key(Vim.initial_state(), key_d())
      assert Vim.key_sequence_pending?(state)
    end
  end

  describe "status_segment/1" do
    test "NORMAL in normal mode" do
      assert Vim.status_segment(Vim.initial_state()) == "NORMAL"
    end

    test "INSERT in insert mode" do
      {_, _, state} = Vim.process_key(Vim.initial_state(), key_i())
      assert Vim.status_segment(state) == "INSERT"
    end
  end

  # ── Insert mode key handling ───────────────────────────────────────────────

  describe "insert mode" do
    test "printable character produces insert_char command" do
      state = Vim.initial_state()
      {_mode, _commands, insert_state} = Vim.process_key(state, key_i())

      {mode, commands, _new_state} = Vim.process_key(insert_state, key_x())
      assert mode == :insert
      assert commands == [{:insert_char, "x"}]
    end
  end
end
