defmodule MingaAgent.Providers.Native.InferenceRouteResponse do
  @moduledoc """
  Translates a route's `MingaAgent.InferenceRoute.Response` into the stream response the native loop consumes.

  Events become stream chunks as they arrive. Usage and the finish reason are delivered through the response metadata once the events end. An event that is not a valid `MingaAgent.InferenceRoute.Event` stops the stream and fails the request with `{:inference_route_invalid_event, event}`; `{:finish, {:error, reason}}` fails it with the route's own `reason`. If enumerating the route's events raises, exits, or throws, the stream ends with `{:inference_route_failed, route_id, failure}`.

  When the events end, `finished` runs. When Minga stops reading early (an invalid event, a failure, or a consumer that halts), the response's `cancel` runs instead.
  """

  alias MingaAgent.InferenceRoute.{Event, Response, ToolCall, Usage}
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  @typep state :: %{
           index: non_neg_integer(),
           usage: Usage.t() | nil,
           finish: Event.finish_reason() | nil,
           invalid: {:invalid, term()} | nil,
           failure: term() | nil,
           done?: boolean()
         }

  @doc "Wraps a route response for the native loop. The model and messages describe the request."
  @spec to_stream_response(term(), LLMDB.Model.t(), [ReqLLM.Message.t()], (-> term())) ::
          {:ok, StreamResponse.t()} | {:error, {:inference_route_invalid_response, term()}}
  def to_stream_response(response, model, messages, finished \\ fn -> :ok end)

  def to_stream_response(
        %Response{events: events, cancel: cancel},
        %LLMDB.Model{} = model,
        messages,
        finished
      )
      when is_function(cancel, 0) and is_function(finished, 0) do
    tag = make_ref()
    relay = spawn_link(fn -> relay(tag, nil, nil) end)

    {:ok, handle} =
      MetadataHandle.start_link(fn ->
        send(relay, {:await, self()})

        receive do
          {^tag, metadata} -> metadata
        end
      end)

    {:ok,
     %StreamResponse{
       stream: translate(events, relay, route_id(model), cancel, finished),
       metadata_handle: handle,
       cancel: fn ->
         try do
           cancel.()
         after
           send(relay, {:final, %{error: :cancelled}})
         end

         :ok
       end,
       model: model,
       context: ReqLLM.Context.new(messages)
     }}
  end

  def to_stream_response(other, _model, _messages, _finished),
    do: {:error, {:inference_route_invalid_response, invalid_summary(other)}}

  @spec route_id(LLMDB.Model.t()) :: String.t()
  defp route_id(%LLMDB.Model{extra: %{inference_route: %{route_id: route_id}}}), do: route_id
  defp route_id(%LLMDB.Model{}), do: "unknown"

  @spec metadata(state()) :: map()
  defp metadata(%{invalid: {:invalid, event}}),
    do: %{error: {:inference_route_invalid_event, invalid_summary(event)}}

  defp metadata(%{failure: {route_id, failure}}),
    do: %{error: {:inference_route_failed, route_id, failure}}

  defp metadata(%{finish: {:error, reason}}), do: %{error: reason}

  defp metadata(%{finish: finish, usage: usage}),
    do: %{usage: usage_metadata(usage), finish_reason: finish_reason(finish)}

  @spec translate(Enumerable.t(), pid(), String.t(), (-> term()), (-> term())) ::
          Enumerable.t()
  defp translate(events, relay, route_id, cancel, finished) do
    tag = make_ref()

    events
    |> guarded(tag)
    |> Stream.transform(
      fn -> %{index: 0, usage: nil, finish: nil, invalid: nil, failure: nil, done?: false} end,
      fn event, state -> chunks(event, state, tag, route_id) end,
      fn state -> {[], %{state | done?: true}} end,
      fn state ->
        send(relay, {:final, metadata(state)})
        if state.done?, do: finished.(), else: cancel.()
      end
    )
  end

  # Enumerates the route's events one at a time so a raise, exit, or throw becomes a tagged failure element.
  @spec guarded(Enumerable.t(), reference()) :: Enumerable.t()
  defp guarded(events, tag) do
    Stream.resource(
      fn -> &Enumerable.reduce(events, &1, fn event, _acc -> {:suspend, event} end) end,
      &next_event(&1, tag),
      &close_events/1
    )
  end

  @spec next_event(term(), reference()) :: {[term()], term()} | {:halt, :done}
  defp next_event(:done, _tag), do: {:halt, :done}

  defp next_event(continuation, tag) do
    case continuation.({:cont, nil}) do
      {:suspended, event, next} -> {[event], next}
      {:done, _acc} -> {:halt, :done}
      {:halted, _acc} -> {:halt, :done}
    end
  rescue
    exception -> {[{tag, {:raised, Exception.message(exception)}}], :done}
  catch
    kind, reason -> {[{tag, {kind, invalid_summary(reason)}}], :done}
  end

  @spec close_events(term()) :: :ok
  defp close_events(:done), do: :ok

  defp close_events(continuation) do
    continuation.({:halt, nil})
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @spec chunks(term(), state(), reference(), String.t()) ::
          {[StreamChunk.t()], state()} | {:halt, state()}
  defp chunks({tag, failure}, state, tag, route_id),
    do: {:halt, %{state | failure: {route_id, failure}}}

  defp chunks(event, state, _tag, _route_id) do
    case Event.validate(event) do
      {:ok, valid} -> valid_chunks(valid, state)
      {:error, {:invalid_event, invalid}} -> {:halt, %{state | invalid: {:invalid, invalid}}}
    end
  end

  @spec valid_chunks(Event.t(), state()) :: {[StreamChunk.t()], state()}
  defp valid_chunks({:text, text}, state), do: {[StreamChunk.text(text)], state}
  defp valid_chunks({:thinking, text}, state), do: {[StreamChunk.thinking(text)], state}

  defp valid_chunks({:tool_call, %ToolCall{} = call}, state) do
    chunk = StreamChunk.tool_call(call.name, call.arguments, %{id: call.id, index: state.index})
    {[chunk], %{state | index: state.index + 1}}
  end

  defp valid_chunks({:usage, usage}, state), do: {[], %{state | usage: usage}}
  defp valid_chunks({:finish, reason}, state), do: {[], %{state | finish: reason}}

  @spec usage_metadata(Usage.t() | nil) :: map() | nil
  defp usage_metadata(nil), do: nil

  defp usage_metadata(%Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_read_input_tokens: usage.cache_read_tokens,
      cache_creation_input_tokens: usage.cache_write_tokens
    }
  end

  @spec finish_reason(Event.finish_reason() | nil) :: atom()
  defp finish_reason(nil), do: :stop
  defp finish_reason(:refusal), do: :content_filter
  defp finish_reason(reason) when reason in [:stop, :tool_calls, :length], do: reason

  # Keep a bounded, printable shape of route output in errors and logs.
  @spec invalid_summary(term()) :: String.t()
  defp invalid_summary(term), do: inspect(term, limit: 10, printable_limit: 200)

  # Hands the final metadata to the metadata worker, whichever arrives first.
  @spec relay(reference(), pid() | nil, map() | nil) :: :ok
  defp relay(tag, waiter, metadata) do
    receive do
      {:await, pid} when is_map(metadata) ->
        send(pid, {tag, metadata})
        :ok

      {:await, pid} ->
        relay(tag, pid, metadata)

      {:final, final} when is_nil(metadata) and is_pid(waiter) ->
        send(waiter, {tag, final})
        :ok

      {:final, final} when is_nil(metadata) ->
        relay(tag, waiter, final)

      {:final, _later} ->
        relay(tag, waiter, metadata)
    end
  end
end
