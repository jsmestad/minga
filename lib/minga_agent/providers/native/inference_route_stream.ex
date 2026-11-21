defmodule MingaAgent.Providers.Native.InferenceRouteStream do
  @moduledoc """
  Starts one model stream through a contributed inference route.

  The route is looked up in the registry at request time, so a route removed after selection fails the request instead of falling back to another model. The calling process holds a `Minga.Extension.CodeLease` lease on the route's module for the whole stream: the lease is released when the stream finishes, halts, raises, or is cancelled, and when the consuming process exits. An extension that stops during a stream therefore keeps its code loaded until the stream ends.
  """

  alias Minga.Extension.CodeLease
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.InferenceRouteRegistry.Entry
  alias MingaAgent.Providers.Native.{InferenceRouteRequest, InferenceRouteResponse}
  alias ReqLLM.StreamResponse

  @typedoc "Failure before any stream exists."
  @type start_error ::
          {:inference_route_unavailable, String.t()}
          | {:inference_route_failed, String.t(), term()}
          | InferenceRouteRequest.error()

  @doc """
  Looks up the route, translates the request, leases the route's code, and starts its stream.

  `llm_model` is the materialized model the native loop holds; it describes the translated stream response.
  """
  @spec start(
          GenServer.server(),
          String.t(),
          String.t(),
          LLMDB.Model.t(),
          [ReqLLM.Message.t()],
          keyword()
        ) :: {:ok, StreamResponse.t()} | {:error, term()}
  def start(registry, route_id, model_id, llm_model, messages, opts) do
    with {:ok, entry} <- fetch_route(registry, route_id),
         {:ok, model} <- route_model(entry, model_id),
         {:ok, request} <- InferenceRouteRequest.build(model, messages, opts),
         {:ok, lease} <- lease(entry) do
      entry
      |> call_route(request)
      |> translate(llm_model, messages)
      |> hold_lease(lease, route_id)
    end
  end

  @spec fetch_route(GenServer.server(), String.t()) ::
          {:ok, Entry.t()} | {:error, start_error()}
  defp fetch_route(registry, route_id) do
    case InferenceRouteRegistry.lookup(registry, route_id) do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, {:inference_route_unavailable, route_id}}
    end
  catch
    :exit, _reason -> {:error, {:inference_route_unavailable, route_id}}
  end

  @spec route_model(Entry.t(), String.t()) ::
          {:ok, MingaAgent.InferenceRoute.Model.t()} | {:error, start_error()}
  defp route_model(entry, model_id) do
    case Entry.model(entry, model_id) do
      {:ok, model} -> {:ok, model}
      {:error, :model_not_found} -> {:error, {:inference_route_unavailable, entry.spec.id}}
    end
  end

  @spec lease(Entry.t()) :: {:ok, CodeLease.t()} | {:error, start_error()}
  defp lease(%Entry{spec: spec}) do
    case CodeLease.lease(spec.source, spec.module, :inference_route) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, {:inference_route_failed, spec.id, {:code_lease, reason}}}
    end
  end

  @spec call_route(Entry.t(), MingaAgent.InferenceRoute.Request.t()) :: term()
  defp call_route(%Entry{spec: spec}, request) do
    spec.module.stream(request)
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec translate(term(), LLMDB.Model.t(), [ReqLLM.Message.t()]) :: term()
  defp translate({:ok, response}, llm_model, messages),
    do: InferenceRouteResponse.to_stream_response(response, llm_model, messages)

  defp translate(other, _llm_model, _messages), do: other

  @spec hold_lease(term(), CodeLease.t(), String.t()) ::
          {:ok, StreamResponse.t()} | {:error, term()}
  defp hold_lease({:ok, %StreamResponse{} = response}, lease, _route_id) do
    release = fn -> CodeLease.release(lease) end

    stream =
      Stream.transform(
        response.stream,
        fn -> :ok end,
        fn chunk, acc -> {[chunk], acc} end,
        fn _acc -> release.() end
      )

    cancel = fn ->
      try do
        response.cancel.()
      after
        release.()
      end
    end

    {:ok, %{response | stream: stream, cancel: cancel}}
  end

  defp hold_lease({:error, reason}, lease, _route_id) do
    CodeLease.release(lease)
    {:error, reason}
  end

  defp hold_lease(other, lease, route_id) do
    CodeLease.release(lease)
    {:error, {:inference_route_failed, route_id, {:invalid_stream_return, other}}}
  end
end
