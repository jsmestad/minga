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
  alias MingaEditor.Extension.EventHandler
  alias MingaEditor.State, as: EditorState

  @type unload_result ::
          {:ok, EditorState.t()}
          | {:error, [CallbackInvoker.failure()], EditorState.t()}

  @typep fanout_acc :: %{
           status: :handled | :not_matched,
           state: EditorState.t(),
           failures: [CallbackInvoker.failure()]
         }

  @doc "Dispatches an ordinary recognized event with its family policy."
  @spec dispatch(
          EditorState.t(),
          term(),
          CallbackRegistry.registry(),
          GenServer.server()
        ) :: EventHandler.result()
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

  def dispatch(%EditorState{}, _event, _registry, _admission), do: :not_matched

  @doc "Dispatches a parameterized action to extension callbacks in priority order."
  @spec dispatch_editor_action(
          EditorState.t(),
          atom(),
          term(),
          CallbackRegistry.registry(),
          GenServer.server()
        ) :: EventHandler.result()
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
        ) :: unload_result()
  def dispatch_source_unload(
        %EditorState{} = state,
        source,
        token,
        registry \\ CallbackRegistry.default_table(),
        admission \\ CodeLease
      )
      when is_reference(token) do
    callbacks = CallbackRegistry.callbacks_for_source(:source_unload, source, registry)

    case dispatch_unload_callbacks(callbacks, state, source, token, admission, []) do
      {updated_state, []} -> {:ok, updated_state}
      {updated_state, failures} -> {:error, Enum.reverse(failures), updated_state}
    end
  end

  @spec dispatch_fanout(
          [CallbackRegistry.callback()],
          EditorState.t(),
          EventHandler.event(),
          GenServer.server()
        ) :: EventHandler.result()
  defp dispatch_fanout(callbacks, state, event, admission) do
    callbacks
    |> Enum.reduce(%{status: :not_matched, state: state, failures: []}, fn callback, acc ->
      dispatch_fanout_callback(callback, acc, event, admission)
    end)
    |> fanout_result()
  end

  @spec dispatch_fanout_callback(
          CallbackRegistry.callback(),
          fanout_acc(),
          EventHandler.event(),
          GenServer.server()
        ) :: fanout_acc()
  defp dispatch_fanout_callback(callback, acc, event, admission) do
    case invoke(callback, acc.state, event, admission) do
      {:handled, state} -> %{acc | status: :handled, state: state}
      :not_matched -> acc
      {:callback_failed, failure} -> %{acc | failures: [failure | acc.failures]}
    end
  end

  @spec fanout_result(fanout_acc()) :: EventHandler.result()
  defp fanout_result(%{failures: [], status: :handled, state: state}), do: {:handled, state}
  defp fanout_result(%{failures: [], status: :not_matched}), do: :not_matched

  defp fanout_result(%{failures: failures, state: state}),
    do: {:callback_failed, Enum.reverse(failures), state}

  @spec dispatch_first(
          [CallbackRegistry.callback()],
          EditorState.t(),
          EventHandler.event(),
          GenServer.server()
        ) :: EventHandler.result()
  defp dispatch_first([], _state, _event, _admission), do: :not_matched

  defp dispatch_first([callback | rest], state, event, admission) do
    case invoke(callback, state, event, admission) do
      {:handled, updated_state} -> {:handled, updated_state}
      :not_matched -> dispatch_first(rest, state, event, admission)
      {:callback_failed, _failure} = failure -> failure
    end
  end

  @spec dispatch_unload_callbacks(
          [CallbackRegistry.callback()],
          EditorState.t(),
          CallbackRegistry.source(),
          CodeLease.unload_token(),
          GenServer.server(),
          [CallbackInvoker.failure()]
        ) :: {EditorState.t(), [CallbackInvoker.failure()]}
  defp dispatch_unload_callbacks([], state, _source, _token, _admission, failures),
    do: {state, failures}

  defp dispatch_unload_callbacks(
         [callback | rest],
         state,
         source,
         token,
         admission,
         failures
       ) do
    case invoke_unload(callback, state, source, token, admission) do
      {:handled, updated_state} ->
        dispatch_unload_callbacks(rest, updated_state, source, token, admission, failures)

      :not_matched ->
        dispatch_unload_callbacks(rest, state, source, token, admission, failures)

      {:callback_failed, failure} ->
        dispatch_unload_callbacks(rest, state, source, token, admission, [failure | failures])
    end
  end

  @spec invoke(
          CallbackRegistry.callback(),
          EditorState.t(),
          EventHandler.event(),
          GenServer.server()
        ) :: EventHandler.callback_result() | {:callback_failed, CallbackInvoker.failure()}
  defp invoke({source, callback}, state, event, admission) do
    case CallbackInvoker.invoke(
           source,
           callback,
           :handle_editor_event,
           [state, event],
           event_kind(event),
           admission
         ) do
      {:ok, result} -> validate_result(source, callback, result)
      {:error, failure} -> {:callback_failed, failure}
    end
  end

  @spec invoke_unload(
          CallbackRegistry.callback(),
          EditorState.t(),
          CallbackRegistry.source(),
          CodeLease.unload_token(),
          GenServer.server()
        ) :: EventHandler.callback_result() | {:callback_failed, CallbackInvoker.failure()}
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
      {:ok, result} -> validate_result(source, callback, result)
      {:error, failure} -> {:callback_failed, failure}
    end
  end

  @spec validate_result(CallbackRegistry.source(), module(), term()) ::
          EventHandler.callback_result() | {:callback_failed, CallbackInvoker.failure()}
  defp validate_result(_source, _callback, {:handled, %EditorState{} = state}),
    do: {:handled, state}

  defp validate_result(_source, _callback, :not_matched), do: :not_matched

  defp validate_result(source, callback, returned) do
    failure = CallbackInvoker.invalid_return(source, callback, :handle_editor_event, returned)
    {:callback_failed, failure}
  end

  @spec updated_state_result(EditorState.t()) :: {:handled, EditorState.t()}
  defp updated_state_result(state), do: {:handled, state}

  @spec event_kind(EventHandler.event()) :: EventHandler.event_kind()
  defp event_kind({:buffer_saved, _buffer}), do: :buffer_saved
  defp event_kind({:editor_action, _action, _arguments}), do: :editor_action
end
