defmodule Minga.Editor.MinibufferDataTest do
  @moduledoc """
  Tests for MinibufferData.from_state/1 and complete_ex_command/1.

  Uses lightweight input maps (not full EditorState) since from_state
  pattern-matches on %{workspace: %{vim: %{mode: ..., mode_state: ...}}.

  Tests against the real CommandRegistry (started by the application) so
  completion candidates reflect actual editor commands.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.MinibufferData

  describe "clamp_index/2" do
    test "returns 0 for empty list" do
      assert MinibufferData.clamp_index(5, 0) == 0
      assert MinibufferData.clamp_index(-3, 0) == 0
    end

    test "wraps positive overflow" do
      assert MinibufferData.clamp_index(3, 3) == 0
      assert MinibufferData.clamp_index(4, 3) == 1
    end

    test "wraps negative underflow" do
      assert MinibufferData.clamp_index(-1, 3) == 2
      assert MinibufferData.clamp_index(-2, 3) == 1
    end

    test "passes through valid indices" do
      assert MinibufferData.clamp_index(0, 5) == 0
      assert MinibufferData.clamp_index(2, 5) == 2
      assert MinibufferData.clamp_index(4, 5) == 4
    end
  end

  describe "from_state/1 command mode" do
    test "returns visible struct with correct fields" do
      state = %{
        workspace: %{vim: %{mode: :command, mode_state: %{input: "wri", candidate_index: 0}}}
      }

      result = MinibufferData.from_state(state)

      assert result.visible == true
      assert result.mode == 0
      assert result.prompt == ":"
      assert result.input == "wri"
      assert result.cursor_pos == 3
    end

    test "reads candidate_index from mode_state" do
      state = %{
        workspace: %{vim: %{mode: :command, mode_state: %{input: "qui", candidate_index: 1}}}
      }

      result = MinibufferData.from_state(state)

      # candidate_index 1 should be clamped and set as selected_index
      assert result.selected_index == 1
    end

    test "generates completion candidates for non-empty input" do
      state = %{
        workspace: %{vim: %{mode: :command, mode_state: %{input: "sav", candidate_index: 0}}}
      }

      result = MinibufferData.from_state(state)

      assert result.candidates != []
      labels = Enum.map(result.candidates, & &1.label)
      assert "save" in labels
    end

    test "empty input returns candidates (popular commands)" do
      state = %{
        workspace: %{vim: %{mode: :command, mode_state: %{input: "", candidate_index: 0}}}
      }

      result = MinibufferData.from_state(state)

      assert result.candidates != []
    end
  end

  describe "from_state/1 search modes" do
    test "search forward sets mode 1 and prompt /" do
      state = %{
        workspace: %{vim: %{mode: :search, mode_state: %{direction: :forward, input: "pattern"}}}
      }

      result = MinibufferData.from_state(state)

      assert result.visible == true
      assert result.mode == 1
      assert result.prompt == "/"
      assert result.input == "pattern"
      assert result.cursor_pos == 7
      assert result.candidates == []
    end

    test "search backward sets mode 2 and prompt ?" do
      state = %{
        workspace: %{vim: %{mode: :search, mode_state: %{direction: :backward, input: "test"}}}
      }

      result = MinibufferData.from_state(state)

      assert result.mode == 2
      assert result.prompt == "?"
    end

    test "search context formats match count correctly" do
      state = %{
        workspace: %{
          vim: %{
            mode: :search,
            mode_state: %{direction: :forward, input: "x", match_count: 42, current_match: 2}
          }
        }
      }

      result = MinibufferData.from_state(state)

      assert result.context == "3 of 42"
    end

    test "search context shows 'no matches' when match_count is 0" do
      state = %{
        workspace: %{
          vim: %{mode: :search, mode_state: %{direction: :forward, input: "x", match_count: 0}}
        }
      }

      result = MinibufferData.from_state(state)

      assert result.context == "no matches"
    end

    test "search context is empty when match_count is nil" do
      state = %{
        workspace: %{vim: %{mode: :search, mode_state: %{direction: :forward, input: "x"}}}
      }

      result = MinibufferData.from_state(state)

      assert result.context == ""
    end
  end

  describe "from_state/1 substitute confirm" do
    test "formats prompt and context from mode_state" do
      state = %{
        workspace: %{
          vim: %{
            mode: :substitute_confirm,
            mode_state: %{matches: [1, 2, 3], current: 1, replacement: "foo"}
          }
        }
      }

      result = MinibufferData.from_state(state)

      assert result.visible == true
      assert result.mode == 5
      assert result.cursor_pos == 0xFFFF
      assert result.prompt == "replace with foo?"
      assert result.context == "y/n/a/q (2 of 3)"
      assert result.candidates == []
    end
  end

  describe "from_state/1 describe key" do
    test "accumulates pressed keys into context" do
      state = %{
        workspace: %{
          vim: %{
            mode: :normal,
            mode_state: %{pending_describe_key: true, describe_key_keys: ["b", "SPC"]}
          }
        }
      }

      result = MinibufferData.from_state(state)

      assert result.visible == true
      assert result.mode == 7
      assert result.cursor_pos == 0xFFFF
      assert result.prompt == "Press key to describe:"
      assert result.context == "SPC b …"
    end

    test "empty keys gives empty context" do
      state = %{
        workspace: %{
          vim: %{
            mode: :normal,
            mode_state: %{pending_describe_key: true, describe_key_keys: []}
          }
        }
      }

      result = MinibufferData.from_state(state)

      assert result.context == ""
    end
  end

  describe "from_state/1 fallthrough" do
    test "normal mode without describe_key returns hidden" do
      state = %{workspace: %{vim: %{mode: :normal, mode_state: %{}}}}
      result = MinibufferData.from_state(state)

      assert result.visible == false
    end

    test "insert mode returns hidden" do
      state = %{workspace: %{vim: %{mode: :insert, mode_state: %{}}}}
      result = MinibufferData.from_state(state)

      assert result.visible == false
    end
  end

  describe "complete_ex_command/1 scoring" do
    test "exact match ranks first" do
      {candidates, _total} = MinibufferData.complete_ex_command("save")
      labels = Enum.map(candidates, & &1.label)

      # "save" should be first (exact match scores highest)
      assert hd(labels) == "save"
    end

    test "prefix matches rank above substring matches" do
      # "quit" is a prefix match for "quit"; "force_quit" contains "quit" as substring
      {candidates, _total} = MinibufferData.complete_ex_command("quit")
      labels = Enum.map(candidates, & &1.label)

      quit_idx = Enum.find_index(labels, &(&1 == "quit"))
      force_quit_idx = Enum.find_index(labels, &(&1 == "force_quit"))

      assert quit_idx != nil
      assert force_quit_idx != nil
      assert quit_idx < force_quit_idx
    end

    test "no match returns empty list" do
      {candidates, _total} = MinibufferData.complete_ex_command("zzzzzzxyz")
      assert candidates == []
    end

    test "shorter names rank higher within same tier" do
      # Both "quit" and "quit_all" are prefix matches for "qui"
      {candidates, _total} = MinibufferData.complete_ex_command("qui")
      labels = Enum.map(candidates, & &1.label)

      quit_idx = Enum.find_index(labels, &(&1 == "quit"))
      quit_all_idx = Enum.find_index(labels, &(&1 == "quit_all"))

      assert quit_idx != nil
      assert quit_all_idx != nil
      assert quit_idx < quit_all_idx
    end

    test "candidates capped at 15" do
      {candidates, _total} = MinibufferData.complete_ex_command("")
      assert length(candidates) <= 15
    end

    test "all candidates have required fields" do
      {candidates, _total} = MinibufferData.complete_ex_command("save")

      for c <- candidates do
        assert is_binary(c.label)
        assert is_binary(c.description)
        assert is_integer(c.match_score)
        assert c.match_score >= 0 and c.match_score <= 255
      end
    end

    test "match_positions reflect matched character indices for exact match" do
      {candidates, _total} = MinibufferData.complete_ex_command("save")
      save = Enum.find(candidates, &(&1.label == "save"))
      assert save != nil
      # Exact match: all 4 characters at positions 0-3
      assert save.match_positions == [0, 1, 2, 3]
    end

    test "match_positions for partial query show correct indices" do
      {candidates, _total} = MinibufferData.complete_ex_command("sa")
      save = Enum.find(candidates, &(&1.label == "save"))
      assert save != nil
      assert save.match_positions == [0, 1]
    end

    test "annotation is a string on every candidate" do
      {candidates, _total} = MinibufferData.complete_ex_command("save")

      for c <- candidates do
        assert is_binary(c.annotation)
      end
    end

    test "total_candidates reflects uncapped match count" do
      {candidates, total} = MinibufferData.complete_ex_command("")
      # Empty query returns popular commands (capped at 15)
      assert length(candidates) <= 15
      # Total should be >= candidates since it's the uncapped count
      assert total >= length(candidates)
    end
  end
end
