defmodule MingaEditor.Extension.EventDispatcher do
  @moduledoc """
  Dispatches runtime editor events to extension-owned callbacks.

  Buffer-save callbacks fan out in priority order and retain state from every
  successful handler even when a later callback fails. Editor actions stop at
  the first success, decline, or failure boundary: only a successful
  `:not_matched` advances. Source unload is a separate token-scoped fan-out that
  filters callbacks by source and intentionally continues after failures.
  """

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias MingaEditor.Extension.EventDispatchResult
  alias MingaEditor.Extension.EventHandler
  alias MingaEditor.State, as: EditorState

  @doc "Dispatches an ordinary recognized event with its family policy."
  @spec dispatch(
          EditorState.t(),
          term(),
          CallbackRegistry.registry(),
          GenServer.server()
        ) :: EventDispatchResult.t()
  def dispatch(
        state,
        event,
        registry \\ CallbackRegistry.default_table(),
        admission \\ CodeLease
      )

  def dispatch(%EditorState{} = state, {:buffer_saved, buffer} = event, registry, admission)
      when is_pid(buffer) do
    callbacks = CallbackRegistry.callbacks(:buffer_saved, registry)
    dispatch_fanout(callbacks, state, event, admission)
  end

  def dispatch(
        %EditorState{} = state,
        {:editor_action, action, _arguments} = event,
        registry,
        admission
      )
      when is_atom(action) do
    callbacks = CallbackRegistry.callbacks(:editor_action, registry)
    dispatch_first(callbacks, state, event, admission)
  end

  def dispatch(%EditorState{} = state, _event, _registry, _admission),
    do: EventDispatchResult.not_matched(state)

  @doc "Dispatches a parameterized action to extension callbacks in priority order."
  @spec dispatch_editor_action(
          EditorState.t(),
          atom(),
          term(),
          CallbackRegistry.registry(),
          GenServer.server()
        ) :: EventDispatchResult.t()
  def dispatch_editor_action(
        %EditorState{} = state,
        action,
        arguments,
        registry \\ CallbackRegistry.default_table(),
        admission \\ CodeLease
      )
      when is_atom(action) do
    dispatch(state, {:editor_action, action, arguments}, registry, admission)
  end

  @doc "Invokes a core event callback directly with normal crash semantics."
  @spec dispatch_core(EditorState.t(), EventHandler.event(), module()) ::
          EventHandler.callback_result()
  def dispatch_core(%EditorState{} = state, event, callback) when is_atom(callback) do
    case callback.handle_editor_event(state, event) do
      {:handled, %EditorState{} = updated_state} ->
        updated_state_result(updated_state)

      :not_matched ->
        :not_matched

      returned ->
        raise ArgumentError, "core event callback returned invalid value: #{inspect(returned)}"
    end
  end

  @doc "Runs token-scoped unload callbacks owned by exactly one extension source."
  @spec dispatch_source_unload(
          EditorState.t(),
          CallbackRegistry.source(),
          CodeLease.unload_token(),
          CallbackRegistry.registry(),
          GenServer.server()
        ) :: EventDispatchResult.t()
  def dispatch_source_unload(
        %EditorState{} = state,
        source,
        token,
        registry \\ CallbackRegistry.default_table(),
        admission \\ CodeLease
      )
      when is_reference(token) do
    callbacks = CallbackRegistry.callbacks_for_source(:source_unload, source, registry)

    dispatch_unload_callbacks(
      callbacks,
      EventDispatchResult.not_matched(state),
      source,
      token,
      admission
    )
  end

  @spec dispatch_fanout(
          [CallbackRegistry.callback()],
          EditorState.t(),
          EventHandler.event(),
          GenServer.server()
        ) :: EventDispatchResult.t()
  defp dispatch_fanout(callbacks, state, event, admission) do
    callbacks
    |> Enum.reduce(EventDispatchResult.not_matched(state), fn callback, result ->
      dispatch_fanout_callback(callback, result, event, admission)
    end)
    |> order_failures()
  end

  @spec dispatch_fanout_callback(
          CallbackRegistry.callback(),
          EventDispatchResult.t(),
          EventHandler.event(),
          GenServer.server()
        ) :: EventDispatchResult.t()
  defp dispatch_fanout_callback(callback, result, event, admission) do
    callback
    |> invoke(result.state, event, admission)
    |> accumulate_fanout_result(result)
  end

  @spec accumulate_fanout_result(EventDispatchResult.t(), EventDispatchResult.t()) ::
          EventDispatchResult.t()
  defp accumulate_fanout_result(
         %EventDispatchResult{status: :handled, state: state},
         %EventDispatchResult{failures: []}
       ),
       do: EventDispatchResult.handled(state)

  defp accumulate_fanout_result(
         %EventDispatchResult{status: :handled, state: state},
         %EventDispatchResult{failures: failures}
       ),
       do: EventDispatchResult.callback_failed(state, failures)

  defp accumulate_fanout_result(
         %EventDispatchResult{status: :not_matched},
         %EventDispatchResult{} = result
       ),
       do: result

  defp accumulate_fanout_result(
         %EventDispatchResult{status: :callback_failed, failures: [failure]},
         %EventDispatchResult{} = result
       ) do
    EventDispatchResult.callback_failed(result.state, [failure | result.failures])
  end

  @spec order_failures(EventDispatchResult.t()) :: EventDispatchResult.t()
  defp order_failures(%EventDispatchResult{
         status: :callback_failed,
         state: state,
         failures: failures
       }),
       do: EventDispatchResult.callback_failed(state, Enum.reverse(failures))

  defp order_failures(%EventDispatchResult{} = result), do: result

  @spec dispatch_first(
          [CallbackRegistry.callback()],
          EditorState.t(),
          EventHandler.event(),
          GenServer.server()
        ) :: EventDispatchResult.t()
  defp dispatch_first([], state, _event, _admission), do: EventDispatchResult.not_matched(state)

  defp dispatch_first([callback | rest], state, event, admission) do
    case invoke(callback, state, event, admission) do
      %EventDispatchResult{status: :not_matched} -> dispatch_first(rest, state, event, admission)
      %EventDispatchResult{} = result -> result
    end
  end

  @spec dispatch_unload_callbacks(
          [CallbackRegistry.callback()],
          EventDispatchResult.t(),
          CallbackRegistry.source(),
          CodeLease.unload_token(),
          GenServer.server()
        ) :: EventDispatchResult.t()
  defp dispatch_unload_callbacks([], result, _source, _token, _admission),
    do: order_failures(result)

  defp dispatch_unload_callbacks(
         [callback | rest],
         result,
         source,
         token,
         admission
       ) do
    next_result =
      callback
      |> invoke_unload(result.state, source, token, admission)
      |> accumulate_fanout_result(result)

    dispatch_unload_callbacks(rest, next_result, source, token, admission)
  end

  @spec invoke(
          CallbackRegistry.callback(),
          EditorState.t(),
          EventHandler.event(),
          GenServer.server()
        ) :: EventDispatchResult.t()
  defp invoke({source, callback}, state, event, admission) do
    case CallbackInvoker.invoke(
           source,
           callback,
           :handle_editor_event,
           [state, event],
           event_kind(event),
           admission
         ) do
      {:ok, result} -> validate_result(source, callback, state, result)
      {:error, failure} -> EventDispatchResult.callback_failed(state, [failure])
    end
  end

  @spec invoke_unload(
          CallbackRegistry.callback(),
          EditorState.t(),
          CallbackRegistry.source(),
          CodeLease.unload_token(),
          GenServer.server()
        ) :: EventDispatchResult.t()
  defp invoke_unload({source, callback}, state, source, token, admission) do
    case CallbackInvoker.invoke_unload(
           source,
           token,
           callback,
           :handle_editor_event,
           [state, {:source_unload, source}],
           :source_unload,
           admission
         ) do
      {:ok, result} -> validate_result(source, callback, state, result)
      {:error, failure} -> EventDispatchResult.callback_failed(state, [failure])
    end
  end

  @spec validate_result(CallbackRegistry.source(), module(), EditorState.t(), term()) ::
          EventDispatchResult.t()
  defp validate_result(_source, _callback, _state, {:handled, %EditorState{} = state}),
    do: EventDispatchResult.handled(state)

  defp validate_result(_source, _callback, state, :not_matched),
    do: EventDispatchResult.not_matched(state)

  defp validate_result(source, callback, state, returned) do
    failure = CallbackInvoker.invalid_return(source, callback, :handle_editor_event, returned)
    EventDispatchResult.callback_failed(state, [failure])
  end

  @spec updated_state_result(EditorState.t()) :: {:handled, EditorState.t()}
  defp updated_state_result(state), do: {:handled, state}

  @spec event_kind(EventHandler.event()) :: EventHandler.event_kind()
  defp event_kind({:buffer_saved, _buffer}), do: :buffer_saved
  defp event_kind({:editor_action, _action, _arguments}), do: :editor_action
end
