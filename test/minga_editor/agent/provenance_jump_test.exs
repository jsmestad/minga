defmodule MingaEditor.Agent.ProvenanceJumpTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.ProvenanceJump
  alias MingaEditor.Agent.Transcript

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
      assert Transcript.turn_anchor_id(pairs(), "tc_auth") == 1
    end

    test "falls back to the preceding thinking when the turn had no user prompt" do
      # tc_rate's turn has thinking (id 5) but no user message after id 1's turn;
      # nearest preceding :user is id 1, so it wins (top-down read of the turn).
      assert Transcript.turn_anchor_id(pairs(), "tc_rate") == 1
    end

    test "uses thinking when there is no preceding user message at all" do
      agent_initiated = [
        {10, {:thinking, "proactive cleanup", false}},
        {11, {:tool_call, %{id: "tc_x", name: "apply_diff", result: ""}}}
      ]

      assert Transcript.turn_anchor_id(agent_initiated, "tc_x") == 10
    end

    test "falls back to the tool call itself when nothing precedes it" do
      only_tc = [{20, {:tool_call, %{id: "tc_y", name: "apply_diff", result: ""}}}]
      assert Transcript.turn_anchor_id(only_tc, "tc_y") == 20
    end

    test "returns nil when the tool call is absent" do
      assert Transcript.turn_anchor_id(pairs(), "tc_missing") == nil
    end
  end
end
