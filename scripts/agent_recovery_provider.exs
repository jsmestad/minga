defmodule Minga.Recovery.ProviderFixture do
  @moduledoc """
  Deterministic, non-live-model responses at Native's external llm_client boundary.

  Session, Native, tool registration, admission, execution, storage and cancellation are real.
  Each response waits for an explicit driver message; no provider HTTP request is made.
  """

  @type request :: {pid(), reference(), LLMDB.Model.t(), [ReqLLM.Message.t()]}

  @spec client(pid()) :: MingaAgent.Providers.Native.llm_client()
  def client(owner) do
    fn model, messages, _options ->
      token = make_ref()
      send(owner, {:recovery_request, {self(), token, model, messages}})

      receive do
        {:recovery_response, ^token, chunks} -> response(model, chunks)
      after
        15_000 -> {:error, :fixture_response_deadline}
      end
    end
  end

  @spec deliver(request(), [ReqLLM.StreamChunk.t()]) :: :ok
  def deliver({pid, token, _model, _messages}, chunks) do
    send(pid, {:recovery_response, token, chunks})
    :ok
  end

  @spec tool(String.t(), String.t(), map()) :: [ReqLLM.StreamChunk.t()]
  def tool(id, name, args) do
    [
      ReqLLM.StreamChunk.tool_call(name, args, %{id: id}),
      ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
    ]
  end

  @spec text(String.t()) :: [ReqLLM.StreamChunk.t()]
  def text(text) do
    [ReqLLM.StreamChunk.text(text), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
  end

  @spec response(LLMDB.Model.t(), [ReqLLM.StreamChunk.t()]) :: {:ok, ReqLLM.StreamResponse.t()}
  defp response(model, chunks) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{usage: %{total_cost: 0.0}, finish_reason: :stop}
      end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: chunks,
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: model,
       context: ReqLLM.Context.new()
     }}
  end
end
