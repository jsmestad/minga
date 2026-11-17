defmodule MingaAgent.Session.PortableHistoryTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.PortableHistory
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  test "handoff preserves text, attachment bytes, and paired tool results without native signatures" do
    call = ToolCall.new("call|source-item", "read_file", ~s({"path":"雪.txt"}))
    signed_call = ToolCall.put_metadata(call, %{thought_signature: "private"})
    file = ContentPart.file(<<0, 255>>, "notes.pdf", "application/pdf", %{signature: "private"})
    image = ContentPart.image(<<137, 80, 78, 71>>, "image/png")

    tool_metadata = %{
      is_error: true,
      minga_effect_status: :not_executed,
      tool_output: %{error: "denied"},
      response_id: "private"
    }

    messages = [
      Context.system("instructions"),
      Context.user([ContentPart.text("inspect 雪"), file, image]),
      %Message{
        role: :assistant,
        content: [ContentPart.thinking("private", %{signature: "private"})],
        reasoning_details: [%{signature: "private"}]
      },
      %Message{
        role: :assistant,
        tool_calls: [signed_call],
        metadata: %{responses_replay: %{private: true}}
      },
      %Message{
        role: :tool,
        tool_call_id: call.id,
        content: [ContentPart.text("denied")],
        metadata: tool_metadata
      },
      Context.assistant("No file was changed")
    ]

    assert {:ok, converted, counts} = PortableHistory.convert(messages)
    assert [system, user, assistant, tool, answer] = converted
    assert system == hd(messages)
    assert user.content == [ContentPart.text("inspect 雪"), %{file | metadata: %{}}, image]
    assert assistant.tool_calls == [call]
    assert assistant.metadata == %{}
    assert assistant.reasoning_details == nil
    assert tool.tool_call_id == call.id
    assert tool.content == [ContentPart.text("denied")]
    assert tool.metadata == Map.delete(tool_metadata, :response_id)
    assert answer == List.last(messages)
    assert counts == %{0 => 0, 1 => 1, 2 => 2, 3 => 2, 4 => 3, 5 => 4, 6 => 5}
  end

  test "file references require the same authenticated namespace or inline bytes" do
    reference = ContentPart.owned_file_id("source-file", :openai)
    messages = [Context.user([reference])]
    assert {:error, :unportable_attachment} = PortableHistory.convert(messages)
    assert {:ok, [user], _counts} = PortableHistory.convert(messages, :retain)

    assert ContentPart.provider_file_reference(hd(user.content)) ==
             ContentPart.provider_file_reference(reference)

    inline = %{reference | data: "pdf bytes", filename: "notes.pdf"}
    assert {:ok, [user], _counts} = PortableHistory.convert([Context.user([inline])])
    assert [%ContentPart{data: "pdf bytes", file_id: nil, metadata: %{}}] = user.content
  end

  test "handoff rejects opaque compaction rather than losing substantive context" do
    for type <- ["compaction", :compaction] do
      data = if is_atom(type), do: %{type: "compaction"}, else: %{"type" => type}
      block = ContentPart.provider_block(:openai, data)

      assert {:error, :unportable_compaction} =
               PortableHistory.convert([Context.assistant([block])])
    end
  end

  test "completed exchanges can reuse an ID but incomplete or ambiguous exchanges cannot migrate" do
    call = ToolCall.new("call", "read_file", "{}")
    assistant = %Message{role: :assistant, tool_calls: [call]}
    result = %Message{role: :tool, tool_call_id: call.id, content: [ContentPart.text("found")]}
    assert {:ok, _, _} = PortableHistory.convert([assistant, result, assistant, result])

    for messages <- [
          [assistant],
          [result],
          [assistant, Context.user("next")],
          [%{assistant | tool_calls: [call, call]}, result]
        ] do
      assert {:error, :incomplete_tool_exchange} = PortableHistory.convert(messages)
    end
  end
end
