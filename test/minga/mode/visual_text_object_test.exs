defmodule Minga.Mode.VisualTextObjectTest do
  @moduledoc """
  Tests for visual mode text object selection (viw, vi\", vif, vaf, etc.)
  and the text_object_modifier state machine.
  """
  use ExUnit.Case, async: true

  alias Minga.Mode.Visual
  alias Minga.Mode.VisualState

  defp visual_state(opts \\ []) do
    anchor = Keyword.get(opts, :anchor, {0, 0})
    type = Keyword.get(opts, :type, :char)
    modifier = Keyword.get(opts, :modifier, nil)

    %VisualState{
      visual_anchor: anchor,
      visual_type: type,
      text_object_modifier: modifier
    }
  end

  # ── text_object_modifier state machine ───────────────────────────────────────

  describe "text_object_modifier state machine" do
    test "i sets modifier to :inner" do
      state = visual_state()

      assert {:continue, %VisualState{text_object_modifier: :inner}} =
               Visual.handle_key({?i, 0}, state)
    end

    test "a sets modifier to :around" do
      state = visual_state()

      assert {:continue, %VisualState{text_object_modifier: :around}} =
               Visual.handle_key({?a, 0}, state)
    end

    test "modifier resets to nil after text object dispatch" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, :word}], %VisualState{} = new_state} =
               Visual.handle_key({?w, 0}, state)

      assert new_state.text_object_modifier == nil
    end

    test "i with modifier already set is a no-op (falls through to catch-all)" do
      state = visual_state(modifier: :inner)
      # i with modifier already :inner falls through to the unknown-key
      # handler, which returns {:continue, state} unchanged. This is harmless.
      result = Visual.handle_key({?i, 0}, state)
      assert {:continue, %VisualState{text_object_modifier: :inner}} = result
    end
  end

  # ── Regex text objects in visual mode ────────────────────────────────────────

  describe "regex text objects in visual mode" do
    test "viw selects inner word" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, :word}], %VisualState{}} =
               Visual.handle_key({?w, 0}, state)
    end

    test "vaw selects around word" do
      state = visual_state(modifier: :around)

      assert {:execute, [{:visual_text_object, :around, :word}], %VisualState{}} =
               Visual.handle_key({?w, 0}, state)
    end

    test "vi\" selects inner double-quoted string" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:quote, "\""}}], %VisualState{}} =
               Visual.handle_key({?", 0}, state)
    end

    test "va' selects around single-quoted string" do
      state = visual_state(modifier: :around)

      assert {:execute, [{:visual_text_object, :around, {:quote, "'"}}], %VisualState{}} =
               Visual.handle_key({?', 0}, state)
    end

    test "vi( selects inner parens" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:paren, "(", ")"}}], %VisualState{}} =
               Visual.handle_key({?(, 0}, state)
    end

    test "va) also selects around parens" do
      state = visual_state(modifier: :around)

      assert {:execute, [{:visual_text_object, :around, {:paren, "(", ")"}}], %VisualState{}} =
               Visual.handle_key({?), 0}, state)
    end

    test "vi[ selects inner brackets" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:paren, "[", "]"}}], %VisualState{}} =
               Visual.handle_key({?[, 0}, state)
    end

    test "vi{ selects inner braces" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:paren, "{", "}"}}], %VisualState{}} =
               Visual.handle_key({?{, 0}, state)
    end
  end

  # ── Structural text objects in visual mode ──────────────────────────────────

  describe "structural text objects in visual mode" do
    test "vif selects inner function" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:structural, :function}}], %VisualState{}} =
               Visual.handle_key({?f, 0}, state)
    end

    test "vaf selects around function" do
      state = visual_state(modifier: :around)

      assert {:execute, [{:visual_text_object, :around, {:structural, :function}}],
              %VisualState{}} = Visual.handle_key({?f, 0}, state)
    end

    test "vic selects inner class" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:structural, :class}}], %VisualState{}} =
               Visual.handle_key({?c, 0}, state)
    end

    test "vac selects around class" do
      state = visual_state(modifier: :around)

      assert {:execute, [{:visual_text_object, :around, {:structural, :class}}], %VisualState{}} =
               Visual.handle_key({?c, 0}, state)
    end

    test "via selects inner parameter" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:structural, :parameter}}],
              %VisualState{}} = Visual.handle_key({?a, 0}, state)
    end

    test "vab selects around block" do
      state = visual_state(modifier: :around)

      assert {:execute, [{:visual_text_object, :around, {:structural, :block}}], %VisualState{}} =
               Visual.handle_key({?b, 0}, state)
    end

    test "vib selects inner block" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:structural, :block}}], %VisualState{}} =
               Visual.handle_key({?b, 0}, state)
    end
  end

  # ── Wrap handlers guard on text_object_modifier ─────────────────────────────

  describe "wrap handlers guard on text_object_modifier" do
    test "\" wraps selection when no modifier is pending" do
      state = visual_state(modifier: nil)

      assert {:execute_then_transition, [{:wrap_visual_selection, "\"", "\""}], :normal, _} =
               Visual.handle_key({?", 0}, state)
    end

    test "\" selects text object when :inner modifier is pending" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:quote, "\""}}], _} =
               Visual.handle_key({?", 0}, state)
    end

    test "( wraps selection when no modifier is pending" do
      state = visual_state(modifier: nil)

      assert {:execute_then_transition, [{:wrap_visual_selection, "(", ")"}], :normal, _} =
               Visual.handle_key({?(, 0}, state)
    end

    test "( selects text object when :inner modifier is pending" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:paren, "(", ")"}}], _} =
               Visual.handle_key({?(, 0}, state)
    end

    test "[ wraps selection when no modifier is pending" do
      state = visual_state(modifier: nil)

      assert {:execute_then_transition, [{:wrap_visual_selection, "[", "]"}], :normal, _} =
               Visual.handle_key({?[, 0}, state)
    end

    test "[ selects text object when :around modifier is pending" do
      state = visual_state(modifier: :around)

      assert {:execute, [{:visual_text_object, :around, {:paren, "[", "]"}}], _} =
               Visual.handle_key({?[, 0}, state)
    end

    test "' wraps selection when no modifier is pending" do
      state = visual_state(modifier: nil)

      assert {:execute_then_transition, [{:wrap_visual_selection, "'", "'"}], :normal, _} =
               Visual.handle_key({?', 0}, state)
    end

    test "' selects text object when :inner modifier is pending" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:quote, "'"}}], _} =
               Visual.handle_key({?', 0}, state)
    end

    test "` wraps selection when no modifier is pending" do
      state = visual_state(modifier: nil)

      assert {:execute_then_transition, [{:wrap_visual_selection, "`", "`"}], :normal, _} =
               Visual.handle_key({?`, 0}, state)
    end
  end

  # ── w and b guard on text_object_modifier ──────────────────────────────────

  describe "w and b guard on text_object_modifier" do
    test "w is :word_forward when no modifier" do
      state = visual_state(modifier: nil)
      assert {:execute, :word_forward, _} = Visual.handle_key({?w, 0}, state)
    end

    test "w selects inner word when modifier is :inner" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, :word}], _} =
               Visual.handle_key({?w, 0}, state)
    end

    test "b is :word_backward when no modifier" do
      state = visual_state(modifier: nil)
      assert {:execute, :word_backward, _} = Visual.handle_key({?b, 0}, state)
    end

    test "b selects inner block when modifier is :inner" do
      state = visual_state(modifier: :inner)

      assert {:execute, [{:visual_text_object, :inner, {:structural, :block}}], _} =
               Visual.handle_key({?b, 0}, state)
    end
  end

  # ── = reindent in visual mode ──────────────────────────────────────────────

  describe "= reindent in visual mode" do
    test "= reindents visual selection and transitions to normal" do
      state = visual_state()

      assert {:execute_then_transition, [:reindent_visual_selection], :normal, _} =
               Visual.handle_key({?=, 0}, state)
    end
  end
end
