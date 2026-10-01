defmodule MingaAgent.Providers.Native.ReqLLMAdapterTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.ModelSelection.Credential.ApiKey
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias ReqLLM.StreamResponse.MetadataHandle

  defp build_stream_response(chunks, usage \\ %{}, response_metadata \\ %{}) do
    metadata = Map.merge(%{usage: usage, finish_reason: :stop}, response_metadata)
    {:ok, handle} = MetadataHandle.start_link(fn -> metadata end)

    %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: ModelSelectionFixture.selection().request_model,
      context: ReqLLM.Context.new()
    }
  end

  test "builds request-local credential, cache, token, and reasoning options" do
    config = %AgentConfig{prompt_cache: true}
    selection = selection()

    assert {:ok, opts} =
             ReqLLMAdapter.stream_opts(
               selection,
               [],
               config,
               env: %{"ANTHROPIC_API_KEY" => "request-secret"}
             )

    assert opts[:tools] == []
    assert opts[:max_tokens] == 4_096
    refute Keyword.has_key?(opts, :base_url)
    assert opts[:auth_mode] == :api_key
    assert opts[:api_key] == "request-secret"
    assert opts[:provider_options][:anthropic_prompt_cache] == true
    assert opts[:provider_options][:anthropic_cache_messages] == true
    assert opts[:reasoning_effort] == :high

    assert {:error, {:credential_unavailable, "anthropic:env"}} =
             ReqLLMAdapter.stream_opts(selection, [], config, env: %{"OPENAI_API_KEY" => "other"})
  end

  test "cache options follow the executing protocol rather than the model source owner" do
    for {request_provider, owner, expected_cache?} <- [
          {:anthropic, "local", true},
          {:openai, "anthropic", false}
        ] do
      selection =
        ModelSelectionFixture.selection(request_provider: request_provider, model_provider: owner)

      assert {:ok, opts} =
               ReqLLMAdapter.stream_opts(selection, [], %AgentConfig{prompt_cache: true})

      assert get_in(opts, [:provider_options, :anthropic_prompt_cache]) == true == expected_cache?
    end
  end

  test "compaction cannot exceed the active model output budget" do
    parent = self()

    selection =
      ModelSelectionFixture.selection(
        limits: %{context: 2_000, input: nil, output: 100, request_output: 80}
      )

    client = fn _model, _messages, opts ->
      send(parent, {:summary_budget, opts[:max_tokens]})
      {:ok, build_stream_response([ReqLLM.StreamChunk.text("summary")])}
    end

    summary = ReqLLMAdapter.summary_client(client, selection, %AgentConfig{})
    assert {:ok, "summary"} = summary.(nil, [], max_tokens: 4_096)
    assert_receive {:summary_budget, 80}
    assert {:ok, "summary"} = summary.(nil, [], max_tokens: 40)
    assert_receive {:summary_budget, 40}
  end

  test "processes streaming text, thinking, tool calls, and usage into neutral turn data" do
    parent = self()

    stream_response =
      build_stream_response(
        [
          ReqLLM.StreamChunk.text("hello"),
          ReqLLM.StreamChunk.thinking("thinking"),
          ReqLLM.StreamChunk.tool_call("grep", %{"pattern" => "needle"}, %{id: "tc_1"}),
          ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
        ],
        %{input_tokens: 10, output_tokens: 5}
      )

    assert {:ok, result} =
             ReqLLMAdapter.process_stream(stream_response,
               on_text: fn text -> send(parent, {:text, text}) end,
               on_thinking: fn text -> send(parent, {:thinking, text}) end,
               on_tool_call: fn chunk -> send(parent, {:tool, chunk}) end
             )

    assert_received {:text, "hello"}
    assert_received {:thinking, "thinking"}

    assert_received {:tool,
                     %ReqLLMAdapter.ToolCall{
                       id: "tc_1",
                       name: "grep",
                       arguments: %{"pattern" => "needle"}
                     }}

    assert %ReqLLMAdapter.TurnResult{tool_calls: tool_calls, usage: usage} = result

    assert [
             %ReqLLMAdapter.ToolCall{
               id: "tc_1",
               name: "grep",
               arguments: %{"pattern" => "needle"}
             }
           ] = tool_calls

    assert usage.input_tokens == 10
    assert usage.output_tokens == 5
  end

  test "retains the complete assistant message for provider continuation" do
    reasoning =
      ReqLLM.Message.ReasoningDetails.from_openai_compatible(
        %{
          "text" => "private reasoning",
          "signature" => "opaque-signature",
          "vendor_field" => "kept"
        },
        :openrouter,
        0
      )

    opaque_part = ReqLLM.Message.ContentPart.image_url("https://example.test/result.png")

    stream_response =
      build_stream_response(
        [
          ReqLLM.StreamChunk.text("before", %{provider_field: "opaque"}),
          ReqLLM.StreamChunk.content_part(opaque_part),
          ReqLLM.StreamChunk.content_part(opaque_part, %{stream_only?: true}),
          ReqLLM.StreamChunk.thinking("temporary preview", %{stream_only?: true}),
          ReqLLM.StreamChunk.thinking("private reasoning"),
          ReqLLM.StreamChunk.text("after"),
          ReqLLM.StreamChunk.tool_call("grep", %{"pattern" => "one"}, %{id: "tc_1", index: 0}),
          ReqLLM.StreamChunk.tool_call("grep", %{"pattern" => "two"}, %{id: "tc_2", index: 1}),
          ReqLLM.StreamChunk.meta(%{
            finish_reason: :tool_use,
            reasoning_details: [reasoning]
          })
        ],
        %{},
        %{
          response_id: "resp_1",
          phase: :analysis,
          phase_items: ["item_1"],
          provider_meta: %{trace_id: "trace_1"}
        }
      )

    assert {:ok, result} = ReqLLMAdapter.process_stream(stream_response)

    assert Enum.map(result.message.content, & &1.type) == [:text, :image_url, :thinking, :text]

    assert result.message.content |> Enum.at(0) ==
             ReqLLM.Message.ContentPart.text("before", %{provider_field: "opaque"})

    assert Enum.at(result.message.content, 1) == opaque_part
    assert Enum.at(result.message.content, 2).text == "private reasoning"
    assert Enum.at(result.message.content, 3).text == "after"
    assert result.message.reasoning_details == [reasoning]
    assert result.message.metadata.response_id == "resp_1"
    assert result.message.metadata.phase == :analysis
    assert result.message.metadata.phase_items == ["item_1"]

    assert Enum.map(result.message.tool_calls, & &1.id) == ["tc_1", "tc_2"]
    assert Enum.map(result.tool_calls, & &1.id) == ["tc_1", "tc_2"]
  end

  test "keeps interleaved text and thinking in provider order" do
    stream_response =
      build_stream_response([
        ReqLLM.StreamChunk.text("before"),
        ReqLLM.StreamChunk.thinking("reasoning"),
        ReqLLM.StreamChunk.text("after"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ])

    assert {:ok, result} = ReqLLMAdapter.process_stream(stream_response)
    assert Enum.map(result.message.content, & &1.type) == [:text, :thinking, :text]
    assert Enum.map(result.message.content, & &1.text) == ["before", "reasoning", "after"]
  end

  test "rejects a response marked incomplete instead of returning a successful turn" do
    stream_response =
      build_stream_response(
        [
          ReqLLM.StreamChunk.text("partial response"),
          ReqLLM.StreamChunk.meta(%{finish_reason: :incomplete})
        ],
        %{},
        %{finish_reason: :incomplete}
      )

    assert {:error, {:incomplete_response, :incomplete}, "partial response"} =
             ReqLLMAdapter.process_stream(stream_response)
  end

  test "preserves structured content materialized by ReqLLM" do
    stream_response =
      build_stream_response([
        ReqLLM.StreamChunk.text(~s({"answer":"ok"})),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ])

    assert {:ok, result} = ReqLLMAdapter.process_stream(stream_response)
    assert result.message.content == [%{type: :object, object: %{"answer" => "ok"}}]
  end

  test "stops the stream accumulator when a callback raises" do
    parent = self()

    stream_response =
      build_stream_response([
        ReqLLM.StreamChunk.text("boom"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ])

    {:links, links_before} = Process.info(self(), :links)

    assert {:error, %RuntimeError{message: "callback failed"}, "boom"} =
             ReqLLMAdapter.process_stream(stream_response,
               on_text: fn _text ->
                 {:links, links_during} = Process.info(self(), :links)
                 send(parent, {:new_links, links_during -- links_before})
                 raise "callback failed"
               end
             )

    assert_received {:new_links, [accumulator]}
    ref = Process.monitor(accumulator)
    assert_receive {:DOWN, ^ref, :process, ^accumulator, _reason}
  end

  test "summary client uses the resolved request model and exact route" do
    parent = self()

    client = fn model, messages, opts ->
      send(parent, {:summary_request, model, messages, opts})
      {:ok, build_stream_response([ReqLLM.StreamChunk.text("compacted")])}
    end

    selection = ModelSelectionFixture.selection()

    summary_client = ReqLLMAdapter.summary_client(client, selection, %AgentConfig{})

    assert {:ok, "compacted"} =
             summary_client.(selection.request_model, [:message], max_tokens: 500)

    assert_received {:summary_request, %LLMDB.Model{} = model, [:message], opts}
    assert model == selection.request_model
    assert opts[:max_tokens] == 500
    refute Keyword.has_key?(opts, :base_url)
    assert opts[:auth_mode] == :none
    refute Keyword.has_key?(opts, :api_key)
  end

  test "assistant_tool_call keeps ReqLLM message compatibility" do
    tool_call = ReqLLMAdapter.assistant_tool_call("tc_1", "grep", %{"pattern" => "needle"})

    assert ReqLLM.ToolCall.to_map(tool_call) == %{
             id: "tc_1",
             name: "grep",
             arguments: %{"pattern" => "needle"}
           }
  end

  defp selection do
    ModelSelectionFixture.selection(
      request_provider: :anthropic,
      model_provider: "anthropic",
      model_id: "claude",
      display_name: "Claude",
      origin: {:catalog, "anthropic", "claude"},
      credential: %ApiKey{provider: "anthropic", source: :env},
      reasoning: %{effort: "high", options: ["off", "high"]},
      limits: %{
        context: 100_000,
        input: 90_000,
        output: 4_096,
        request_output: 4_096
      }
    )
  end
end
