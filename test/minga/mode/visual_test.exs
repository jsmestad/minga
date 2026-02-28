defmodule Minga.Mode.VisualTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Mode
  alias Minga.Mode.Normal
  alias Minga.Mode.Visual

  alias Minga.Mode.VisualState

  # Build a fresh FSM state as if visual mode was just entered with anchor at
  # the given position and the given type.
  defp visual_state(anchor \\ {0, 0}, type \\ :char) do
    %VisualState{visual_anchor: anchor, visual_type: type}
  end

  # ── Entering visual from Normal ──────────────────────────────────────────────

  describe "entering visual mode from Normal via 'v' (characterwise)" do
    test "v transitions to :visual mode" do
      state = Mode.initial_state()
      {new_mode, commands, new_state} = Mode.process(:normal, {?v, 0}, state)
      assert new_mode == :visual
      assert commands == []
      assert new_state.visual_type == :char
    end

    test "v sets visual_type to :char in the mode state" do
      {:transition, :visual, new_state} = Normal.handle_key({?v, 0}, Mode.initial_state())
      assert new_state.visual_type == :char
    end

    test "v returns VisualState with default anchor (editor overrides it)" do
      {:transition, :visual, new_state} = Normal.handle_key({?v, 0}, Mode.initial_state())
      assert %VisualState{} = new_state
      # Default anchor is {0, 0}; the editor overwrites this with the real cursor position
      assert new_state.visual_anchor == {0, 0}
    end
  end

  describe "entering visual mode from Normal via 'V' (linewise)" do
    test "V transitions to :visual mode" do
      state = Mode.initial_state()
      {new_mode, commands, new_state} = Mode.process(:normal, {?V, 0}, state)
      assert new_mode == :visual
      assert commands == []
      assert new_state.visual_type == :line
    end

    test "V sets visual_type to :line in the mode state" do
      {:transition, :visual, new_state} = Normal.handle_key({?V, 0}, Mode.initial_state())
      assert new_state.visual_type == :line
    end
  end

  # ── Escape cancels visual selection ─────────────────────────────────────────

  describe "Escape cancels visual selection" do
    test "Escape transitions back to :normal" do
      state = visual_state({0, 0}, :char)
      assert {:transition, :normal, _} = Visual.handle_key({27, 0}, state)
    end

    test "Escape with modifier also transitions to :normal" do
      state = visual_state({2, 3}, :line)
      assert {:transition, :normal, _} = Visual.handle_key({27, 4}, state)
    end

    test "Mode.process: Escape in visual returns :normal with no commands" do
      state = visual_state({0, 0})
      {new_mode, commands, _} = Mode.process(:visual, {27, 0}, state)
      assert new_mode == :normal
      assert commands == []
    end
  end

  # ── Movement extends selection ───────────────────────────────────────────────

  describe "movement keys in visual mode" do
    test "h emits :move_left" do
      state = visual_state()
      assert {:execute, :move_left, _} = Visual.handle_key({?h, 0}, state)
    end

    test "j emits :move_down" do
      state = visual_state()
      assert {:execute, :move_down, _} = Visual.handle_key({?j, 0}, state)
    end

    test "k emits :move_up" do
      state = visual_state()
      assert {:execute, :move_up, _} = Visual.handle_key({?k, 0}, state)
    end

    test "l emits :move_right" do
      state = visual_state()
      assert {:execute, :move_right, _} = Visual.handle_key({?l, 0}, state)
    end

    test "w emits :word_forward" do
      state = visual_state()
      assert {:execute, :word_forward, _} = Visual.handle_key({?w, 0}, state)
    end

    test "b emits :word_backward" do
      state = visual_state()
      assert {:execute, :word_backward, _} = Visual.handle_key({?b, 0}, state)
    end

    test "e emits :end_of_word" do
      state = visual_state()
      assert {:execute, :end_of_word, _} = Visual.handle_key({?e, 0}, state)
    end

    test "Mode.process: j in visual emits :move_down and stays in :visual" do
      state = visual_state()
      {new_mode, commands, _} = Mode.process(:visual, {?j, 0}, state)
      assert new_mode == :visual
      assert commands == [:move_down]
    end

    test "Mode.process: movement stays in visual mode (does not cancel selection)" do
      state = visual_state({1, 2})
      {new_mode, _, new_state} = Mode.process(:visual, {?l, 0}, state)
      assert new_mode == :visual
      # anchor is preserved through movements
      assert new_state.visual_anchor == {1, 2}
    end
  end

  describe "arrow keys in visual mode" do
    test "up arrow (57_416) emits :move_up" do
      assert {:execute, :move_up, _} = Visual.handle_key({57_416, 0}, visual_state())
    end

    test "down arrow (57_424) emits :move_down" do
      assert {:execute, :move_down, _} = Visual.handle_key({57_424, 0}, visual_state())
    end

    test "left arrow (57_419) emits :move_left" do
      assert {:execute, :move_left, _} = Visual.handle_key({57_419, 0}, visual_state())
    end

    test "right arrow (57_421) emits :move_right" do
      assert {:execute, :move_right, _} = Visual.handle_key({57_421, 0}, visual_state())
    end
  end

  # ── Operators on selection ───────────────────────────────────────────────────

  describe "d — delete selection, transition to Normal" do
    test "d emits :delete_visual_selection and transitions to :normal" do
      state = visual_state({0, 0}, :char)

      assert {:execute_then_transition, [:delete_visual_selection], :normal, _} =
               Visual.handle_key({?d, 0}, state)
    end

    test "Mode.process: d returns :normal mode with :delete_visual_selection command" do
      state = visual_state()
      {new_mode, commands, _} = Mode.process(:visual, {?d, 0}, state)
      assert new_mode == :normal
      assert commands == [:delete_visual_selection]
    end

    test "d works identically in linewise visual mode" do
      state = visual_state({2, 0}, :line)

      assert {:execute_then_transition, [:delete_visual_selection], :normal, _} =
               Visual.handle_key({?d, 0}, state)
    end
  end

  describe "c — delete selection, transition to Insert" do
    test "c emits :delete_visual_selection and transitions to :insert" do
      state = visual_state({0, 3}, :char)

      assert {:execute_then_transition, [:delete_visual_selection], :insert, _} =
               Visual.handle_key({?c, 0}, state)
    end

    test "Mode.process: c returns :insert mode with :delete_visual_selection command" do
      state = visual_state()
      {new_mode, commands, _} = Mode.process(:visual, {?c, 0}, state)
      assert new_mode == :insert
      assert commands == [:delete_visual_selection]
    end
  end

  describe "y — yank selection, transition to Normal" do
    test "y emits :yank_visual_selection and transitions to :normal" do
      state = visual_state({1, 4}, :char)

      assert {:execute_then_transition, [:yank_visual_selection], :normal, _} =
               Visual.handle_key({?y, 0}, state)
    end

    test "Mode.process: y returns :normal mode with :yank_visual_selection command" do
      state = visual_state()
      {new_mode, commands, _} = Mode.process(:visual, {?y, 0}, state)
      assert new_mode == :normal
      assert commands == [:yank_visual_selection]
    end

    test "y does not modify the state (buffer unchanged at mode level)" do
      state = visual_state({0, 0})
      {:execute_then_transition, _, _, returned_state} = Visual.handle_key({?y, 0}, state)
      assert returned_state == state
    end
  end

  # ── Linewise vs characterwise ────────────────────────────────────────────────

  describe "linewise visual mode (V)" do
    test "visual_type is :line when entered via V" do
      {:transition, :visual, new_state} = Normal.handle_key({?V, 0}, Mode.initial_state())
      assert new_state.visual_type == :line
    end

    test "operators in linewise visual still emit the same commands" do
      state = visual_state({3, 0}, :line)

      assert {:execute_then_transition, [:delete_visual_selection], :normal, _} =
               Visual.handle_key({?d, 0}, state)
    end

    test "Mode.display shows -- VISUAL LINE -- for linewise" do
      assert Mode.display(:visual, %VisualState{visual_type: :line}) == "-- VISUAL LINE --"
    end

    test "Mode.display shows -- VISUAL -- for characterwise" do
      assert Mode.display(:visual, %{visual_type: :char}) == "-- VISUAL --"
    end

    test "Mode.display/1 still shows -- VISUAL -- for backward compat" do
      assert Mode.display(:visual) == "-- VISUAL --"
    end
  end

  # ── Unknown keys ────────────────────────────────────────────────────────────

  describe "unknown keys in visual mode" do
    test "unknown key produces {:continue, state}" do
      state = visual_state({0, 0})
      assert {:continue, ^state} = Visual.handle_key({?z, 0}, state)
    end

    test "control character is ignored" do
      state = visual_state()
      assert {:continue, _} = Visual.handle_key({?x, 2}, state)
    end

    test "unknown key does not alter mode state" do
      state = visual_state({2, 5}, :line)
      {:continue, returned} = Visual.handle_key({?q, 0}, state)
      assert returned.visual_anchor == {2, 5}
      assert returned.visual_type == :line
    end
  end

  # ── Round-trip: Normal → Visual → Normal ────────────────────────────────────

  describe "Normal → Visual → Normal round-trip" do
    test "v enters visual, Escape returns to normal" do
      s0 = Mode.initial_state()
      {mode1, _, s1} = Mode.process(:normal, {?v, 0}, s0)
      assert mode1 == :visual

      {mode2, _, _} = Mode.process(:visual, {27, 0}, s1)
      assert mode2 == :normal
    end

    test "V enters visual line, d exits to normal" do
      s0 = Mode.initial_state()
      {mode1, _, s1} = Mode.process(:normal, {?V, 0}, s0)
      assert mode1 == :visual
      assert s1.visual_type == :line

      {mode2, cmds, _} = Mode.process(:visual, {?d, 0}, s1)
      assert mode2 == :normal
      assert cmds == [:delete_visual_selection]
    end

    test "v enters visual, c exits to insert" do
      s0 = Mode.initial_state()
      {_mode, _, s1} = Mode.process(:normal, {?v, 0}, s0)
      {mode2, cmds, _} = Mode.process(:visual, {?c, 0}, s1)
      assert mode2 == :insert
      assert cmds == [:delete_visual_selection]
    end
  end

  # ── Integration: buffer operations ──────────────────────────────────────────

  describe "delete_visual_selection with real buffer (characterwise)" do
    setup do
      {:ok, buf} = BufferServer.start_link(content: "hello world\nfoo bar")
      {:ok, buf: buf}
    end

    test "deleting 'hello' from start of line", %{buf: buf} do
      # Place cursor at col 4 (on 'o')
      BufferServer.move_to(buf, {0, 4})

      # Simulate: anchor={0,0}, cursor={0,4}, delete char selection
      anchor = {0, 0}
      cursor = BufferServer.cursor(buf)
      assert cursor == {0, 4}

      # delete_range is inclusive on both ends
      BufferServer.delete_range(buf, anchor, cursor)

      assert BufferServer.content(buf) == " world\nfoo bar"
    end

    test "yanking a range returns correct text", %{buf: buf} do
      BufferServer.move_to(buf, {0, 4})
      text = BufferServer.get_range(buf, {0, 0}, {0, 4})
      assert text == "hello"
    end
  end

  describe "delete_visual_selection with real buffer (linewise)" do
    setup do
      {:ok, buf} = BufferServer.start_link(content: "line one\nline two\nline three")
      {:ok, buf: buf}
    end

    test "deleting first two lines leaves only the third", %{buf: buf} do
      BufferServer.delete_lines(buf, 0, 1)
      assert BufferServer.content(buf) == "line three"
    end

    test "deleting the middle line preserves surrounding lines", %{buf: buf} do
      BufferServer.delete_lines(buf, 1, 1)
      assert BufferServer.content(buf) == "line one\nline three"
    end

    test "deleting all lines leaves an empty buffer", %{buf: buf} do
      BufferServer.delete_lines(buf, 0, 2)
      assert BufferServer.content(buf) == ""
    end

    test "get_lines_content returns joined text of a range", %{buf: buf} do
      text = BufferServer.get_lines_content(buf, 0, 1)
      assert text == "line one\nline two"
    end
  end
end
