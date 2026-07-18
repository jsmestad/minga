defmodule MingaAgent.Session.TurnExecution do
  @moduledoc """
  Owns one session's execution mode, runtime phase, and turn-scoped resources.

  Transitions are pure. They return the next owned value or a domain outcome; `MingaAgent.Session` remains responsible for provider calls, notifications, broadcasts, transcript updates, and persistence.
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
  @type prompt_admission :: {:send_now, t()} | {:queued, t()}

  @typedoc "An active provider tool identified by its stable call ID."
  @type active_tool :: {tool_call_id :: String.t(), name :: String.t()}

  @typedoc "Provider activity within one active turn."
  @type activity ::
          :starting | :thinking | :completion | {:tool_execution, [active_tool(), ...]}

  @typedoc "Runtime phase. Approval and nonterminal error presentation are orthogonal to provider activity within an active turn."
  @type phase ::
          :idle
          | {:active, activity(), ToolApproval.t() | nil, String.t() | nil}
          | {:failure, String.t()}

  @typedoc "Public status retained at the Session API boundary."
  @type status :: :idle | :plan | :thinking | :tool_executing | :error

  @typedoc "Supported approval response."
  @type approval_decision :: :approve | :approve_session | :approve_turn | :reject

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
  def phase(%__MODULE__{phase: {:active, _activity, %ToolApproval{}, _error}}),
    do: :approval_waiting

  def phase(%__MODULE__{phase: {:active, activity, nil, _error}}),
    do: activity_phase(activity)

  def phase(%__MODULE__{phase: {:failure, _message}}), do: :failure
  def phase(%__MODULE__{phase: :idle}), do: :idle

  @doc "Derives the stable public Session status."
  @spec status(t()) :: status()
  def status(%__MODULE__{mode: :plan}), do: :plan
  def status(%__MODULE__{phase: :idle}), do: :idle

  def status(%__MODULE__{phase: {:active, _activity, _approval, message}})
      when is_binary(message),
      do: :error

  def status(%__MODULE__{phase: {:active, activity, _approval, nil}}),
    do: activity_status(activity)

  def status(%__MODULE__{phase: {:failure, _message}}), do: :error

  @doc "Returns true while provider work belongs to the current turn."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{phase: {:active, _activity, _approval, _error}}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "Returns the current pending approval, if any."
  @spec pending_approval(t()) :: ToolApproval.t() | nil
  def pending_approval(%__MODULE__{phase: {:active, _activity, approval, _error}}),
    do: approval

  def pending_approval(%__MODULE__{}), do: nil

  @doc "Returns the current error message, if any."
  @spec error(t()) :: String.t() | nil
  def error(%__MODULE__{phase: {:active, _activity, _approval, message}})
      when is_binary(message),
      do: message

  def error(%__MODULE__{phase: {:failure, message}}), do: message
  def error(%__MODULE__{}), do: nil

  @doc "Returns active tools in provider start order."
  @spec active_tools(t()) :: [active_tool()]
  def active_tools(%__MODULE__{
        phase: {:active, {:tool_execution, tools}, _approval, _error}
      }),
      do: tools

  def active_tools(%__MODULE__{}), do: []

  @doc "Returns the most recently started active tool name."
  @spec active_tool_name(t()) :: String.t() | nil
  def active_tool_name(%__MODULE__{
        phase: {:active, {:tool_execution, tools}, _approval, _error}
      }) do
    case List.last(tools) do
      {_id, name} -> name
      nil -> nil
    end
  end

  def active_tool_name(%__MODULE__{}), do: nil

  @doc "Returns the name for one active tool call."
  @spec tool_name(t(), String.t()) :: {:ok, String.t()} | {:error, :tool_not_active}
  def tool_name(
        %__MODULE__{phase: {:active, {:tool_execution, tools}, _approval, _error}},
        tool_call_id
      )
      when is_binary(tool_call_id) do
    case List.keyfind(tools, tool_call_id, 0) do
      {_id, name} -> {:ok, name}
      nil -> {:error, :tool_not_active}
    end
  end

  def tool_name(%__MODULE__{}, tool_call_id) when is_binary(tool_call_id),
    do: {:error, :tool_not_active}

  @doc "Begins a provider turn from an inactive state."
  @spec begin_turn(t()) :: {:ok, t()} | {:error, :turn_active}
  def begin_turn(%__MODULE__{phase: :idle} = execution),
    do: {:ok, activate(execution, :starting)}

  def begin_turn(%__MODULE__{phase: {:failure, _message}} = execution),
    do: {:ok, activate(execution, :starting)}

  def begin_turn(%__MODULE__{phase: {:active, _activity, _approval, _error}}),
    do: {:error, :turn_active}

  @doc "Accepts the provider's turn-start event."
  @spec provider_started(t()) :: {:ok, t()} | {:error, :invalid_phase}
  def provider_started(%__MODULE__{phase: {:active, :starting, nil, _error}} = execution),
    do: {:ok, activate(execution, :thinking)}

  def provider_started(%__MODULE__{}),
    do: {:error, :invalid_phase}

  @doc "Moves an active turn into approval waiting."
  @spec request_approval(t(), ToolApproval.t()) :: {:accepted, t()} | :rejected
  def request_approval(
        %__MODULE__{phase: {:active, activity, nil, error}} = execution,
        %ToolApproval{} = approval
      ),
      do: {:accepted, %{execution | phase: {:active, activity, approval, error}}}

  def request_approval(%__MODULE__{}, %ToolApproval{}), do: :rejected

  @doc "Resolves the matching pending approval and restores the active runtime phase."
  @spec resolve_approval(t(), String.t() | nil, approval_decision()) ::
          {:ok, ToolApproval.t(), t()} | {:error, :approval_not_found | :no_pending_approval}
  def resolve_approval(
        %__MODULE__{
          phase: {:active, activity, %ToolApproval{} = approval, error}
        } = execution,
        approval_id,
        decision
      )
      when decision in [:approve, :approve_session, :approve_turn, :reject] do
    resolve_matching_approval(execution, activity, approval, error, approval_id, decision)
  end

  def resolve_approval(%__MODULE__{}, _approval_id, _decision),
    do: {:error, :no_pending_approval}

  @doc "Records a trusted approval, or rejects it outside an admitted turn."
  @spec auto_approve(t(), Event.ToolApproval.t(), trust_scope()) ::
          {:approved, ToolApproval.t(), t()} | {:rejected, ToolApproval.t()}
  def auto_approve(
        %__MODULE__{phase: :idle},
        %Event.ToolApproval{} = event,
        _scope
      ),
      do: {:rejected, approval_from_event(event)}

  def auto_approve(
        %__MODULE__{phase: {:failure, _message}},
        %Event.ToolApproval{} = event,
        _scope
      ),
      do: {:rejected, approval_from_event(event)}

  def auto_approve(%__MODULE__{} = execution, %Event.ToolApproval{} = event, scope)
      when scope in [:session, :turn] do
    next = %{
      execution
      | pending_auto_approvals:
          Map.put(execution.pending_auto_approvals, event.tool_call_id, scope)
    }

    {:approved, approval_from_event(event), next}
  end

  @doc "Starts one tool and records its stable identity."
  @spec tool_started(t(), Event.ToolStart.t()) ::
          {:ok, trust_scope() | nil, t()} | {:error, :invalid_phase | :tool_already_active}
  def tool_started(
        %__MODULE__{
          phase: {:active, {:tool_execution, tools}, approval, _error}
        } = execution,
        %Event.ToolStart{} = event
      ),
      do: start_tool(execution, tools, approval, event)

  def tool_started(
        %__MODULE__{phase: {:active, _activity, approval, _error}} = execution,
        %Event.ToolStart{} = event
      ),
      do: start_tool(execution, [], approval, event)

  def tool_started(%__MODULE__{}, %Event.ToolStart{}),
    do: {:error, :invalid_phase}

  @doc "Completes one matching active tool and rejects stale or duplicate completions."
  @spec tool_completed(t(), Event.ToolEnd.t()) ::
          {:ok, t()} | {:error, :tool_not_active}
  def tool_completed(
        %__MODULE__{
          phase: {:active, {:tool_execution, tools}, approval, error}
        } = execution,
        %Event.ToolEnd{} = event
      ) do
    case List.keytake(tools, event.tool_call_id, 0) do
      {{_id, _name}, remaining} ->
        next = %{
          execution
          | phase: {:active, completed_tool_activity(remaining), approval, error},
            pending_auto_approvals:
              Map.delete(execution.pending_auto_approvals, event.tool_call_id)
        }

        {:ok, next}

      nil ->
        {:error, :tool_not_active}
    end
  end

  def tool_completed(%__MODULE__{}, %Event.ToolEnd{}),
    do: {:error, :tool_not_active}

  @doc "Admits a prompt by starting an inactive turn or queueing behind an active turn."
  @spec admit_prompt(t(), prompt_kind(), content()) :: prompt_admission()
  def admit_prompt(
        %__MODULE__{phase: {:active, _activity, _approval, _error}} = execution,
        kind,
        content
      )
      when kind in [:steering, :follow_up] do
    queue_prompt(execution, kind, content)
  end

  def admit_prompt(%__MODULE__{} = execution, kind, _content)
      when kind in [:steering, :follow_up] do
    {:ok, next} = begin_turn(execution)
    {:send_now, next}
  end

  @doc "Dequeues steering prompts without changing follow-up admission."
  @spec dequeue_steering(t()) :: {[content()], t()}
  def dequeue_steering(%__MODULE__{} = execution) do
    {execution.steering_queue, %{execution | steering_queue: []}}
  end

  @doc "Returns and clears both prompt queues."
  @spec recall_queues(t()) :: {{[content()], [content()]}, t()}
  def recall_queues(%__MODULE__{} = execution),
    do: {queues(execution), clear_queue_values(execution)}

  @doc "Clears both prompt queues."
  @spec clear_queues(t()) :: t()
  def clear_queues(%__MODULE__{} = execution), do: clear_queue_values(execution)

  @doc "Returns steering and follow-up queues in FIFO order."
  @spec queues(t()) :: {[content()], [content()]}
  def queues(%__MODULE__{} = execution),
    do: {execution.steering_queue, execution.follow_up_queue}

  @doc "Switches to plan mode while preserving the runtime phase."
  @spec enter_plan(t()) :: t()
  def enter_plan(%__MODULE__{} = execution) do
    execution
    |> clear_approval()
    |> transition_mode(:plan)
  end

  @doc "Switches from plan mode to execution mode."
  @spec enter_exec(t()) :: {:changed, t()} | :unchanged
  def enter_exec(%__MODULE__{mode: :exec}), do: :unchanged

  def enter_exec(%__MODULE__{mode: :plan} = execution),
    do: {:changed, transition_mode(execution, :exec)}

  @doc "Aborts provider and tool work before returning to an inactive phase."
  @spec abort(t()) :: t()
  def abort(%__MODULE__{} = execution) do
    %{
      execution
      | phase: :idle,
        trust_levels: drop_turn_trust(execution.trust_levels),
        pending_auto_approvals: %{}
    }
  end

  @doc "Moves any runtime phase into failure and clears turn-owned active resources."
  @spec fail(t(), String.t()) :: t()
  def fail(%__MODULE__{} = execution, message) when is_binary(message) do
    %{
      execution
      | phase: {:failure, message},
        trust_levels: drop_turn_trust(execution.trust_levels),
        pending_auto_approvals: %{}
    }
  end

  @doc "Records a provider-reported error without discarding active turn work."
  @spec report_error(t(), String.t()) :: t()
  def report_error(
        %__MODULE__{phase: {:active, activity, approval, _old_error}} = execution,
        message
      )
      when is_binary(message),
      do: %{execution | phase: {:active, activity, approval, message}}

  def report_error(%__MODULE__{} = execution, message) when is_binary(message),
    do: fail(execution, message)

  @doc "Updates the current provider failure presentation without changing its phase."
  @spec update_failure(t(), String.t()) :: {:ok, t()} | {:error, :invalid_phase}
  def update_failure(%__MODULE__{phase: {:failure, _old}} = execution, message)
      when is_binary(message),
      do: {:ok, %{execution | phase: {:failure, message}}}

  def update_failure(%__MODULE__{}, _message),
    do: {:error, :invalid_phase}

  @doc "Clears a provider failure after provider recovery."
  @spec recover(t()) :: {:changed, t()} | :unchanged
  def recover(%__MODULE__{phase: {:failure, _message}} = execution),
    do: {:changed, %{execution | phase: :idle}}

  def recover(%__MODULE__{}), do: :unchanged

  @doc "Moves an admitted turn into completion."
  @spec begin_completion(t()) :: {:ok, t()} | {:error, :invalid_phase}
  def begin_completion(%__MODULE__{phase: :idle}),
    do: {:error, :invalid_phase}

  def begin_completion(%__MODULE__{} = execution),
    do: {:ok, activate(execution, :completion)}

  @doc "Finishes completion, clearing turn trust before admitting queued work."
  @spec finish_completion(t()) ::
          {:idle, t()}
          | {:send_next, [content(), ...], t()}
          | {:error, :invalid_phase}
  def finish_completion(%__MODULE__{phase: {:active, :completion, nil, _error}} = execution) do
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

  def finish_completion(%__MODULE__{}),
    do: {:error, :invalid_phase}

  @doc "Returns a failed queued-send transition to idle without restoring consumed entries."
  @spec queued_send_failed(t()) :: {:ok, t()} | {:error, :invalid_phase}
  def queued_send_failed(%__MODULE__{phase: {:active, :starting, nil, _error}} = execution),
    do: {:ok, %{execution | phase: :idle}}

  def queued_send_failed(%__MODULE__{}),
    do: {:error, :invalid_phase}

  @doc "Resets every turn resource for a fresh session."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{}), do: new()

  @doc "Restores an idle execution value after live work is cleaned up."
  @spec restore(t()) :: t()
  def restore(%__MODULE__{}), do: new()

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
          String.t() | nil,
          approval_decision()
        ) ::
          {:ok, ToolApproval.t(), t()} | {:error, :approval_not_found}
  defp resolve_matching_approval(
         _execution,
         _activity,
         approval,
         _error,
         approval_id,
         _decision
       )
       when is_binary(approval_id) and approval.tool_call_id != approval_id,
       do: {:error, :approval_not_found}

  defp resolve_matching_approval(execution, activity, approval, error, _approval_id, decision) do
    next =
      execution
      |> maybe_put_decision_trust(approval, decision)
      |> then(&%{&1 | phase: {:active, activity, nil, error}})

    {:ok, approval, next}
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

  @spec queue_prompt(t(), prompt_kind(), content()) :: prompt_admission()
  defp queue_prompt(%__MODULE__{} = execution, :steering, content) do
    next = %{execution | steering_queue: execution.steering_queue ++ [content]}
    {:queued, next}
  end

  defp queue_prompt(%__MODULE__{} = execution, :follow_up, content) do
    next = %{execution | follow_up_queue: execution.follow_up_queue ++ [content]}
    {:queued, next}
  end

  @spec clear_approval(t()) :: t()
  defp clear_approval(
         %__MODULE__{phase: {:active, activity, %ToolApproval{}, error}} = execution
       ),
       do: %{execution | phase: {:active, activity, nil, error}}

  defp clear_approval(%__MODULE__{} = execution), do: execution

  @spec start_tool(t(), [active_tool()], ToolApproval.t() | nil, Event.ToolStart.t()) ::
          {:ok, trust_scope() | nil, t()} | {:error, :tool_already_active}
  defp start_tool(execution, tools, approval, event) do
    if List.keymember?(tools, event.tool_call_id, 0) do
      {:error, :tool_already_active}
    else
      {scope, pending_auto_approvals} =
        Map.pop(execution.pending_auto_approvals, event.tool_call_id)

      next = %{
        execution
        | phase:
            {:active, {:tool_execution, tools ++ [{event.tool_call_id, event.name}]}, approval,
             nil},
          pending_auto_approvals: pending_auto_approvals
      }

      {:ok, scope, next}
    end
  end

  @spec activate(t(), activity()) :: t()
  defp activate(%__MODULE__{} = execution, activity),
    do: %{execution | phase: {:active, activity, nil, nil}}

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

  @spec finish_completion_result(t(), [content()]) ::
          {:idle, t()} | {:send_next, [content(), ...], t()}
  defp finish_completion_result(next, []) do
    {:idle, %{next | phase: :idle}}
  end

  defp finish_completion_result(next, [_entry | _rest] = pending) do
    {:send_next, pending, activate(next, :starting)}
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
