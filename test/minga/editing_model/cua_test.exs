defmodule Minga.EditingModel.CUATest do
  @moduledoc """
  Unit tests for the CUA editing model.

  Tests the CUA state struct and EditingModel behaviour callbacks.
  Key dispatch is tested with raw codepoints and modifier flags
  matching the port protocol encoding.
  """

  use ExUnit.Case, async: true

  alias Minga.EditingModel.CUA

  # Modifier flags (matching port protocol)
  @shift 1
  @cmd 8

  # Special codepoints (matching port protocol)
  @up 0xF700
  @down 0xF701
  @left 0xF702
  @right 0xF703
  @backspace 0x7F
  @enter 0x0D
  @escape 0x1B
  @home 0xF729
  @end_key 0xF72B

  # ── initial_state/0 ─────────────────────────────────────────────────────────

  describe "initial_state/0" do
    test "returns a CUA state with no selection" do
      state = CUA.initial_state()
      assert %CUA{selection: nil} = state
    end
  end

  # ── EditingModel callbacks ─────────────────────────────────────────────────

  describe "mode/1" do
    test "always returns :cua" do
      assert CUA.mode(CUA.initial_state()) == :cua
    end
  end

  describe "mode_display/1" do
    test "returns empty string (no mode indicator in CUA)" do
      assert CUA.mode_display(CUA.initial_state()) == ""
    end
  end

  describe "inserting?/1" do
    test "always returns true" do
      assert CUA.inserting?(CUA.initial_state())
    end
  end

  describe "selecting?/1" do
    test "false when no selection" do
      refute CUA.selecting?(CUA.initial_state())
    end

    test "true when selection is active" do
      state = %CUA{selection: %{anchor: {0, 0}}}
      assert CUA.selecting?(state)
    end
  end

  describe "cursor_shape/1" do
    test "always returns :beam" do
      assert CUA.cursor_shape(CUA.initial_state()) == :beam
    end
  end

  describe "key_sequence_pending?/1" do
    test "always returns false" do
      refute CUA.key_sequence_pending?(CUA.initial_state())
    end
  end

  describe "status_segment/1" do
    test "returns empty string" do
      assert CUA.status_segment(CUA.initial_state()) == ""
    end
  end

  # ── Key dispatch: printable characters ─────────────────────────────────────

  describe "process_key/2 with printable characters" do
    test "letter produces insert_char command" do
      state = CUA.initial_state()
      {:cua, commands, _new_state} = CUA.process_key(state, {?a, 0})
      assert commands == [{:insert_char, "a"}]
    end

    test "space produces insert_char command" do
      state = CUA.initial_state()
      {:cua, commands, _new_state} = CUA.process_key(state, {0x20, 0})
      assert commands == [{:insert_char, " "}]
    end

    test "typing with active selection replaces it" do
      state = %CUA{selection: %{anchor: {0, 0}}}
      {:cua, commands, new_state} = CUA.process_key(state, {?x, 0})
      assert commands == [:delete_visual_selection, {:insert_char, "x"}]
      assert new_state.selection == nil
    end
  end

  # ── Key dispatch: arrow keys ───────────────────────────────────────────────

  describe "process_key/2 with arrow keys" do
    test "plain arrows produce movement commands" do
      state = CUA.initial_state()

      {:cua, cmds, _} = CUA.process_key(state, {@up, 0})
      assert cmds == [:move_up]

      {:cua, cmds, _} = CUA.process_key(state, {@down, 0})
      assert cmds == [:move_down]

      {:cua, cmds, _} = CUA.process_key(state, {@left, 0})
      assert cmds == [:move_left]

      {:cua, cmds, _} = CUA.process_key(state, {@right, 0})
      assert cmds == [:move_right]
    end

    test "plain arrows clear selection" do
      state = %CUA{selection: %{anchor: {0, 0}}}
      {:cua, _, new_state} = CUA.process_key(state, {@left, 0})
      assert new_state.selection == nil
    end

    test "shift+arrows produce extend_selection commands" do
      state = CUA.initial_state()

      {:cua, cmds, _} = CUA.process_key(state, {@up, @shift})
      assert cmds == [{:extend_selection, :up}]

      {:cua, cmds, _} = CUA.process_key(state, {@down, @shift})
      assert cmds == [{:extend_selection, :down}]

      {:cua, cmds, _} = CUA.process_key(state, {@left, @shift})
      assert cmds == [{:extend_selection, :left}]

      {:cua, cmds, _} = CUA.process_key(state, {@right, @shift})
      assert cmds == [{:extend_selection, :right}]
    end

    test "shift+arrow starts selection when none exists" do
      state = CUA.initial_state()
      {:cua, _, new_state} = CUA.process_key(state, {@right, @shift})
      assert new_state.selection != nil
    end

    test "shift+arrow preserves existing selection" do
      state = %CUA{selection: %{anchor: {5, 3}}}
      {:cua, _, new_state} = CUA.process_key(state, {@right, @shift})
      assert new_state.selection == %{anchor: {5, 3}}
    end
  end

  # ── Key dispatch: Cmd chords ───────────────────────────────────────────────

  describe "process_key/2 with Cmd chords" do
    test "Cmd+Z = undo" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {?z, @cmd})
      assert cmds == [:undo]
    end

    test "Cmd+Shift+Z = redo" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {?z, @cmd + @shift})
      assert cmds == [:redo]
    end

    test "Cmd+C = yank selection" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {?c, @cmd})
      assert cmds == [:yank_selection]
    end

    test "Cmd+X = cut selection" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {?x, @cmd})
      assert cmds == [:delete_visual_selection]
    end

    test "Cmd+V = paste" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {?v, @cmd})
      assert cmds == [:paste_after]
    end

    test "Cmd+A = select all" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {?a, @cmd})
      assert cmds == [:select_all]
    end

    test "Cmd+S = save" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {?s, @cmd})
      assert cmds == [:save]
    end
  end

  # ── Key dispatch: editing keys ─────────────────────────────────────────────

  describe "process_key/2 with editing keys" do
    test "backspace without selection deletes before" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {@backspace, 0})
      assert cmds == [:delete_before]
    end

    test "backspace with selection deletes selection" do
      state = %CUA{selection: %{anchor: {0, 0}}}
      {:cua, cmds, new_state} = CUA.process_key(state, {@backspace, 0})
      assert cmds == [:delete_visual_selection]
      assert new_state.selection == nil
    end

    test "enter inserts newline" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {@enter, 0})
      assert cmds == [{:insert_char, "\n"}]
    end

    test "escape clears selection" do
      state = %CUA{selection: %{anchor: {0, 0}}}
      {:cua, cmds, new_state} = CUA.process_key(state, {@escape, 0})
      assert cmds == []
      assert new_state.selection == nil
    end
  end

  # ── Key dispatch: Home/End ─────────────────────────────────────────────────

  describe "process_key/2 with Home/End" do
    test "Home moves to first non-blank" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {@home, 0})
      assert cmds == [:first_non_blank]
    end

    test "End moves to line end" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {@end_key, 0})
      assert cmds == [:line_end]
    end

    test "Shift+Home extends selection to line start" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {@home, @shift})
      assert cmds == [{:extend_selection, :line_start}]
    end

    test "Shift+End extends selection to line end" do
      {:cua, cmds, _} = CUA.process_key(CUA.initial_state(), {@end_key, @shift})
      assert cmds == [{:extend_selection, :line_end}]
    end
  end

  # ── process_key/2 always returns :cua mode ─────────────────────────────────

  describe "process_key/2 mode label" do
    test "always returns :cua regardless of key" do
      state = CUA.initial_state()
      {:cua, _, _} = CUA.process_key(state, {?a, 0})
      {:cua, _, _} = CUA.process_key(state, {@escape, 0})
      {:cua, _, _} = CUA.process_key(state, {?z, @cmd})
    end
  end
end
