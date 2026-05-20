defmodule Minga.Mode.VisualTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Mode
  alias Minga.Mode.Normal
  alias Minga.Mode.Visual
  alias Minga.Mode.VisualState

  defp visual_state(anchor \\ {0, 0}, type \\ :char),
    do: %VisualState{visual_anchor: anchor, visual_type: type}

  describe "entering and leaving visual mode" do
    test "v and V enter visual variants, display correctly, and round-trip out" do
      assert {:visual, [], %VisualState{visual_type: :char, visual_anchor: {0, 0}}} =
               Mode.process(:normal, {?v, 0}, Mode.initial_state())

      assert {:transition, :visual, %VisualState{visual_type: :char, visual_anchor: {0, 0}}} =
               Normal.handle_key({?v, 0}, Mode.initial_state())

      assert {:visual, [], %VisualState{visual_type: :line} = line_state} =
               Mode.process(:normal, {?V, 0}, Mode.initial_state())

      assert {:transition, :visual, %VisualState{visual_type: :line}} =
               Normal.handle_key({?V, 0}, Mode.initial_state())

      assert Mode.display(:visual, %VisualState{visual_type: :line}) == "-- VISUAL LINE --"
      assert Mode.display(:visual, %{visual_type: :char}) == "-- VISUAL --"
      assert Mode.display(:visual) == "-- VISUAL --"

      assert {:normal, [], _state} = Mode.process(:visual, {27, 0}, visual_state())
      assert {:transition, :normal, _state} = Visual.handle_key({27, 4}, line_state)
    end

    test "movement, structural navigation, scrolling, and arrows stay in visual mode and preserve anchor" do
      cases = [
        {{?h, 0}, :move_left},
        {{?j, 0}, :move_down},
        {{?k, 0}, :move_up},
        {{?l, 0}, :move_right},
        {{?h, 0x04}, :nav_parent},
        {{?l, 0x04}, :nav_first_child},
        {{?j, 0x04}, :nav_next_sibling},
        {{?k, 0x04}, :nav_prev_sibling},
        {{?w, 0}, :word_forward},
        {{?b, 0}, :word_backward},
        {{?e, 0}, :word_end},
        {{?d, 0x02}, :half_page_down},
        {{?u, 0x02}, :half_page_up},
        {{?f, 0x02}, :page_down},
        {{?b, 0x02}, :page_up},
        {{57_352, 0}, :move_up},
        {{57_353, 0}, :move_down},
        {{57_350, 0}, :move_left},
        {{57_351, 0}, :move_right}
      ]

      for {key, command} <- cases do
        assert {:execute, ^command, _state} = Visual.handle_key(key, visual_state({1, 2}))

        assert {:visual, [^command], %VisualState{visual_anchor: {1, 2}}} =
                 Mode.process(:visual, key, visual_state({1, 2}))
      end
    end
  end

  describe "selection operators" do
    test "delete, change, yank, indent, and dedent emit selection commands and transition appropriately" do
      cases = [
        {?d, :normal, [:delete_visual_selection]},
        {?x, :normal, [:delete_visual_selection]},
        {?c, :insert, [:delete_visual_selection]},
        {?y, :normal, [:yank_visual_selection]},
        {?>, :normal, [:indent_visual_selection]},
        {?<, :normal, [:dedent_visual_selection]}
      ]

      for {key, mode, commands} <- cases do
        assert {:execute_then_transition, ^commands, ^mode, returned_state} =
                 Visual.handle_key({key, 0}, visual_state({2, 0}, :line))

        assert returned_state == visual_state({2, 0}, :line)
        assert {^mode, ^commands, _state} = Mode.process(:visual, {key, 0}, visual_state())
      end

      assert Visual.handle_key({?x, 0}, visual_state()) ==
               Visual.handle_key({?d, 0}, visual_state())
    end

    test "unknown and modified keys continue without mutating state" do
      state = visual_state({2, 5}, :line)
      assert {:continue, ^state} = Visual.handle_key({?z, 0}, state)
      assert {:continue, ^state} = Visual.handle_key({?q, 0}, state)
      assert {:continue, ^state} = Visual.handle_key({?x, 2}, state)
    end
  end

  describe "buffer selection behavior" do
    test "characterwise selection deletes and yanks inclusive ranges" do
      {:ok, buf} = BufferProcess.start_link(content: "hello world\nfoo bar")
      BufferProcess.move_to(buf, {0, 4})

      assert BufferProcess.text_between_inclusive(buf, {0, 0}, BufferProcess.cursor(buf)) ==
               "hello"

      BufferProcess.delete_range(buf, {0, 0}, BufferProcess.cursor(buf))
      assert BufferProcess.content(buf) == " world\nfoo bar"
    end

    test "linewise selection deletes line ranges and reads joined content" do
      {:ok, buf} = BufferProcess.start_link(content: "line one\nline two\nline three")
      assert BufferProcess.content_on_lines(buf, 0, 1) == "line one\nline two"

      BufferProcess.delete_lines(buf, 1, 1)
      assert BufferProcess.content(buf) == "line one\nline three"

      BufferProcess.delete_lines(buf, 0, 1)
      assert BufferProcess.content(buf) == ""
    end
  end

  describe "wrapping selections" do
    test "paired delimiter keys wrap visual selections" do
      cases = [
        {?(, "(", ")"},
        {?[, "[", "]"},
        {?", "\"", "\""},
        {?', "'", "'"},
        {?`, "`", "`"}
      ]

      for {key, left, right} <- cases do
        assert {:execute_then_transition, [{:wrap_visual_selection, ^left, ^right}], :normal,
                _state} =
                 Visual.handle_key({key, 0}, visual_state())
      end
    end
  end
end
