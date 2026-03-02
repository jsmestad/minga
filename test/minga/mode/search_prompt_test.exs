defmodule Minga.Mode.SearchPromptTest do
  use ExUnit.Case, async: true

  alias Minga.Mode.SearchPrompt
  alias Minga.Mode.SearchPromptState

  defp state(input \\ ""), do: %SearchPromptState{input: input}

  describe "handle_key/2" do
    test "Enter with empty input transitions to normal" do
      assert {:transition, :normal, _} = SearchPrompt.handle_key({13, 0}, state())
    end

    test "Enter with input confirms project search and transitions to normal" do
      assert {:execute_then_transition, [:confirm_project_search], :normal, %{input: "foo"}} =
               SearchPrompt.handle_key({13, 0}, state("foo"))
    end

    test "Escape transitions to normal and clears input" do
      assert {:transition, :normal, %{input: ""}} =
               SearchPrompt.handle_key({27, 0}, state("foo"))
    end

    test "Backspace on empty input transitions to normal" do
      assert {:transition, :normal, _} = SearchPrompt.handle_key({127, 0}, state())
    end

    test "Backspace removes last character" do
      assert {:continue, %{input: "fo"}} = SearchPrompt.handle_key({127, 0}, state("foo"))
    end

    test "printable character appends to input" do
      assert {:continue, %{input: "f"}} = SearchPrompt.handle_key({?f, 0}, state())
      assert {:continue, %{input: "fo"}} = SearchPrompt.handle_key({?o, 0}, state("f"))
    end

    test "ignores arrow keys" do
      assert {:continue, _} = SearchPrompt.handle_key({57_352, 0}, state("foo"))
    end
  end
end
