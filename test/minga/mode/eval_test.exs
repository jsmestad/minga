defmodule Minga.Mode.EvalTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Mode.Eval
  alias Minga.Mode.EvalState

  @enter 13
  @escape 27

  defp fresh_state(input \\ ""), do: %EvalState{input: input}

  # ── Typing characters ────────────────────────────────────────────────────────

  describe "typing printable characters" do
    test "typing a letter appends it to input" do
      assert {:continue, %{input: "x"}} = Eval.handle_key({?x, 0}, fresh_state())
    end

    test "successive characters accumulate in input" do
      {:continue, s1} = Eval.handle_key({?1, 0}, fresh_state())
      {:continue, s2} = Eval.handle_key({?+, 0}, s1)
      {:continue, s3} = Eval.handle_key({?1, 0}, s2)
      assert s3.input == "1+1"
    end

    test "typing a space appends it to input" do
      assert {:continue, %{input: "1 "}} = Eval.handle_key({?\s, 0}, fresh_state("1"))
    end
  end

  # ── Backspace ────────────────────────────────────────────────────────────────

  describe "Backspace (DEL 127)" do
    test "removes last character from a non-empty input" do
      assert {:continue, %{input: "1+"}} = Eval.handle_key({127, 0}, fresh_state("1+1"))
    end

    test "backspace on single-char input transitions to normal" do
      assert {:transition, :normal, %{input: ""}} = Eval.handle_key({127, 0}, fresh_state("x"))
    end

    test "backspace on empty input transitions to normal" do
      assert {:transition, :normal, _} = Eval.handle_key({127, 0}, fresh_state())
    end
  end

  # ── Enter ────────────────────────────────────────────────────────────────────

  describe "Enter" do
    test "evaluates expression and transitions to normal" do
      assert {:execute_then_transition, [{:eval_expression, "1 + 1"}], :normal, %{input: ""}} =
               Eval.handle_key({@enter, 0}, fresh_state("1 + 1"))
    end

    test "enter on empty input transitions to normal without evaluating" do
      assert {:transition, :normal, %{input: ""}} =
               Eval.handle_key({@enter, 0}, fresh_state())
    end
  end

  # ── Escape ───────────────────────────────────────────────────────────────────

  describe "Escape" do
    test "cancels eval and transitions to normal" do
      assert {:transition, :normal, %{input: ""}} =
               Eval.handle_key({@escape, 0}, fresh_state("some code"))
    end

    test "escape on empty input transitions to normal" do
      assert {:transition, :normal, %{input: ""}} =
               Eval.handle_key({@escape, 0}, fresh_state())
    end
  end

  # ── Ignored keys ─────────────────────────────────────────────────────────────

  describe "ignored keys" do
    test "arrow keys are ignored" do
      state = fresh_state("test")
      assert {:continue, ^state} = Eval.handle_key({57_352, 0}, state)
      assert {:continue, ^state} = Eval.handle_key({57_353, 0}, state)
    end

    test "control sequences are ignored" do
      state = fresh_state("test")
      assert {:continue, ^state} = Eval.handle_key({?a, 0x02}, state)
    end
  end
end
