defmodule MingaAgent.Session.TurnExecution do
  @moduledoc """
  Owns one session's execution mode, runtime phase, and turn-scoped resources.

  Transitions are pure. `MingaAgent.Session` interprets returned effects in order and remains responsible for provider calls, notifications, broadcasts, transcript updates, and persistence.
  """

  alias MingaAgent.EditBoundary
  alias MingaAgent.Event
  alias MingaAgent.ToolApproval

  @typedoc "Execution mode, independent of whether a provider turn is active."
  @type mode :: :exec | :plan

  @typedoc "Tool trust lifetime."
  @type trust_scope :: :session | :turn

  @typedoc "Prompt content admitted to steering and follow-up queues."
  @type content :: String.t() | [ReqLLM.Message.ContentPart.t()]

  @typedoc "How an active turn should admit an additional prompt."
  @type prompt_kind :: :steering | :follow_up

  @typedoc "Whether a prompt starts a turn now or joins one of the active turn's queues."
  @type prompt_admission ::
          {:send_now, t(), effects()} | {:queued, prompt_kind(), t(), effects()}

  @typedoc "An active provider tool identified by its stable call ID."
  @type active_tool :: {tool_call_id :: String.t(), name :: String.t()}

  @typedoc "Provider activity within one active turn."
  @type activity ::
          :starting | :thinking | :completion | {:tool_execution, [active_tool(), ...]}

  @typedoc "Runtime phase. Approval is orthogonal to provider activity within an active turn."
  @type phase ::
          :idle
          | {:active, activity(), ToolApproval.t() | nil}
          | {:failure, String.t()}

  @typedoc "Public status retained at the Session API boundary."
  @type status :: :idle | :plan | :thinking | :tool_executing | :error

  @typedoc "Supported approval response."
  @type approval_decision :: :approve | :approve_session | :approve_turn | :reject

  @typedoc "Typed reason a transition rejected its source state or identity."
  @type rejection ::
          :turn_active
          | :invalid_phase
          | :no_pending_approval
          | :approval_not_found
          | :tool_already_active
          | :tool_not_active

  @typedoc "Ordered external effect interpreted by the Session process."
  @type effect ::
          {:status_changed, status()}
          | {:notify, atom(), String.t()}
          | :notify_completion
          | {:broadcast, term()}
          | {:reject_approval, ToolApproval.t()}
          | {:send_approval_response, ToolApproval.t(), approval_decision()}
          | {:record_approval_resolution, ToolApproval.t(), approval_decision()}
          | {:append_approval_rejection, ToolApproval.t()}
          | {:mark_tool_auto_approved, Event.ToolApproval.t(), trust_scope()}
          | {:append_tool_start, Event.ToolStart.t(), trust_scope() | nil}
          | {:finish_tool, Event.ToolEnd.t()}
          | :announce_plan_mode
          | :announce_exec_mode
          | :notify_messages_changed
          | :reconsider_idle_gc
          | :abort_provider
          | :abort_active_tools
          | {:append_system_message, String.t(), :info | :warning | :error}
          | {:append_error_once, String.t()}
          | :collapse_thinking
          | {:apply_usage, Event.token_usage() | nil}
          | :dispatch_stop
          | {:append_steering_messages, [content()]}

  @typedoc "Ordered effects returned by a transition."
  @type effects :: [effect()]

  @typedoc "Canonical turn execution state."
  @type t :: %__MODULE__{
          mode: mode(),
          phase: phase(),
          trust_levels: %{String.t() => trust_scope()},
          pending_auto_approvals: %{String.t() => trust_scope()},
          steering_queue: [content()],
          follow_up_queue: [content()],
          boundaries: %{String.t() => EditBoundary.t()}
        }

  defstruct mode: :exec,
            phase: :idle,
            trust_levels: %{},
            pending_auto_approvals: %{},
            steering_queue: [],
            follow_up_queue: [],
            boundaries: %{}

  @doc "Builds an idle execution state."
  @spec new(mode()) :: t()
  def new(mode \\ :exec) when mode in [:exec, :plan], do: %__MODULE__{mode: mode}

  @doc "Returns the current execution mode."
  @spec mode(t()) :: mode()
  def mode(%__MODULE__{mode: mode}), do: mode

  @doc "Returns the current runtime phase name."
  @spec phase(t()) ::
          :idle
          | :starting
          | :thinking
          | :approval_waiting
          | :tool_execution
          | :completion
          | :failure
  def phase(%__MODULE__{phase: {:active, _activity, %ToolApproval{}}}),
    do: :approval_waiting

  def phase(%__MODULE__{phase: {:active, activity, nil}}), do: activity_phase(activity)
  def phase(%__MODULE__{phase: {:failure, _message}}), do: :failure
  def phase(%__MODULE__{phase: :idle}), do: :idle

  @doc "Derives the stable public Session status."
  @spec status(t()) :: status()
  def status(%__MODULE__{mode: :plan}), do: :plan
  def status(%__MODULE__{phase: :idle}), do: :idle
  def status(%__MODULE__{phase: {:active, activity, _approval}}), do: activity_status(activity)
  def status(%__MODULE__{phase: {:failure, _message}}), do: :error

  @doc "Returns true while provider work belongs to the current turn."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{phase: {:active, _activity, _approval}}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "Returns the current pending approval, if any."
  @spec pending_approval(t()) :: ToolApproval.t() | nil
  def pending_approval(%__MODULE__{phase: {:active, _activity, approval}}), do: approval
  def pending_approval(%__MODULE__{}), do: nil

  @doc "Returns the current failure message, if any."
  @spec error(t()) :: String.t() | nil
  def error(%__MODULE__{phase: {:failure, message}}), do: message
  def error(%__MODULE__{}), do: nil

  @doc "Returns active tools in provider start order."
  @spec active_tools(t()) :: [active_tool()]
  def active_tools(%__MODULE__{phase: {:active, {:tool_execution, tools}, _approval}}),
    do: tools

  def active_tools(%__MODULE__{}), do: []

  @doc "Returns the most recently started active tool name."
  @spec active_tool_name(t()) :: String.t() | nil
  def active_tool_name(%__MODULE__{} = execution) do
    case List.last(active_tools(execution)) do
      {_id, name} -> name
      nil -> nil
    end
  end

  @doc "Returns the name for one active tool call."
  @spec tool_name(t(), String.t()) :: {:ok, String.t()} | {:error, :tool_not_active}
  def tool_name(%__MODULE__{} = execution, tool_call_id) when is_binary(tool_call_id) do
    case List.keyfind(active_tools(execution), tool_call_id, 0) do
      {_id, name} -> {:ok, name}
      nil -> {:error, :tool_not_active}
    end
  end

  @doc "Begins a provider turn from an inactive state."
  @spec begin_turn(t()) :: {:ok, t(), effects()} | {:error, :turn_active, t()}
  def begin_turn(%__MODULE__{phase: :idle} = execution),
    do: {:ok, activate(execution, :starting), []}

  def begin_turn(%__MODULE__{phase: {:failure, _message}} = execution),
    do: {:ok, activate(execution, :starting), []}

  def begin_turn(%__MODULE__{phase: {:active, _activity, _approval}} = execution),
    do: {:error, :turn_active, execution}

  @doc "Accepts the provider's turn-start event."
  @spec provider_started(t()) :: {:ok, t(), effects()} | {:error, :invalid_phase, t()}
  def provider_started(%__MODULE__{phase: {:active, :starting, nil}} = execution) do
    next = activate(execution, :thinking)
    {:ok, next, status_effect(next, :thinking)}
  end

  def provider_started(%__MODULE__{} = execution),
    do: {:error, :invalid_phase, execution}

  @doc "Moves an active turn into approval waiting."
  @spec request_approval(t(), ToolApproval.t()) :: {:ok, t(), effects()}
  def request_approval(
        %__MODULE__{phase: {:active, _activity, %ToolApproval{}}} = execution,
        %ToolApproval{} = approval
      ),
      do: {:ok, execution, [{:reject_approval, approval}]}

  def request_approval(
        %__MODULE__{phase: {:active, activity, nil}} = execution,
        %ToolApproval{} = approval
      ) do
    next = %{execution | phase: {:active, activity, approval}}

    effects = [
      {:notify, :approval, "Approval needed: #{approval.name}"},
      {:broadcast, {:approval_pending, ToolApproval.public(approval)}}
    ]

    {:ok, next, effects}
  end

  def request_approval(%__MODULE__{} = execution, %ToolApproval{} = approval),
    do: {:ok, execution, [{:reject_approval, approval}]}

  @doc "Resolves the matching pending approval and restores the active runtime phase."
  @spec resolve_approval(t(), String.t() | nil, approval_decision()) ::
          {:ok, ToolApproval.t(), t(), effects()}
          | {:error, :approval_not_found | :no_pending_approval, t()}
  def resolve_approval(
        %__MODULE__{phase: {:active, activity, %ToolApproval{} = approval}} = execution,
        approval_id,
        decision
      )
      when decision in [:approve, :approve_session, :approve_turn, :reject] do
    resolve_matching_approval(execution, activity, approval, approval_id, decision)
  end

  def resolve_approval(%__MODULE__{} = execution, _approval_id, _decision),
    do: {:error, :no_pending_approval, execution}

  @doc "Records a trusted approval, or rejects it outside an admitted turn."
  @spec auto_approve(t(), Event.ToolApproval.t(), trust_scope()) :: {:ok, t(), effects()}
  def auto_approve(
        %__MODULE__{phase: :idle} = execution,
        %Event.ToolApproval{} = event,
        _scope
      ),
      do: {:ok, execution, [{:reject_approval, approval_from_event(event)}]}

  def auto_approve(
        %__MODULE__{phase: {:failure, _message}} = execution,
        %Event.ToolApproval{} = event,
        _scope
      ),
      do: {:ok, execution, [{:reject_approval, approval_from_event(event)}]}

  def auto_approve(%__MODULE__{} = execution, %Event.ToolApproval{} = event, scope)
      when scope in [:session, :turn] do
    next = %{
      execution
      | pending_auto_approvals:
          Map.put(execution.pending_auto_approvals, event.tool_call_id, scope)
    }

    effects = [
      {:send_approval_response, approval_from_event(event), :approve},
      {:mark_tool_auto_approved, event, scope}
    ]

    {:ok, next, effects}
  end

  @doc "Starts one tool and installs its stable identity before effects run."
  @spec tool_started(t(), Event.ToolStart.t()) ::
          {:ok, trust_scope() | nil, t(), effects()}
          | {:error, :invalid_phase | :tool_already_active, t()}
  def tool_started(
        %__MODULE__{phase: {:active, _activity, _approval}} = execution,
        %Event.ToolStart{} = event
      ) do
    tools = active_tools(execution)

    if List.keymember?(tools, event.tool_call_id, 0) do
      {:error, :tool_already_active, execution}
    else
      {scope, pending_auto_approvals} =
        Map.pop(execution.pending_auto_approvals, event.tool_call_id)

      next =
        execution
        |> put_activity({:tool_execution, tools ++ [{event.tool_call_id, event.name}]})
        |> Map.put(:pending_auto_approvals, pending_auto_approvals)

      effects = status_effect(next, :tool_executing) ++ [{:append_tool_start, event, scope}]
      {:ok, scope, next, effects}
    end
  end

  def tool_started(%__MODULE__{} = execution, %Event.ToolStart{}),
    do: {:error, :invalid_phase, execution}

  @doc "Completes one matching active tool and rejects stale or duplicate completions."
  @spec tool_completed(t(), Event.ToolEnd.t()) ::
          {:ok, t(), effects()} | {:error, :tool_not_active, t()}
  def tool_completed(%__MODULE__{} = execution, %Event.ToolEnd{} = event) do
    case List.keytake(active_tools(execution), event.tool_call_id, 0) do
      {{_id, _name}, remaining} ->
        next =
          execution
          |> put_activity(completed_tool_activity(remaining))
          |> Map.update!(:pending_auto_approvals, &Map.delete(&1, event.tool_call_id))

        {:ok, next, [{:finish_tool, event}]}

      nil ->
        {:error, :tool_not_active, execution}
    end
  end

  @doc "Admits a prompt by starting an inactive turn or queueing behind an active turn."
  @spec admit_prompt(t(), prompt_kind(), content()) :: prompt_admission()
  def admit_prompt(%__MODULE__{phase: {:active, _activity, _approval}} = execution, kind, content)
      when kind in [:steering, :follow_up] do
    queue_prompt(execution, kind, content)
  end

  def admit_prompt(%__MODULE__{} = execution, kind, _content)
      when kind in [:steering, :follow_up] do
    {:ok, next, effects} = begin_turn(execution)
    {:send_now, next, effects}
  end

  @doc "Dequeues steering prompts without changing follow-up admission."
  @spec dequeue_steering(t()) :: {[content()], t(), effects()}
  def dequeue_steering(%__MODULE__{} = execution) do
    steering = execution.steering_queue
    next = %{execution | steering_queue: []}
    effects = if steering == [], do: [], else: [{:append_steering_messages, steering}]
    {steering, next, effects}
  end

  @doc "Returns and clears both prompt queues."
  @spec recall_queues(t()) :: {{[content()], [content()]}, t(), effects()}
  def recall_queues(%__MODULE__{} = execution) do
    result = queues(execution)
    {result, clear_queue_values(execution), [{:broadcast, :queues_recalled}]}
  end

  @doc "Clears both prompt queues."
  @spec clear_queues(t()) :: {t(), effects()}
  def clear_queues(%__MODULE__{} = execution) do
    {clear_queue_values(execution), [{:broadcast, :queues_recalled}]}
  end

  @doc "Returns steering and follow-up queues in FIFO order."
  @spec queues(t()) :: {[content()], [content()]}
  def queues(%__MODULE__{} = execution),
    do: {execution.steering_queue, execution.follow_up_queue}

  @doc "Switches to plan mode while preserving the runtime phase."
  @spec enter_plan(t()) :: {t(), effects()}
  def enter_plan(%__MODULE__{} = execution) do
    {next, approval_effects} = clear_approval(execution)
    next = transition_mode(next, :plan)
    {next, approval_effects ++ [:announce_plan_mode, {:status_changed, :plan}]}
  end

  @doc "Switches from plan mode to execution mode."
  @spec enter_exec(t()) :: {:changed, t(), effects()} | {:unchanged, t(), effects()}
  def enter_exec(%__MODULE__{mode: :exec} = execution), do: {:unchanged, execution, []}

  def enter_exec(%__MODULE__{mode: :plan} = execution) do
    next = transition_mode(execution, :exec)
    {:changed, next, [:announce_exec_mode, {:status_changed, status(next)}]}
  end

  @doc "Aborts provider and tool work before returning to an inactive phase."
  @spec abort(t()) :: {t(), effects()}
  def abort(%__MODULE__{} = execution) do
    approval_effects = reject_approval_effects(execution)

    next = %{
      execution
      | phase: :idle,
        trust_levels: drop_turn_trust(execution.trust_levels),
        pending_auto_approvals: %{}
    }

    effects =
      approval_effects ++
        [
          :abort_provider,
          :abort_active_tools,
          {:append_system_message, "Aborted", :info},
          :notify_messages_changed
        ] ++ status_effect(next, :idle)

    {next, effects}
  end

  @doc "Moves any runtime phase into failure and clears turn-owned active resources."
  @spec fail(t(), String.t()) :: {t(), effects()}
  def fail(%__MODULE__{} = execution, message) when is_binary(message) do
    next = %{
      execution
      | phase: {:failure, message},
        trust_levels: drop_turn_trust(execution.trust_levels),
        pending_auto_approvals: %{}
    }

    effects =
      reject_approval_effects(execution) ++
        abort_active_tool_effects(execution, false) ++
        [
          {:notify, :error, message}
        ] ++
        status_effect(next, :error) ++
        [
          {:append_error_once, message},
          :notify_messages_changed,
          {:broadcast, {:error, message}}
        ]

    {next, effects}
  end

  @doc "Moves any runtime phase into provider failure while declaring only lifecycle effects."
  @spec provider_failed(t(), String.t()) :: {t(), effects()}
  def provider_failed(%__MODULE__{} = execution, message) when is_binary(message) do
    next = %{
      execution
      | phase: {:failure, message},
        trust_levels: drop_turn_trust(execution.trust_levels),
        pending_auto_approvals: %{}
    }

    effects =
      reject_approval_effects(execution) ++
        abort_active_tool_effects(execution, true) ++ status_effect(next, :error)

    {next, effects}
  end

  @doc "Updates the current provider failure presentation without changing its phase."
  @spec update_failure(t(), String.t()) :: {:ok, t()} | {:error, :invalid_phase, t()}
  def update_failure(%__MODULE__{phase: {:failure, _old}} = execution, message)
      when is_binary(message),
      do: {:ok, %{execution | phase: {:failure, message}}}

  def update_failure(%__MODULE__{} = execution, _message),
    do: {:error, :invalid_phase, execution}

  @doc "Clears a provider failure after provider recovery."
  @spec recover(t()) :: {:changed, t()} | {:unchanged, t()}
  def recover(%__MODULE__{phase: {:failure, _message}} = execution),
    do: {:changed, %{execution | phase: :idle}}

  def recover(%__MODULE__{} = execution), do: {:unchanged, execution}

  @doc "Begins ordered turn-completion effects."
  @spec begin_completion(t(), Event.token_usage() | nil) ::
          {:ok, t(), effects()} | {:error, :invalid_phase, t()}
  def begin_completion(%__MODULE__{phase: :idle} = execution, _usage),
    do: {:error, :invalid_phase, execution}

  def begin_completion(%__MODULE__{} = execution, usage) do
    next = activate(execution, :completion)

    effects =
      reject_approval_effects(execution) ++
        [:notify_completion, :collapse_thinking, {:apply_usage, usage}, :dispatch_stop]

    {:ok, next, effects}
  end

  @doc "Finishes completion, clearing turn trust before admitting queued work."
  @spec finish_completion(t()) ::
          {:idle, t(), effects()}
          | {:send_next, [content(), ...], t(), effects()}
          | {:error, :invalid_phase, t()}
  def finish_completion(%__MODULE__{phase: {:active, :completion, nil}} = execution) do
    pending = execution.steering_queue ++ execution.follow_up_queue

    next = %{
      execution
      | trust_levels: drop_turn_trust(execution.trust_levels),
        pending_auto_approvals: %{},
        steering_queue: [],
        follow_up_queue: []
    }

    finish_completion_result(next, pending)
  end

  def finish_completion(%__MODULE__{} = execution),
    do: {:error, :invalid_phase, execution}

  @doc "Returns a failed queued-send transition to idle without restoring consumed entries."
  @spec queued_send_failed(t()) :: {:ok, t(), effects()} | {:error, :invalid_phase, t()}
  def queued_send_failed(%__MODULE__{phase: {:active, :starting, nil}} = execution) do
    next = %{execution | phase: :idle}
    {:ok, next, status_effect(next, :idle)}
  end

  def queued_send_failed(%__MODULE__{} = execution),
    do: {:error, :invalid_phase, execution}

  @doc "Resets every turn resource for a fresh session."
  @spec reset(t()) :: {t(), effects()}
  def reset(%__MODULE__{} = execution) do
    next = new()
    {next, reject_approval_effects(execution) ++ [{:status_changed, :idle}]}
  end

  @doc "Restores an idle execution value after declaring cleanup for live work."
  @spec restore(t()) :: {t(), effects()}
  def restore(%__MODULE__{phase: {:active, _activity, _approval}} = execution) do
    effects =
      reject_approval_effects(execution) ++
        [:abort_provider] ++ abort_active_tool_effects(execution, true)

    {new(), effects}
  end

  def restore(%__MODULE__{}), do: {new(), []}

  @doc "Adds or replaces one tool trust decision."
  @spec put_trust(t(), String.t(), trust_scope()) :: t()
  def put_trust(%__MODULE__{} = execution, name, scope)
      when is_binary(name) and scope in [:session, :turn] do
    %{execution | trust_levels: Map.put(execution.trust_levels, name, scope)}
  end

  @doc "Removes one or all tool trust decisions."
  @spec revoke_trust(t(), String.t() | :all) :: t()
  def revoke_trust(%__MODULE__{} = execution, :all), do: %{execution | trust_levels: %{}}

  def revoke_trust(%__MODULE__{} = execution, name) when is_binary(name),
    do: %{execution | trust_levels: Map.delete(execution.trust_levels, name)}

  @doc "Returns all current tool trust decisions."
  @spec trust_levels(t()) :: %{String.t() => trust_scope()}
  def trust_levels(%__MODULE__{trust_levels: trust_levels}), do: trust_levels

  @doc "Returns the matching trust scope for one provider approval event."
  @spec trusted_scope(t(), Event.ToolApproval.t()) :: trust_scope() | nil
  def trusted_scope(%__MODULE__{trust_levels: trust_levels}, %Event.ToolApproval{} = event) do
    Map.get(trust_levels, trust_key(event.name, event.args)) || Map.get(trust_levels, event.name)
  end

  @doc "Validates and stores an edit boundary by absolute path."
  @spec set_boundary(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, String.t()}
  def set_boundary(%__MODULE__{} = execution, path, start_line, end_line)
      when is_binary(path) and is_integer(start_line) and is_integer(end_line) do
    case EditBoundary.new(start_line, end_line) do
      {:ok, boundary} ->
        abs_path = Path.expand(path)
        {:ok, %{execution | boundaries: Map.put(execution.boundaries, abs_path, boundary)}}

      {:error, _message} = error ->
        error
    end
  end

  @doc "Clears one edit boundary."
  @spec clear_boundary(t(), String.t()) :: t()
  def clear_boundary(%__MODULE__{} = execution, path) when is_binary(path) do
    %{execution | boundaries: Map.delete(execution.boundaries, Path.expand(path))}
  end

  @doc "Clears every edit boundary."
  @spec clear_boundaries(t()) :: t()
  def clear_boundaries(%__MODULE__{} = execution), do: %{execution | boundaries: %{}}

  @doc "Returns one edit boundary as its public line tuple."
  @spec boundary(t(), String.t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def boundary(%__MODULE__{} = execution, path) when is_binary(path) do
    case Map.get(execution.boundaries, Path.expand(path)) do
      nil -> nil
      %EditBoundary{start_line: start_line, end_line: end_line} -> {start_line, end_line}
    end
  end

  @doc "Returns true when turn state does not prevent detached-session reclamation."
  @spec reclaimable?(t()) :: boolean()
  def reclaimable?(%__MODULE__{} = execution) do
    not active?(execution) and execution.pending_auto_approvals == %{} and
      execution.steering_queue == [] and execution.follow_up_queue == []
  end

  @spec resolve_matching_approval(
          t(),
          activity(),
          ToolApproval.t(),
          String.t() | nil,
          approval_decision()
        ) ::
          {:ok, ToolApproval.t(), t(), effects()} | {:error, :approval_not_found, t()}
  defp resolve_matching_approval(execution, _activity, approval, approval_id, _decision)
       when is_binary(approval_id) and approval.tool_call_id != approval_id,
       do: {:error, :approval_not_found, execution}

  defp resolve_matching_approval(execution, activity, approval, _approval_id, decision) do
    next =
      execution
      |> maybe_put_decision_trust(approval, decision)
      |> then(&%{&1 | phase: {:active, activity, nil}})

    effects =
      [
        {:send_approval_response, approval, decision},
        {:record_approval_resolution, approval, decision}
      ] ++
        rejection_message_effects(approval, decision) ++
        [:notify_messages_changed, {:broadcast, {:approval_resolved, decision}}]

    {:ok, approval, next, effects}
  end

  @spec approval_from_event(Event.ToolApproval.t()) :: ToolApproval.t()
  defp approval_from_event(event) do
    ToolApproval.new(
      tool_call_id: event.tool_call_id,
      name: event.name,
      args: event.args,
      reply_to: event.reply_to
    )
  end

  @spec maybe_put_decision_trust(t(), ToolApproval.t(), approval_decision()) :: t()
  defp maybe_put_decision_trust(execution, approval, :approve_session),
    do: put_trust(execution, approval_trust_key(approval), :session)

  defp maybe_put_decision_trust(execution, approval, :approve_turn),
    do: put_trust(execution, approval_trust_key(approval), :turn)

  defp maybe_put_decision_trust(execution, _approval, _decision), do: execution

  @spec rejection_message_effects(ToolApproval.t(), approval_decision()) :: effects()
  defp rejection_message_effects(approval, :reject),
    do: [{:append_approval_rejection, approval}]

  defp rejection_message_effects(_approval, _decision), do: []

  @spec queue_prompt(t(), prompt_kind(), content()) :: prompt_admission()
  defp queue_prompt(%__MODULE__{} = execution, :steering, content) do
    next = %{execution | steering_queue: execution.steering_queue ++ [content]}
    {:queued, :steering, next, [{:broadcast, {:prompt_queued, content, :steering}}]}
  end

  defp queue_prompt(%__MODULE__{} = execution, :follow_up, content) do
    next = %{execution | follow_up_queue: execution.follow_up_queue ++ [content]}
    {:queued, :follow_up, next, [{:broadcast, {:prompt_queued, content, :follow_up}}]}
  end

  @spec clear_approval(t()) :: {t(), effects()}
  defp clear_approval(
         %__MODULE__{phase: {:active, activity, %ToolApproval{} = approval}} = execution
       ) do
    {%{execution | phase: {:active, activity, nil}}, [{:reject_approval, approval}]}
  end

  defp clear_approval(%__MODULE__{} = execution), do: {execution, []}

  @spec reject_approval_effects(t()) :: effects()
  defp reject_approval_effects(%__MODULE__{
         phase: {:active, _activity, %ToolApproval{} = approval}
       }),
       do: [{:reject_approval, approval}]

  defp reject_approval_effects(%__MODULE__{}), do: []

  @spec abort_active_tool_effects(t(), boolean()) :: effects()
  defp abort_active_tool_effects(%__MODULE__{} = execution, notify?) do
    active_tool_effects(active_tools(execution), notify?)
  end

  @spec active_tool_effects([active_tool()], boolean()) :: effects()
  defp active_tool_effects([], _notify?), do: []
  defp active_tool_effects([_tool | _rest], false), do: [:abort_active_tools]

  defp active_tool_effects([_tool | _rest], true),
    do: [:abort_active_tools, :notify_messages_changed]

  @spec activate(t(), activity()) :: t()
  defp activate(%__MODULE__{} = execution, activity),
    do: %{execution | phase: {:active, activity, nil}}

  @spec put_activity(t(), activity()) :: t()
  defp put_activity(
         %__MODULE__{phase: {:active, _old_activity, approval}} = execution,
         activity
       ),
       do: %{execution | phase: {:active, activity, approval}}

  @spec completed_tool_activity([active_tool()]) ::
          :completion | {:tool_execution, [active_tool(), ...]}
  defp completed_tool_activity([]), do: :completion
  defp completed_tool_activity([_tool | _rest] = tools), do: {:tool_execution, tools}

  @spec activity_phase(activity()) :: :starting | :thinking | :tool_execution | :completion
  defp activity_phase(:starting), do: :starting
  defp activity_phase(:thinking), do: :thinking
  defp activity_phase(:completion), do: :completion
  defp activity_phase({:tool_execution, [_tool | _rest]}), do: :tool_execution

  @spec activity_status(activity()) :: :idle | :thinking | :tool_executing
  defp activity_status(:starting), do: :idle
  defp activity_status(:thinking), do: :thinking
  defp activity_status(:completion), do: :tool_executing
  defp activity_status({:tool_execution, [_tool | _rest]}), do: :tool_executing

  @spec transition_mode(t(), mode()) :: t()
  defp transition_mode(%__MODULE__{} = execution, mode), do: struct!(execution, mode: mode)

  @spec status_effect(t(), status()) :: effects()
  defp status_effect(%__MODULE__{mode: :plan} = execution, _status),
    do: plan_idle_effect(reclaimable?(execution))

  defp status_effect(%__MODULE__{}, status), do: [{:status_changed, status}]

  @spec plan_idle_effect(boolean()) :: effects()
  defp plan_idle_effect(true), do: [:reconsider_idle_gc]
  defp plan_idle_effect(false), do: []

  @spec finish_completion_result(t(), [content()]) ::
          {:idle, t(), effects()} | {:send_next, [content(), ...], t(), effects()}
  defp finish_completion_result(next, []) do
    idle = %{next | phase: :idle}
    {:idle, idle, status_effect(idle, :idle)}
  end

  defp finish_completion_result(next, [_entry | _rest] = pending) do
    starting = activate(next, :starting)
    {:send_next, pending, starting, []}
  end

  @spec clear_queue_values(t()) :: t()
  defp clear_queue_values(execution),
    do: %{execution | steering_queue: [], follow_up_queue: []}

  @spec drop_turn_trust(%{String.t() => trust_scope()}) :: %{String.t() => trust_scope()}
  defp drop_turn_trust(trust_levels),
    do: Map.reject(trust_levels, fn {_name, scope} -> scope == :turn end)

  @spec approval_trust_key(ToolApproval.t()) :: String.t()
  defp approval_trust_key(%ToolApproval{name: name, args: args}), do: trust_key(name, args)

  @spec trust_key(String.t(), map()) :: String.t()
  defp trust_key("shell", args) when is_map(args), do: shell_trust_key(args)

  defp trust_key("call_mcp_tool", args) when is_map(args),
    do: hashed_trust_key("call_mcp_tool", args)

  defp trust_key("list_mcp_tools", args) when is_map(args),
    do: hashed_trust_key("list_mcp_tools", args)

  defp trust_key("mcp_" <> _rest = name, args) when is_map(args), do: hashed_trust_key(name, args)
  defp trust_key(name, _args), do: name

  @spec shell_trust_key(map()) :: String.t()
  defp shell_trust_key(args) do
    string_args = Map.new(args, fn {key, value} -> {to_string(key), value} end)

    case Map.get(string_args, "command") do
      command when is_binary(command) -> "shell:#{command}"
      _other -> hashed_trust_key("shell", args)
    end
  end

  @spec hashed_trust_key(String.t(), map()) :: String.t()
  defp hashed_trust_key(name, args) do
    hash =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(args))
      |> Base.encode16(case: :lower)

    "#{name}:#{hash}"
  end
end
