defmodule Minga.Mode.EnterChordsTest do
  @moduledoc """
  In a prompt that submits typed text, Enter held with Control, Alt or Command is not bound, so it does nothing.

  Without enhanced key reporting a terminal sends Esc followed by Enter as Alt+Enter when both arrive together. A person who pressed Esc to drop what they typed must not have it submitted.
  """

  use ExUnit.Case, async: true

  alias Minga.Mode.Eval
  alias Minga.Mode.EvalState
  alias Minga.Mode.Search
  alias Minga.Mode.SearchPrompt
  alias Minga.Mode.SearchPromptState
  alias Minga.Mode.SearchState

  @enter 13
  @chords [{0x02, "Control"}, {0x04, "Alt"}, {0x08, "Command"}, {0x05, "Alt and Shift"}]

  defp cases do
    [
      {Eval, %EvalState{input: "1 + 1"}},
      {Eval, %EvalState{input: ""}},
      {Search, %SearchState{direction: :forward, input: "needle", original_cursor: {0, 0}}},
      {Search, %SearchState{direction: :forward, input: "", original_cursor: {0, 0}}},
      {SearchPrompt, %SearchPromptState{input: "needle"}},
      {SearchPrompt, %SearchPromptState{input: ""}}
    ]
  end

  test "Enter held with a chord modifier submits nothing and leaves the prompt as it is" do
    for {mode, state} <- cases(), {mods, name} <- @chords do
      assert {:continue, ^state} = mode.handle_key({@enter, mods}, state),
             "#{inspect(mode)} with input #{inspect(state.input)}: #{name}+Enter must do nothing"
    end
  end

  test "plain Enter and Shift+Enter still submit or leave" do
    for {mode, state} <- cases(), mods <- [0x00, 0x01] do
      refute match?({:continue, _state}, mode.handle_key({@enter, mods}, state)),
             "#{inspect(mode)} with input #{inspect(state.input)}: Enter must act"
    end
  end
end
