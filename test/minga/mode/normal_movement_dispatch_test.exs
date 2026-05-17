defmodule Minga.Mode.NormalMovementDispatchTest do
  @moduledoc """
  Layer 0 key dispatch coverage for normal-mode movement and scroll bindings.

  These tests classify the key-to-command behavior that used to live in editor GenServer movement tests. They assert `Minga.Mode.process/3` command tuples directly, without starting buffers or an editor.
  """
  use ExUnit.Case, async: true

  alias Minga.Mode

  @ctrl 0x02
  @arrow_left 57_350
  @arrow_right 57_351
  @arrow_up 57_352
  @arrow_down 57_353

  describe "Layer 0 pure key dispatch — movement commands" do
    test "normal movement keys return command tuples" do
      assert_commands(?h, [:move_left])
      assert_commands(?j, [:move_down])
      assert_commands(?k, [:move_up])
      assert_commands(?l, [:move_right])
      assert_commands(?0, [:move_to_line_start])
      assert_commands(?$, [:move_to_line_end])
    end

    test "arrow keys return movement command tuples" do
      assert_commands(@arrow_left, [:move_left])
      assert_commands(@arrow_right, [:move_right])
      assert_commands(@arrow_up, [:move_up])
      assert_commands(@arrow_down, [:move_down])
    end

    test "unknown normal-mode keys are ignored" do
      assert Mode.process(:normal, {57_376, 0}, Mode.initial_state()) ==
               {:normal, [], Mode.initial_state()}
    end
  end

  describe "Layer 0 pure key dispatch — count prefixes" do
    test "count prefixes expand the next movement command" do
      {:normal, [], state} = Mode.process(:normal, {?3, 0}, Mode.initial_state())

      assert Mode.process(:normal, {?l, 0}, state) ==
               {:normal, [:move_right, :move_right, :move_right], Mode.initial_state()}
    end

    test "count prefixes expand vertical movement commands" do
      {:normal, [], state} = Mode.process(:normal, {?2, 0}, Mode.initial_state())

      assert Mode.process(:normal, {?j, 0}, state) ==
               {:normal, [:move_down, :move_down], Mode.initial_state()}
    end
  end

  describe "Layer 0 pure key dispatch — page and viewport scroll commands" do
    test "ctrl page keys return scroll command tuples" do
      assert_commands(?d, @ctrl, [:half_page_down])
      assert_commands(?u, @ctrl, [:half_page_up])
      assert_commands(?f, @ctrl, [:page_down])
      assert_commands(?b, @ctrl, [:page_up])
      assert_commands(?e, @ctrl, [:scroll_down_line])
      assert_commands(?y, @ctrl, [:scroll_up_line])
    end

    test "z-prefixed scroll keys return viewport positioning commands" do
      {:normal, [], state} = Mode.process(:normal, {?z, 0}, Mode.initial_state())

      assert Mode.process(:normal, {?z, 0}, state) ==
               {:normal, [:scroll_center], Mode.initial_state()}

      {:normal, [], state} = Mode.process(:normal, {?z, 0}, Mode.initial_state())

      assert Mode.process(:normal, {?t, 0}, state) ==
               {:normal, [:scroll_cursor_top], Mode.initial_state()}

      {:normal, [], state} = Mode.process(:normal, {?z, 0}, Mode.initial_state())

      assert Mode.process(:normal, {?b, 0}, state) ==
               {:normal, [:scroll_cursor_bottom], Mode.initial_state()}
    end
  end

  describe "Layer 0 pure key dispatch — find-char commands" do
    test "find-char keys wait for a target and return tagged command tuples" do
      assert_find_char(?f, :f)
      assert_find_char(?F, :F)
      assert_find_char(?t, :t)
      assert_find_char(?T, :T)
    end

    test "repeat find keys return repeat command tuples" do
      assert_commands(?;, [:repeat_find_char])
      assert_commands(?,, [:repeat_find_char_reverse])
    end
  end

  defp assert_commands(codepoint, expected_commands),
    do: assert_commands(codepoint, 0, expected_commands)

  defp assert_commands(codepoint, mods, expected_commands) do
    assert Mode.process(:normal, {codepoint, mods}, Mode.initial_state()) ==
             {:normal, expected_commands, Mode.initial_state()}
  end

  defp assert_find_char(prefix, direction) do
    {:normal, [], state} = Mode.process(:normal, {prefix, 0}, Mode.initial_state())

    assert Mode.process(:normal, {?a, 0}, state) ==
             {:normal, [{:find_char, direction, "a"}], Mode.initial_state()}
  end
end
