defmodule Minga.Frontend.Adapter.GUI.SubagentPeekEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.{AgentTranscriptEncoder, Caches, SubagentPeekEncoder}
  alias Minga.Frontend.Adapter.GUI.SubagentPeekTranscriptEncoder
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.{AgentChat, SubagentPeek}

  test "the same message ID in a sibling cannot reuse the previous child's wire base" do
    first = model("child-a", [{1, {:user, "first"}}])
    second = model("child-b", [{1, {:user, "second"}}])

    parent = %AgentChat{
      visible?: true,
      transcript_epoch: 9,
      resident_messages: [{1, {:user, "parent"}}]
    }

    {_, caches} = AgentTranscriptEncoder.encode(parent, Caches.new())
    parent_base = caches.last_agent_transcript
    opcode = Opcodes.gui_subagent_peek_transcript()

    {initial, caches} = SubagentPeekTranscriptEncoder.encode(first, caches)
    assert <<^opcode, _bytes::32, 1, 0, 9::32, _::binary>> = initial
    assert {nil, ^caches} = SubagentPeekTranscriptEncoder.encode(first, caches)

    running = model("child-a", [{1, {:user, "first"}}, {2, {:assistant, "partial"}}])
    {delta, caches} = SubagentPeekTranscriptEncoder.encode(running, caches)
    assert <<^opcode, _bytes::32, 1, 1, 9::32, _::binary>> = delta

    {replacement, caches} = SubagentPeekTranscriptEncoder.encode(second, caches)
    assert <<^opcode, _bytes::32, 1, 0, 9::32, _::binary>> = replacement
    assert caches.last_agent_transcript == parent_base
  end

  test "a closed peek retains parent steps but emits no child transcript" do
    model = %SubagentPeek{
      parent_window_id: 7,
      steps: [{42, "token", "Started Audit", "1 of 2 reports in"}]
    }

    opcode = Opcodes.gui_subagent_peek()
    {frame, caches} = SubagentPeekEncoder.encode(model, Caches.new())
    assert <<^opcode, _size::32, 7::16, 1::16, 42::32, 5::16, "token", _::binary>> = frame
    assert {nil, ^caches} = SubagentPeekEncoder.encode(model, caches)
    assert {nil, ^caches} = SubagentPeekTranscriptEncoder.encode(model, caches)
  end

  defp model(token, messages) do
    %SubagentPeek{pane: %{token: token}, transcript: {9, messages, false}}
  end
end
