defmodule Minga.Mode.SearchTest do
  use ExUnit.Case, async: true

  alias Minga.Mode.Search
  alias Minga.Mode.SearchState

  defp state(opts) do
    %SearchState{
      direction: Keyword.get(opts, :direction, :forward),
      input: Keyword.get(opts, :input, ""),
      original_cursor: Keyword.get(opts, :original_cursor, {0, 0})
    }
  end

  describe "Enter key" do
    test "with non-empty input confirms search and transitions to normal" do
      s = state(input: "hello")

      assert {:execute_then_transition, [:confirm_search], :normal, _} =
               Search.handle_key({13, 0}, s)
    end

    test "with empty input transitions to normal without command" do
      s = state(input: "")
      assert {:transition, :normal, _} = Search.handle_key({13, 0}, s)
    end
  end

  describe "Escape key" do
    test "cancels search and transitions to normal" do
      s = state(input: "hello")

      assert {:execute_then_transition, [:cancel_search], :normal, _} =
               Search.handle_key({27, 0}, s)
    end
  end

  describe "Backspace" do
    test "removes last character and triggers incremental search" do
      s = state(input: "hel")

      assert {:execute, :incremental_search, %SearchState{input: "he"}} =
               Search.handle_key({127, 0}, s)
    end

    test "on empty input cancels search" do
      s = state(input: "")

      assert {:execute_then_transition, [:cancel_search], :normal, _} =
               Search.handle_key({127, 0}, s)
    end

    test "deleting to empty triggers incremental search" do
      s = state(input: "x")

      assert {:execute, :incremental_search, %SearchState{input: ""}} =
               Search.handle_key({127, 0}, s)
    end
  end

  describe "printable characters" do
    test "appends character and triggers incremental search" do
      s = state(input: "hel")

      assert {:execute, :incremental_search, %SearchState{input: "hell"}} =
               Search.handle_key({?l, 0}, s)
    end

    test "starts accumulation from empty" do
      s = state(input: "")

      assert {:execute, :incremental_search, %SearchState{input: "h"}} =
               Search.handle_key({?h, 0}, s)
    end
  end

  describe "direction" do
    test "preserves forward direction" do
      s = state(direction: :forward, input: "")
      {:execute, :incremental_search, new_s} = Search.handle_key({?a, 0}, s)
      assert new_s.direction == :forward
    end

    test "preserves backward direction" do
      s = state(direction: :backward, input: "")
      {:execute, :incremental_search, new_s} = Search.handle_key({?a, 0}, s)
      assert new_s.direction == :backward
    end
  end

  describe "ignored keys" do
    test "arrow keys are ignored" do
      s = state(input: "test")
      assert {:continue, ^s} = Search.handle_key({57_352, 0}, s)
      assert {:continue, ^s} = Search.handle_key({57_353, 0}, s)
    end
  end
end
