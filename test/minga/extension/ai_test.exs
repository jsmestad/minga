defmodule Minga.Extension.AITest do
  use ExUnit.Case, async: true

  alias Minga.Extension.AI
  alias MingaAgent.Config
  alias MingaAgent.Credentials
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelSelection

  @msgs [%{role: "user", content: "hi"}]

  setup_all do
    snapshot = Credentials.Snapshot.new(%{"openai" => :env}, nil)

    assert {:ok, _selection} =
             ModelResolver.resolve("openai:gpt-4", credential_snapshot: snapshot)

    :ok
  end

  setup do
    [
      hosted_opts: [
        model: "openai:gpt-4",
        credentials_opts: [env: %{"OPENAI_API_KEY" => "fixture-openai-key"}]
      ]
    ]
  end

  test "complete maps a provider error to a tagged tuple", %{hosted_opts: hosted_opts} do
    client = fn _model, _messages, _opts -> {:error, :boom} end

    assert {:error, {:provider_error, :boom}} =
             AI.complete(@msgs, Keyword.put(hosted_opts, :client, client))
  end

  test "stream delivers a tagged provider error to reply_to", %{hosted_opts: hosted_opts} do
    client = fn _model, _messages, _opts -> {:error, :boom} end

    {:ok, ref} =
      AI.stream(
        @msgs,
        hosted_opts |> Keyword.put(:client, client) |> Keyword.put(:reply_to, self())
      )

    assert_receive {:minga_ai, ^ref, {:error, {:provider_error, :boom}}}, 5_000
  end

  test "stream reports lazy token enumeration errors to reply_to", %{hosted_opts: hosted_opts} do
    client = fn _model, _messages, _opts -> {:ok, stream_response(raising_stream())} end

    {:ok, ref} =
      AI.stream(
        @msgs,
        hosted_opts |> Keyword.put(:client, client) |> Keyword.put(:reply_to, self())
      )

    assert_receive {:minga_ai, ^ref, {:chunk, "partial"}}, 5_000
    assert_receive {:minga_ai, ^ref, {:error, {:provider_error, "stream blew up"}}}, 2_000
  end

  test "complete maps lazy token enumeration errors to a tagged tuple", %{
    hosted_opts: hosted_opts
  } do
    client = fn _model, _messages, _opts -> {:ok, stream_response(raising_stream())} end

    assert {:error, {:provider_error, "stream blew up"}} =
             AI.complete(@msgs, Keyword.put(hosted_opts, :client, client))
  end

  test "system prompt is prepended ahead of the messages", %{hosted_opts: hosted_opts} do
    test_pid = self()

    client = fn model, messages, opts ->
      send(test_pid, {:captured, model, messages, opts})
      {:error, :stop}
    end

    AI.complete(
      @msgs,
      hosted_opts
      |> Keyword.put(:client, client)
      |> Keyword.put(:system, "You are terse.")
    )

    assert_receive {:captured, %LLMDB.Model{id: "gpt-4"},
                    [
                      %{role: "system", content: "You are terse."},
                      %{role: "user", content: "hi"}
                    ], request_opts}

    assert request_opts[:api_key] == "fixture-openai-key"
    assert request_opts[:max_tokens] == 1_024
  end

  @tag :tmp_dir
  test "hosted file credentials are resolved before dispatch", %{tmp_dir: dir} do
    test_pid = self()
    credentials_opts = [config_dir: dir, env: %{"OPENAI_API_KEY" => nil}]
    assert :ok = Credentials.store("openai", "stored-openai-key", credentials_opts)

    client = fn model, _messages, opts ->
      send(test_pid, {:captured_request, model, opts})
      {:error, :stop}
    end

    assert {:error, {:provider_error, :stop}} =
             AI.complete(@msgs,
               model: "openai:gpt-4",
               client: client,
               credentials_opts: credentials_opts
             )

    assert_receive {:captured_request, %LLMDB.Model{id: "gpt-4"}, request_opts}
    assert request_opts[:api_key] == "stored-openai-key"
  end

  test "unsupported local and custom model names never invoke the client" do
    test_pid = self()
    client = fn _model, _messages, _opts -> send(test_pid, :unexpected_request) end

    for model <- ["ollama:llama3", "private:custom-model"] do
      assert {:error, {:provider_error, {:model_not_found, _message}}} =
               AI.complete(@msgs,
                 model: model,
                 client: client,
                 credentials_opts: [env: %{"OPENAI_API_KEY" => "fixture-openai-key"}]
               )
    end

    refute_received :unexpected_request
  end

  test "an exact configured selection id dispatches its catalog request model" do
    snapshot = MingaAgent.Credentials.Snapshot.new(%{"openai" => :env}, nil)

    assert {:ok, selection} =
             ModelResolver.resolve("openai:gpt-4", credential_snapshot: snapshot)

    config = %Config{
      model: ModelSelection.id(selection),
      selection_intent: ModelSelection.encode(selection)
    }

    test_pid = self()

    client = fn model, _messages, _opts ->
      send(test_pid, {:captured_model, model})
      {:error, :stop}
    end

    assert {:error, {:provider_error, :stop}} =
             AI.complete(@msgs,
               config: config,
               client: client,
               credentials_opts: [env: %{"OPENAI_API_KEY" => "fixture-openai-key"}]
             )

    assert_receive {:captured_model, %LLMDB.Model{id: "gpt-4"}}
  end

  test "resolver option injection cannot replace the hosted catalog endpoint" do
    test_pid = self()

    client = fn model, _messages, _opts ->
      send(test_pid, {:captured_base_url, model.base_url})
      {:error, :stop}
    end

    assert {:error, {:provider_error, :stop}} =
             AI.complete(@msgs,
               model: "openai:gpt-4",
               client: client,
               credentials_opts: [env: %{"OPENAI_API_KEY" => "fixture-openai-key"}],
               model_resolver_opts: [
                 models: [
                   %{
                     id: "openai/gpt-4",
                     provider: :openai,
                     execution: %{
                       text: %{
                         supported: true,
                         wire_protocol: "openai_chat",
                         base_url: "https://redirect.example/v1"
                       }
                     }
                   }
                 ],
                 providers: [
                   %{id: :openai, runtime: %{"base_url" => "https://redirect.example/v1"}}
                 ]
               ]
             )

    assert_receive {:captured_base_url, base_url}
    refute base_url == "https://redirect.example/v1"
  end

  @spec raising_stream() :: Enumerable.t()
  defp raising_stream do
    Stream.resource(
      fn -> :first end,
      fn
        :first -> {[ReqLLM.StreamChunk.text("partial")], :raise}
        :raise -> raise "stream blew up"
      end,
      fn _state -> :ok end
    )
  end

  @spec stream_response(Enumerable.t()) :: ReqLLM.StreamResponse.t()
  defp stream_response(stream) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{usage: %{}, finish_reason: :stop}
      end)

    %ReqLLM.StreamResponse{
      stream: stream,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: nil,
      context: ReqLLM.Context.new()
    }
  end
end
