defmodule MingaEditor.Agent.ProvenanceJumpTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.BufferSync
  alias MingaEditor.Agent.ProvenanceJump

  describe "ProvenanceJump lifecycle" do
    test "request targets a message and starts un-landed" do
      jump = ProvenanceJump.request(42, {"/p/a.ex", 7})
      assert jump.target_message_id == 42
      assert jump.origin == {"/p/a.ex", 7}
      refute jump.landed?
    end

    test "un-landed jumps target the message; landed jumps keep the cursor" do
      jump = ProvenanceJump.request(42)
      assert ProvenanceJump.cursor_target(jump) == {:message_id, 42}

      landed = ProvenanceJump.mark_landed(jump)
      assert landed.landed?
      assert ProvenanceJump.cursor_target(landed) == :keep
    end
  end

  describe "turn_anchor_id/2" do
    # ids are stable message ids; messages are {kind, ...} tuples.
    defp pairs do
      [
        {1, {:user, "add auth"}},
        {2, {:thinking, "use middleware", false}},
        {3, {:assistant, "Adding it."}},
        {4, {:tool_call, %{id: "tc_auth", name: "apply_diff", result: ""}}},
        {5, {:thinking, "now rate limit", false}},
        {6, {:tool_call, %{id: "tc_rate", name: "apply_diff", result: ""}}}
      ]
    end

    test "lands on the user message that opened the turn" do
      assert BufferSync.turn_anchor_id(pairs(), "tc_auth") == 1
    end

    test "falls back to the preceding thinking when the turn had no user prompt" do
      # tc_rate's turn has thinking (id 5) but no user message after id 1's turn;
      # nearest preceding :user is id 1, so it wins (top-down read of the turn).
      assert BufferSync.turn_anchor_id(pairs(), "tc_rate") == 1
    end

    test "uses thinking when there is no preceding user message at all" do
      agent_initiated = [
        {10, {:thinking, "proactive cleanup", false}},
        {11, {:tool_call, %{id: "tc_x", name: "apply_diff", result: ""}}}
      ]

      assert BufferSync.turn_anchor_id(agent_initiated, "tc_x") == 10
    end

    test "falls back to the tool call itself when nothing precedes it" do
      only_tc = [{20, {:tool_call, %{id: "tc_y", name: "apply_diff", result: ""}}}]
      assert BufferSync.turn_anchor_id(only_tc, "tc_y") == 20
    end

    test "returns nil when the tool call is absent" do
      assert BufferSync.turn_anchor_id(pairs(), "tc_missing") == nil
    end
  end

  describe "resolve_cursor_target/5" do
    # display_message_pairs: [{id, msg}] in display order
    # line_offsets: [{display_idx, start_line, line_count}]
    defp display_pairs, do: [{1, {:user, "a"}}, {2, {:assistant, "b"}}, {3, {:user, "c"}}]
    defp offsets, do: [{0, 0, 2}, {1, 3, 4}, {2, 8, 1}]

    test "message_id resolves to the message's start line" do
      assert BufferSync.resolve_cursor_target(
               {:message_id, 3},
               self(),
               display_pairs(),
               offsets(),
               99
             ) ==
               {8, 0}
    end

    test "missing message_id falls back to the bottom (last line)" do
      assert BufferSync.resolve_cursor_target(
               {:message_id, 999},
               self(),
               display_pairs(),
               offsets(),
               99
             ) ==
               {99, 0}
    end

    test "bottom target resolves to the last line" do
      assert BufferSync.resolve_cursor_target({:bottom}, self(), display_pairs(), offsets(), 99) ==
               {99, 0}
    end
  end
end
