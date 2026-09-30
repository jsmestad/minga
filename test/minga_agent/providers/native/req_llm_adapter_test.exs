defmodule MingaAgent.Providers.Native.ReqLLMAdapterTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias ReqLLM.StreamResponse.MetadataHandle

  defp build_stream_response(chunks, usage \\ %{}, response_metadata \\ %{}) do
    metadata = Map.merge(%{usage: usage, finish_reason: :stop}, response_metadata)
    {:ok, handle} = MetadataHandle.start_link(fn -> metadata end)

    %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
      context: ReqLLM.Context.new()
    }
  end

  test "validates malformed models before ReqLLM handles them" do
    assert :ok = ReqLLMAdapter.validate_model("anthropic:claude-sonnet-4")
    assert :ok = ReqLLMAdapter.validate_model("local/llama3@ollama")

    for invalid <- [
          "claude-sonnet-4",
          "anthropic:",
          ":claude",
          "claude@",
          "@ollama",
          "anthropic:claude@openai"
        ] do
      assert {:error, message, :invalid_format} = ReqLLMAdapter.validate_model(invalid)
      assert message =~ "Expected"
      assert message =~ "Check :agent_model"
    end
  end

  test "builds request options for endpoints, prompt cache, codex oauth, and thinking" do
    config = %AgentConfig{
      api_base_url_override: nil,
      api_base_url: "https://global.example/v1",
      api_endpoints: %{"anthropic" => "https://anthropic.example/v1"},
      prompt_cache: true
    }

    opts = ReqLLMAdapter.stream_opts("anthropic:claude", [], "high", 4096, config)
    assert opts[:tools] == []
    assert opts[:max_tokens] == 4096
    assert opts[:base_url] == "https://anthropic.example/v1"
    assert opts[:provider_options][:anthropic_prompt_cache] == true
    assert opts[:provider_options][:anthropic_cache_messages] == true
    assert opts[:reasoning_effort] == :high

    openai_opts = ReqLLMAdapter.stream_opts("gpt-4o@openai", [], "high", 1000, config)
    assert openai_opts[:base_url] == "https://global.example/v1"
    refute Keyword.has_key?(openai_opts[:provider_options] || [], :anthropic_prompt_cache)

    codex_opts = ReqLLMAdapter.stream_opts("gpt-5@openai_codex", [], "off", 1000, config)
    assert codex_opts[:provider_options][:auth_mode] == :oauth
    assert codex_opts[:provider_options][:oauth_file] == MingaAgent.Credentials.oauth_path()
    assert codex_opts[:provider_options][:codex_originator] == "minga"
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

  test "call_sync wraps the streaming client and returns text" do
    parent = self()

    client = fn _model, _messages, opts ->
      send(parent, {:sync_opts, opts})
      {:ok, build_stream_response([ReqLLM.StreamChunk.text("summary")])}
    end

    config = %AgentConfig{api_base_url: "https://global.example/v1"}

    assert {:ok, "summary"} =
             ReqLLMAdapter.call_sync(client, "anthropic:claude", [], [max_tokens: 1234], config)

    assert_received {:sync_opts, opts}
    assert opts[:max_tokens] == 1234
    assert opts[:base_url] == "https://global.example/v1"
  end

  test "summary_client preserves request options and returns text" do
    parent = self()

    client = fn model, messages, opts ->
      send(parent, {:summary_request, model, messages, opts})
      {:ok, build_stream_response([ReqLLM.StreamChunk.text("compacted")])}
    end

    config = %AgentConfig{api_endpoints: %{"anthropic" => "https://anthropic.example/v1"}}
    summary_client = ReqLLMAdapter.summary_client(client, config)

    assert {:ok, "compacted"} = summary_client.("anthropic:claude", [:message], max_tokens: 500)
    assert_received {:summary_request, "anthropic:claude", [:message], opts}
    assert opts[:max_tokens] == 500
    assert opts[:base_url] == "https://anthropic.example/v1"
  end

  test "assistant_tool_call keeps ReqLLM message compatibility" do
    tool_call = ReqLLMAdapter.assistant_tool_call("tc_1", "grep", %{"pattern" => "needle"})

    assert ReqLLM.ToolCall.to_map(tool_call) == %{
             id: "tc_1",
             name: "grep",
             arguments: %{"pattern" => "needle"}
           }
  end
end
