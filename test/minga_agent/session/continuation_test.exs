defmodule MingaAgent.Session.ContinuationTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.ContinuationCodec
  alias MingaAgent.Session.Outcome
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.ToolCall

  test "codec preserves attachments, provider-native blocks, tool groups, and reasoning signatures" do
    reasoning = %ReasoningDetails{
      text: "private reasoning",
      signature: <<0, 1, 255>>,
      encrypted?: true,
      provider: :anthropic,
      format: "anthropic-v1",
      index: 2,
      provider_data: %{"redacted_thinking" => <<3, 4, 5>>}
    }

    tool_call = ToolCall.new("call-1", "read_file", ~s({"path":"README.md"}))

    messages = [
      Context.system("system"),
      Context.user([
        ContentPart.text("inspect"),
        ContentPart.image(<<0, 255, 10>>, "image/png"),
        ContentPart.owned_file_id("file-1", :anthropic,
          media_type: "application/pdf",
          provider_metadata: %{"signature" => <<7, 8>>}
        )
      ]),
      %Message{
        role: :assistant,
        content: [
          ContentPart.text("working"),
          ContentPart.provider_block(
            :anthropic,
            %{"type" => "server_tool_use", "signature" => <<9, 0, 9>>}
          )
        ],
        tool_calls: [tool_call],
        reasoning_details: [reasoning]
      },
      Context.tool_result_message("read_file", "call-1", "contents", %{is_error: false})
    ]

    branch = %{messages: messages, boundaries: []}

    assert {:ok, continuation} =
             Continuation.restore(messages, 4, 4, [], %{"branch" => branch}, :lossless)

    assert {:ok, restored} =
             continuation |> ContinuationCodec.encode() |> ContinuationCodec.decode()

    assert restored.messages == messages
    assert restored.branch_messages == %{"branch" => branch}
  end

  test "codec restores the exact active request after a process interruption" do
    assert {:ok, request, continuation} =
             Continuation.begin_request(Continuation.new(), "request-in-flight", 7, [
               ContentPart.text("continue this prompt"),
               ContentPart.image(<<0, 255>>, "image/png")
             ])

    assert {:ok, restored} =
             continuation |> ContinuationCodec.encode() |> ContinuationCodec.decode()

    assert restored.active_request == request
    assert restored.active_request.messages == request.messages
    assert Continuation.interrupt_request(restored).messages == request.messages
  end

  test "stale and duplicate outcomes cannot replace a newer boundary" do
    continuation = Continuation.new()

    assert {:ok, request, continuation} =
             Continuation.begin_request(continuation, "request-1", 1, "hello")

    outcome =
      Outcome.new(request, Enum.concat(request.messages, [Context.assistant("answer")]))

    assert {:ok, completed} = Continuation.complete(continuation, outcome, 2)
    assert {:error, :duplicate_outcome} = Continuation.complete(completed, outcome, 2)

    assert {:ok, request2, active} =
             Continuation.begin_request(completed, "request-2", 3, "newer")

    assert {:error, :stale_outcome} = Continuation.complete(active, outcome, 4)

    outcome2 =
      Outcome.new(
        request2,
        Enum.concat(request2.messages, [Context.assistant("new answer")])
      )

    assert {:ok, newest} = Continuation.complete(active, outcome2, 4)
    assert newest.messages == outcome2.messages
  end

  test "outcomes cannot rewrite their immutable request prefix" do
    assert {:ok, request, continuation} =
             Continuation.begin_request(Continuation.new(), "request-prefix", 5, "original")

    outcome =
      Outcome.new(request, [
        Context.user("rewritten"),
        Context.assistant("answer")
      ])

    assert {:error, :invalid_checkpoint_progression} =
             Continuation.complete(continuation, outcome, 6)
  end

  test "interrupted requests remain in the next continuation request" do
    assert {:ok, request, continuation} =
             Continuation.begin_request(Continuation.new(), "request-interrupted", 7, "original")

    interrupted = Continuation.interrupt_request(continuation)
    assert interrupted.active_request == nil
    assert interrupted.messages == request.messages
    assert [%{transcript_id: 7}] = interrupted.boundaries

    assert {:ok, resumed, _continuation} =
             Continuation.begin_request(interrupted, "request-resumed", 8, "continue")

    assert resumed.messages == Enum.concat(request.messages, [Context.user("continue")])
  end

  test "structured provider content is preserved in a completed continuation" do
    continuation = Continuation.new()

    assert {:ok, request, active} =
             Continuation.begin_request(continuation, "request-structured", 1, "hello")

    structured = %{type: :object, object: %{"answer" => "ok"}}
    response = %Message{role: :assistant, content: [structured]}
    outcome = Outcome.new(request, Enum.concat(request.messages, [response]))

    assert {:ok, completed} = Continuation.complete(active, outcome, 2)
    assert completed.messages == outcome.messages
    assert {:ok, restored} = completed |> ContinuationCodec.encode() |> ContinuationCodec.decode()
    assert restored.messages == completed.messages
  end

  test "branch switching restores the saved model boundaries before a later branch" do
    messages = [
      Context.system("system"),
      Context.user("first"),
      Context.assistant("first answer"),
      Context.user("second"),
      Context.assistant("second answer")
    ]

    boundaries = [
      %{transcript_id: 3, message_count: 3, revision: 1},
      %{transcript_id: 5, message_count: 5, revision: 2}
    ]

    assert {:ok, continuation} =
             Continuation.restore(messages, 2, 2, boundaries, %{}, :lossless)

    assert {:error, :branch_not_resumable} =
             Continuation.branch_at(continuation, "between-boundaries", 4)

    assert {:ok, early_branch} = Continuation.branch_at(continuation, "early", 3)
    assert early_branch.messages == Enum.take(messages, 3)

    assert {:ok, restored_branch} = Continuation.switch_branch(early_branch, "early")
    assert restored_branch.messages == messages
    assert restored_branch.boundaries == boundaries

    assert {:ok, later_branch} = Continuation.branch_at(restored_branch, "later", 5)
    assert later_branch.messages == messages
  end

  test "v2 codec rejects malformed ReqLLM message fields" do
    malformed_messages = [
      %Message{role: :ok, content: []},
      %Message{role: :user, content: [], name: 7}
    ]

    Enum.each(malformed_messages, fn message ->
      continuation = %{Continuation.new() | messages: [message]}
      encoded = ContinuationCodec.encode(continuation)

      assert {:error, :invalid_message} = ContinuationCodec.decode(encoded)
    end)
  end

  test "v2 codec rejects a tool checkpoint without its active request" do
    checkpoint = %{
      version: 1,
      checkpoint_id: "checkpoint-orphan",
      request_id: "request-orphan",
      messages: [Context.user("prompt"), Context.assistant("tool call")],
      calls: [
        %{
          tool_call_id: "call-1",
          name: "read_file",
          arguments: %{},
          status: :pending
        }
      ]
    }

    continuation = %{Continuation.new() | tool_checkpoint: checkpoint}

    assert {:error, :invalid_active_request} =
             continuation
             |> ContinuationCodec.encode()
             |> ContinuationCodec.decode()
  end

  test "missing inline attachment data is rejected rather than invented" do
    missing = %Message{
      role: :user,
      content: [%ContentPart{type: :image, data: nil, media_type: "image/png"}]
    }

    assert {:error, :invalid_attachment} =
             Continuation.restore([missing], 1, 1, [], %{}, :lossless)
  end

  test "legacy import is visibly lossy and copies only portable text" do
    display = [
      {:user, "hello", [%{filename: "missing.png"}]},
      {:assistant, "answer"},
      {:thinking, "hidden", true}
    ]

    continuation = Continuation.import_legacy(display)
    assert continuation.provenance == :legacy_reconstructed
    assert continuation.messages == [Context.user("hello"), Context.assistant("answer")]
  end

  test "checkpoint accepts the Native provider system prompt before the durable request" do
    {:ok, request, continuation} =
      Continuation.begin_request(Continuation.new(), "request-system-prefix", 3, [
        Context.user("inspect")
      ])

    assistant = %Message{
      role: :assistant,
      tool_calls: [ToolCall.new("call-system-prefix", "read_file", ~s({"path":"a"}))]
    }

    messages =
      Enum.concat([Context.system("native system prompt") | request.messages], [assistant])

    assert {:ok, _checkpoint_id, _checkpointed} =
             Continuation.checkpoint_tool_group(
               continuation,
               request.request_id,
               messages,
               [
                 %{
                   tool_call_id: "call-system-prefix",
                   name: "read_file",
                   arguments: %{"path" => "a"}
                 }
               ]
             )
  end

  test "checkpoint recovery preserves the exact assistant group and never re-admits an ambiguous call" do
    {:ok, request, continuation} =
      Continuation.begin_request(Continuation.new(), "request-checkpoint", 7, [
        ContentPart.text("inspect"),
        ContentPart.image(<<0, 255, 10>>, "image/png")
      ])

    reasoning = %ReasoningDetails{
      text: "provider reasoning",
      signature: <<9, 0, 9>>,
      encrypted?: true,
      provider: :anthropic,
      format: "anthropic-v1",
      index: 1,
      provider_data: %{"opaque" => <<1, 2, 255>>}
    }

    assistant = %Message{
      role: :assistant,
      content: [
        ContentPart.provider_block(:anthropic, %{
          "type" => "server_tool_use",
          "signature" => <<4, 5, 0>>
        })
      ],
      metadata: %{response_id: "response-checkpoint", phase: :analysis},
      tool_calls: [
        ToolCall.new("call-1", "write_file", ~s({"path":"a","content":"b"})),
        ToolCall.new("call-2", "read_file", ~s({"path":"a"}))
      ],
      reasoning_details: [reasoning]
    }

    calls = [
      %{
        tool_call_id: "call-1",
        name: "write_file",
        arguments: %{"path" => "a", "content" => "b"}
      },
      %{tool_call_id: "call-2", name: "read_file", arguments: %{"path" => "a"}}
    ]

    assert {:ok, checkpoint_id, checkpointed} =
             Continuation.checkpoint_tool_group(
               continuation,
               request.request_id,
               Enum.concat(request.messages, [assistant]),
               calls
             )

    assert {:ok, admitted} =
             Continuation.admit_tool_effect(
               checkpointed,
               request.request_id,
               checkpoint_id,
               "call-1",
               "write_file",
               %{"path" => "a", "content" => "b"}
             )

    assert {:error, :duplicate_admission} =
             Continuation.admit_tool_effect(
               admitted,
               request.request_id,
               checkpoint_id,
               "call-1",
               "write_file",
               %{"path" => "a", "content" => "b"}
             )

    read_result =
      Context.tool_result_message("read_file", "call-2", "b", %{is_error: false})

    wrong_result =
      Context.tool_result_message("write_file", "wrong-id", "b", %{is_error: false})

    assert {:error, :tool_result_identity_mismatch} =
             Continuation.complete_tool_effect(
               admitted,
               request.request_id,
               checkpoint_id,
               "call-2",
               wrong_result
             )

    assert {:ok, partially_completed} =
             Continuation.complete_tool_effect(
               admitted,
               request.request_id,
               checkpoint_id,
               "call-2",
               read_result
             )

    assert {:ok, restored} =
             partially_completed |> ContinuationCodec.encode() |> ContinuationCodec.decode()

    assert restored.tool_checkpoint.messages ==
             Enum.concat(request.messages, [assistant])

    {reconciled, statuses} = Continuation.reconcile_interrupted(restored, 11)

    indeterminate_result =
      Context.tool_result_message(
        "write_file",
        "call-1",
        "Tool effect outcome is indeterminate after interruption. The call was not rerun.",
        %{is_error: true, minga_effect_status: :indeterminate}
      )

    assert statuses == [
             %{
               tool_call_id: "call-1",
               name: "write_file",
               status: :indeterminate,
               result_message: indeterminate_result
             },
             %{
               tool_call_id: "call-2",
               name: "read_file",
               status: :completed,
               result_message: read_result
             }
           ]

    assert Enum.at(reconciled.messages, -3) === assistant

    assert reconciled.messages ==
             Enum.concat(restored.tool_checkpoint.messages, [indeterminate_result, read_result])

    assert reconciled.tool_checkpoint == nil

    assert {:ok, recovered_branch} =
             Continuation.branch_at(reconciled, "recovered", 11)

    assert recovered_branch.messages == reconciled.messages

    assert {:ok, next_request, _continuation} =
             Continuation.begin_request(reconciled, "request-next", 8, "continue safely")

    assert Enum.at(next_request.messages, -4) === assistant
    assert Enum.at(next_request.messages, -3).metadata.minga_effect_status == :indeterminate
  end
end
