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
               auth_mode: :api_key,
               api_key: "request-secret"
             )

    assert opts[:tools] == []
    assert opts[:max_tokens] == 4_096
    refute Keyword.has_key?(opts, :base_url)
    assert opts[:auth_mode] == :api_key
    assert opts[:api_key] == "request-secret"
    assert opts[:provider_options][:anthropic_prompt_cache] == true
    assert opts[:provider_options][:anthropic_cache_messages] == true
    assert opts[:reasoning_effort] == :high
  end

  test "cache options follow the executing protocol rather than the model source owner" do
    for {request_provider, owner, expected_cache?} <- [
          {:anthropic, "openai", true},
          {:openai, "anthropic", false}
        ] do
      selection =
        ModelSelectionFixture.selection(request_provider: request_provider, model_provider: owner)

      assert {:ok, opts} =
               ReqLLMAdapter.stream_opts(selection, [], %AgentConfig{prompt_cache: true},
                 auth_mode: :api_key,
                 api_key: "fixture-key"
               )

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

    summary =
      ReqLLMAdapter.summary_client(client, selection, %AgentConfig{}, fn ->
        {:ok, [auth_mode: :api_key, api_key: "fixture-openai-key"]}
      end)

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

  test "the next encoded Anthropic request preserves supported continuation blocks and tool groups" do
    opaque = %{
      "type" => "server_tool_use",
      "id" => "server_1",
      "name" => "web_search",
      "input" => %{"query" => "synthetic fixture"}
    }

    calls = [
      ReqLLM.StreamChunk.tool_call("grep", %{"pattern" => "one"}, %{id: "tc_1", index: 0}),
      ReqLLM.StreamChunk.tool_call("grep", %{"pattern" => "two"}, %{id: "tc_2", index: 1})
    ]

    encoded_calls = [
      %{"type" => "tool_use", "id" => "tc_1", "name" => "grep", "input" => %{"pattern" => "one"}},
      %{"type" => "tool_use", "id" => "tc_2", "name" => "grep", "input" => %{"pattern" => "two"}}
    ]

    for {chunks, expected_content, tool_ids} <- [
          {[ReqLLM.StreamChunk.text("only text")], "only text", []},
          {
            [
              ReqLLM.StreamChunk.text("before", %{cache_control: %{type: "ephemeral"}}),
              ReqLLM.StreamChunk.thinking("stream-only thinking preview", %{stream_only?: true}),
              ReqLLM.StreamChunk.thinking("signed reasoning", %{signature: "opaque-signature"}),
              ReqLLM.StreamChunk.text("after")
            ] ++ calls,
            [
              %{
                "type" => "text",
                "text" => "before",
                "cache_control" => %{"type" => "ephemeral"}
              },
              %{
                "type" => "thinking",
                "thinking" => "signed reasoning",
                "signature" => "opaque-signature"
              },
              %{"type" => "text", "text" => "after"}
            ] ++ encoded_calls,
            ["tc_1", "tc_2"]
          },
          {
            [
              ReqLLM.StreamChunk.text("before"),
              ReqLLM.StreamChunk.content_part(
                ReqLLM.Message.ContentPart.provider_block(
                  :anthropic,
                  Map.put(opaque, "id", "stream-only-preview")
                ),
                %{stream_only?: true}
              ),
              ReqLLM.StreamChunk.content_part(
                ReqLLM.Message.ContentPart.provider_block(:anthropic, opaque)
              ),
              ReqLLM.StreamChunk.text("after")
            ] ++ calls,
            [
              %{"type" => "text", "text" => "before"},
              opaque,
              %{"type" => "text", "text" => "after"}
            ] ++
              encoded_calls,
            ["tc_1", "tc_2"]
          },
          {calls, encoded_calls, ["tc_1", "tc_2"]}
        ] do
      stream_response = build_stream_response(chunks)
      assert {:ok, result} = ReqLLMAdapter.process_stream(stream_response)

      results =
        Enum.map(tool_ids, fn id ->
          ReqLLM.Context.tool_result_message("grep", id, "result " <> id)
        end)

      request =
        ReqLLM.Providers.Anthropic.encode_body(%Req.Request{
          options: [
            context:
              ReqLLM.Context.new([ReqLLM.Context.user("fixture"), result.message] ++ results),
            model: "exact-anthropic",
            stream: false
          ]
        })

      encoded =
        request
        |> Req.Steps.encode_body()
        |> Map.fetch!(:body)
        |> IO.iodata_to_binary()
        |> JSON.decode!()

      assert Enum.at(encoded["messages"], 1) == %{
               "role" => "assistant",
               "content" => expected_content
             }

      if tool_ids != [] do
        assert List.last(encoded["messages"]) == %{
                 "role" => "user",
                 "content" =>
                   Enum.map(tool_ids, fn id ->
                     %{"type" => "tool_result", "tool_use_id" => id, "content" => "result " <> id}
                   end)
               }
      end
    end
  end

  test "rejects cancelled, missing, malformed, and incomplete completion reasons" do
    for finish_reason <- [:incomplete, :cancelled, :length, :unknown, nil] do
      stream_response =
        build_stream_response(
          [
            ReqLLM.StreamChunk.text("partial response"),
            ReqLLM.StreamChunk.meta(%{finish_reason: finish_reason})
          ],
          %{},
          %{finish_reason: finish_reason}
        )

      assert {:error, {:incomplete_response, ^finish_reason}, "partial response"} =
               ReqLLMAdapter.process_stream(stream_response)
    end
  end

  test "compaction preserves JSON-looking text instead of returning an empty summary" do
    json = ~s({ "summary": "keep these facts" })

    client = fn _model, _messages, _opts ->
      {:ok,
       build_stream_response([
         ReqLLM.StreamChunk.thinking("Summarize the facts"),
         ReqLLM.StreamChunk.text(json),
         ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
       ])}
    end

    summary =
      ReqLLMAdapter.summary_client(client, selection(), %AgentConfig{}, fn ->
        {:ok, [auth_mode: :api_key, api_key: "fixture-anthropic-key"]}
      end)

    assert {:ok, ^json} = summary.(nil, [], max_tokens: 100)
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

    summary_client =
      ReqLLMAdapter.summary_client(client, selection, %AgentConfig{}, fn ->
        {:ok, [auth_mode: :api_key, api_key: "fixture-openai-key"]}
      end)

    assert {:ok, "compacted"} =
             summary_client.(selection.request_model, [:message], max_tokens: 500)

    assert_received {:summary_request, %LLMDB.Model{} = model, [:message], opts}
    assert model == selection.request_model
    assert opts[:max_tokens] == 500
    refute Keyword.has_key?(opts, :base_url)
    assert opts[:auth_mode] == :api_key
    assert opts[:api_key] == "fixture-openai-key"
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
