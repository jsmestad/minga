defmodule Minga.Bench.ActiveSessionProvider do
  @moduledoc "Synthetic responses at Native's streaming boundary. The editor, Session and Native worker are real."

  alias Minga.Recovery.ProviderFixture
  alias MingaAgent.Test.ModelSelectionFixture
  alias ReqLLM.StreamChunk

  @spec options(pid()) :: keyword()
  def options(driver) do
    [
      credential_opts: [env: %{"OPENAI_API_KEY" => "benchmark-fixture"}],
      model_resolver_opts: ModelSelectionFixture.resolver_opts(),
      config: MingaAgent.Config.resolve() |> MingaAgent.Config.without_hooks(),
      tool_allowlist: [],
      active_skill_names: [],
      mcp_enabled?: false,
      max_retries: 0,
      llm_client: ProviderFixture.client(driver)
    ]
  end

  @spec stream(pid()) :: Enumerable.t()
  def stream(driver) do
    chunks = Minga.Bench.AgentStreamReplay.chunks()

    Stream.resource(
      fn ->
        send(driver, {:active_stream_consumer, self()})
        chunks
      end,
      fn
        :finished ->
          {:halt, :finished}

        [text | rest] ->
          receive do
            {:benchmark_stream_chunk, ^driver} ->
              {[StreamChunk.text(text)], if(rest == [], do: chunks, else: rest)}

            {:finish_benchmark_stream, ^driver} ->
              {[StreamChunk.meta(%{finish_reason: :stop})], :finished}
          after
            30_000 -> raise "benchmark did not advance the active stream"
          end
      end,
      fn _ -> :ok end
    )
  end
end
