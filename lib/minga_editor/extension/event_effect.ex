defmodule MingaEditor.Extension.EventEffect do
  @moduledoc """
  Runs extension-owned editor callbacks outside the Editor mailbox.

  Each request carries an immutable Editor snapshot. A completed state transition
  commits only while that exact snapshot remains current, so a slow extension
  can never overwrite input or other state changes that arrived while it ran.
  Timed-out, conflicting, and late results are terminal and never rerun.
  """

  @behaviour MingaEditor.Effect

  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Extension.EventDispatchResult
  alias MingaEditor.Extension.EventDispatcher
  alias MingaEditor.Extension.EventHandler
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState

  @resource :extension_editor_events
  @max_queued 0
  @timeout_ms 1_000

  @type mode :: :ordinary | {:unload, CallbackRegistry.source(), CodeLease.unload_token()}
  @type reply_to :: {pid(), reference()} | nil

  @enforce_keys [:mode, :base_state, :event, :registry, :admission]
  defstruct [:mode, :base_state, :event, :registry, :admission, :reply_to]

  @type t :: %__MODULE__{
          mode: mode(),
          base_state: EditorState.t(),
          event: EventHandler.event(),
          registry: CallbackRegistry.registry(),
          admission: GenServer.server(),
          reply_to: reply_to()
        }

  @doc "Builds one bounded FIFO callback request for an ordinary editor event."
  @spec request(EditorState.t(), EventHandler.event(), keyword()) :: Request.t()
  def request(%EditorState{} = state, event, opts \\ []) do
    effect = %__MODULE__{
      mode: :ordinary,
      base_state: state,
      event: event,
      registry: Keyword.get(opts, :callback_registry, CallbackRegistry.default_table()),
      admission: Keyword.get(opts, :callback_admission, CodeLease),
      reply_to: Keyword.get(opts, :reply_to)
    }

    Request.new(effect, @resource, Policy.fifo(@max_queued), timeout_ms: timeout(opts))
  end

  @doc "Builds one token-authorized unload callback request."
  @spec unload_request(
          EditorState.t(),
          CallbackRegistry.source(),
          CodeLease.unload_token(),
          reply_to(),
          keyword()
        ) :: Request.t()
  def unload_request(%EditorState{} = state, source, token, reply_to, opts \\ [])
      when is_reference(token) do
    effect = %__MODULE__{
      mode: {:unload, source, token},
      base_state: state,
      event: {:source_unload, source},
      registry: Keyword.get(opts, :callback_registry, CallbackRegistry.default_table()),
      admission: Keyword.get(opts, :callback_admission, CodeLease),
      reply_to: reply_to
    }

    Request.new(
      effect,
      {:extension_editor_unload, source},
      Policy.fifo(@max_queued),
      timeout_ms: timeout(opts)
    )
  end

  @impl true
  @spec run(t()) :: {:ok, EventDispatchResult.t()}
  def run(%__MODULE__{mode: :ordinary} = effect) do
    {:ok,
     EventDispatcher.dispatch(
       effect.base_state,
       effect.event,
       effect.registry,
       effect.admission
     )}
  end

  def run(%__MODULE__{mode: {:unload, source, token}} = effect) do
    {:ok,
     EventDispatcher.dispatch_source_unload(
       effect.base_state,
       source,
       token,
       effect.registry,
       effect.admission
     )}
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{}, %__MODULE__{} = newer), do: newer

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        %EditorState{} = current,
        %Outcome{
          status: :completed,
          result: %EventDispatchResult{} = result,
          request: %Request{effect: %__MODULE__{base_state: base_state} = effect}
        } = outcome
      ) do
    {state, final_outcome} = commit_result(current, base_state, result, outcome, effect.event)
    reply(effect, unload_reply(result, final_outcome))
    {state, final_outcome}
  end

  def apply(
        %EditorState{} = state,
        %Outcome{
          status: status,
          request: %Request{id: request_id, effect: %__MODULE__{} = effect}
        } = outcome
      )
      when status in [:failed, :canceled, :stale] do
    Minga.Log.warning(
      :editor,
      "Extension editor event terminal request=#{inspect(request_id)} mode=#{inspect(effect.mode)} event=#{inspect(event_label(effect.event))} status=#{status} reason=#{bounded_inspect(outcome.reason)}"
    )

    state = terminal_feedback(state, effect.event, status, outcome.reason)
    reply(effect, {:error, {:extension_event_terminal, status, outcome.reason}})
    {state, outcome}
  end

  def apply(%EditorState{} = state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{status: :completed, result: %EventDispatchResult{status: :handled}}),
    do: true

  def render?(%Outcome{
        status: :completed,
        result: %EventDispatchResult{status: :callback_failed}
      }),
      do: true

  def render?(%Outcome{
        status: :completed,
        result: %EventDispatchResult{status: :not_matched},
        request: %Request{effect: %__MODULE__{mode: {:unload, _source, _token}}}
      }),
      do: true

  def render?(%Outcome{
        status: outcome_status,
        result: %EventDispatchResult{status: result_status},
        request: %Request{effect: %__MODULE__{event: {:editor_action, _action, _arguments}}}
      })
      when outcome_status in [:completed, :stale] and
             result_status in [:not_matched, :callback_failed],
      do: true

  def render?(%Outcome{
        status: status,
        request: %Request{effect: %__MODULE__{event: {:editor_action, _action, _arguments}}}
      })
      when status in [:failed, :canceled],
      do: true

  def render?(%Outcome{}), do: false

  @spec commit_result(
          EditorState.t(),
          EditorState.t(),
          EventDispatchResult.t(),
          Outcome.t(),
          EventHandler.event()
        ) :: {EditorState.t(), Outcome.t()}
  defp commit_result(current, base_state, result, outcome, event) do
    report_callback_failures(event, result.failures)

    case EditorState.accept_extension_event_result(current, base_state, result.state) do
      {:ok, state} ->
        {result_feedback(state, result, event), outcome}

      :stale ->
        request_id = outcome.request.id

        Minga.Log.warning(
          :editor,
          "Discarded stale extension editor event request=#{inspect(request_id)} event=#{inspect(event_label(event))} reason=editor_state_changed"
        )

        state = result_feedback(current, result, event)
        {state, Outcome.stale(outcome, :editor_state_changed)}
    end
  end

  @spec result_feedback(EditorState.t(), EventDispatchResult.t(), EventHandler.event()) ::
          EditorState.t()
  defp result_feedback(state, %EventDispatchResult{status: :callback_failed}, event),
    do: interactive_failure(state, event)

  defp result_feedback(state, %EventDispatchResult{status: :not_matched}, event),
    do: interactive_unavailable(state, event)

  defp result_feedback(state, %EventDispatchResult{}, _event), do: state

  @spec terminal_feedback(EditorState.t(), EventHandler.event(), atom(), term()) ::
          EditorState.t()
  defp terminal_feedback(
         state,
         {:editor_action, :open_git_diff_for_path, _arguments},
         status,
         reason
       ),
       do: NoticeWorkflow.publish(state, "Git diff #{status}: #{bounded_inspect(reason)}")

  defp terminal_feedback(
         state,
         {:editor_action, :execute_git_command, _command},
         status,
         reason
       ),
       do: NoticeWorkflow.publish(state, "Git command #{status}: #{bounded_inspect(reason)}")

  defp terminal_feedback(state, {:editor_action, action, _arguments}, status, reason)
       when action in [:branch_delete_confirm, :branch_delete_cancel],
       do:
         NoticeWorkflow.publish(
           state,
           "Branch delete action #{status}: #{bounded_inspect(reason)}"
         )

  defp terminal_feedback(state, _event, _status, _reason), do: state

  @spec interactive_failure(EditorState.t(), EventHandler.event()) :: EditorState.t()
  defp interactive_failure(state, {:editor_action, :open_git_diff_for_path, _arguments}),
    do: NoticeWorkflow.publish(state, "Git porcelain extension callback failed")

  defp interactive_failure(state, {:editor_action, :execute_git_command, _command}),
    do: NoticeWorkflow.publish(state, "Git command callback failed")

  defp interactive_failure(state, {:editor_action, action, _arguments})
       when action in [:branch_delete_confirm, :branch_delete_cancel],
       do: NoticeWorkflow.publish(state, "Branch delete action failed")

  defp interactive_failure(state, _event), do: state

  @spec interactive_unavailable(EditorState.t(), EventHandler.event()) :: EditorState.t()
  defp interactive_unavailable(state, {:editor_action, :open_git_diff_for_path, _arguments}),
    do: NoticeWorkflow.publish(state, "Git porcelain extension is disabled or failed to load")

  defp interactive_unavailable(state, {:editor_action, :execute_git_command, _command}),
    do: NoticeWorkflow.publish(state, "Git command unavailable")

  defp interactive_unavailable(state, {:editor_action, action, _arguments})
       when action in [:branch_delete_confirm, :branch_delete_cancel],
       do: NoticeWorkflow.publish(state, "Branch delete action unavailable")

  defp interactive_unavailable(state, _event), do: state

  @spec report_callback_failures(EventHandler.event(), [term()]) :: :ok
  defp report_callback_failures(_event, []), do: :ok

  defp report_callback_failures(event, failures) do
    summaries = Enum.map(failures, &failure_label/1)

    Minga.Log.warning(
      :editor,
      "Extension editor callback failed event=#{inspect(event_label(event))} failures=#{inspect(summaries, limit: 20)}"
    )
  end

  @spec event_label(EventHandler.event()) :: term()
  defp event_label({:buffer_saved, _buffer}), do: :buffer_saved
  defp event_label({:editor_action, action, _arguments}), do: {:editor_action, action}
  defp event_label({:source_unload, source}), do: {:source_unload, source}

  @spec failure_label(term()) :: term()
  defp failure_label({:callback_failed, source, module, function, kind, _reason}),
    do: {:callback_failed, source, module, function, kind}

  defp failure_label({:source_unavailable, source, module, function, _reason}),
    do: {:source_unavailable, source, module, function}

  defp failure_label({:invalid_return, source, module, function, returned}),
    do: {:invalid_return, source, module, function, term_kind(returned)}

  defp failure_label(other), do: term_kind(other)

  @spec term_kind(term()) :: atom() | {atom(), non_neg_integer()}
  defp term_kind(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp term_kind(value) when is_map(value), do: {:map, map_size(value)}
  defp term_kind(value) when is_list(value), do: :list
  defp term_kind(value) when is_binary(value), do: {:binary, byte_size(value)}
  defp term_kind(value) when is_atom(value), do: :atom
  defp term_kind(value) when is_number(value), do: :number
  defp term_kind(_value), do: :other

  @spec bounded_inspect(term()) :: String.t()
  defp bounded_inspect(value), do: inspect(value, limit: 10, printable_limit: 200)

  @spec unload_reply(EventDispatchResult.t(), Outcome.t()) :: :ok | {:error, term()}
  defp unload_reply(_result, %Outcome{status: :stale, reason: reason}),
    do: {:error, {:extension_unload_stale, reason}}

  defp unload_reply(%EventDispatchResult{status: :callback_failed, failures: failures}, %Outcome{
         status: :completed
       }),
       do: {:error, failures}

  defp unload_reply(%EventDispatchResult{}, %Outcome{status: :completed}), do: :ok

  @spec timeout(keyword()) :: pos_integer()
  defp timeout(opts) do
    case Keyword.get(opts, :timeout_ms, @timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> min(timeout_ms, @timeout_ms)
      _invalid -> @timeout_ms
    end
  end

  @spec reply(t(), term()) :: :ok
  defp reply(%__MODULE__{reply_to: nil}, _reply), do: :ok

  defp reply(%__MODULE__{reply_to: {recipient, ref}}, result) do
    send(recipient, {:extension_source_finalized, ref, result})
    :ok
  end
end
