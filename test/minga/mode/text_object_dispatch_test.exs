defmodule Minga.Mode.TextObjectDispatchTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Mode.OperatorPending
  alias Minga.Mode.OperatorPendingState
  alias Minga.Mode.Visual
  alias Minga.Mode.VisualState

  test "inner and around prefixes resolve the same objects but keep mode-specific transitions" do
    objects = [
      {?w, :word},
      {?p, :paragraph},
      {?s, :sentence},
      {?", {:quote, "\""}},
      {?', {:quote, "'"}},
      {?(, {:paren, "(", ")"}},
      {?), {:paren, "(", ")"}},
      {?[, {:paren, "[", "]"}},
      {?], {:paren, "[", "]"}},
      {?{, {:paren, "{", "}"}},
      {?}, {:paren, "{", "}"}},
      {?f, {:structural, :function}},
      {?c, {:structural, :class}},
      {?a, {:structural, :parameter}},
      {?b, {:structural, :block}}
    ]

    for {prefix, modifier} <- [{?i, :inner}, {?a, :around}], {key, object} <- objects do
      visual = %VisualState{visual_anchor: {4, 7}, visual_type: :char}
      assert {:continue, selecting} = Visual.handle_key({prefix, 0}, visual)

      assert {:execute, [{:visual_text_object, ^modifier, ^object}], ^visual} =
               Visual.handle_key({key, 0}, selecting)

      for {operator, command, next_mode} <- [
            {:delete, :delete_text_object, :normal},
            {:change, :change_text_object, :insert}
          ] do
        pending = %OperatorPendingState{operator: operator, op_count: 3}
        assert {:continue, selecting} = OperatorPending.handle_key({prefix, 0}, pending)

        assert {:execute_then_transition, [{^command, ^modifier, ^object}], ^next_mode, _state} =
                 OperatorPending.handle_key({key, 0}, selecting)
      end
    end
  end

  test "a prefix does not swallow operator counts, ordinary motions, modified keys, or Escape" do
    pending = %OperatorPendingState{operator: :delete, op_count: 1, text_object_modifier: :inner}

    assert {:continue, %OperatorPendingState{count: 2, text_object_modifier: :inner}} =
             OperatorPending.handle_key({?2, 0}, pending)

    assert {:execute_then_transition, [{:delete_motion, :word_end}], :normal, _state} =
             OperatorPending.handle_key({?e, 0}, pending)

    assert {:execute_then_transition, [{:delete_motion, :page_down}], :normal, _state} =
             OperatorPending.handle_key({?f, 0x02}, pending)

    assert {:continue, ^pending} = OperatorPending.handle_key({?z, 0}, pending)
    assert {:transition, :normal, _state} = OperatorPending.handle_key({27, 0}, pending)
  end

  test "visual comment, delete, and user bindings still take precedence or fall through" do
    trie = Bindings.bind(Bindings.new(), [{?z, 0}], :word_end, "Move to word end")
    state = %VisualState{visual_anchor: {0, 0}, visual_type: :char, mode_trie: trie}
    assert {:continue, selecting} = Visual.handle_key({?i, 0}, state)
    assert {:continue, prefix} = Visual.handle_key({?g, 0}, selecting)

    assert {:execute_then_transition, [:comment_visual_selection], :normal, _state} =
             Visual.handle_key({?c, 0}, prefix)

    assert {:execute_then_transition, [:delete_visual_selection], :normal, _state} =
             Visual.handle_key({?d, 0}, selecting)

    assert {:execute, :word_end, ^selecting} = Visual.handle_key({?z, 0}, selecting)
    assert {:continue, ^selecting} = Visual.handle_key({?`, 0}, selecting)
  end
end
