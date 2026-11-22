defmodule MingaEditor.State.Agent do
  @moduledoc """
  Agent rendering cache: status, error, pending approval, and spinner timer.

  This struct is **not** the source of truth for the active agent session.
  The session pid lives on the active `Tab` in the Traditional shell and
  is read through the active shell runtime.

  On local tab arrival, `MingaEditor.Agent.Arrival` installs the active Session's ordered snapshot without retaining approval or error per tab.

  Domain-only state (status, model, provider, session ID) lives in the
  composed `MingaAgent.RuntimeState` struct at `runtime`. Lifecycle
  monitoring (Process.monitor) is handled exclusively by
  `MingaAgent.SessionManager`, which broadcasts `:agent_session_stopped`
  events via `Minga.Events`.

  UI state (scroll, prompt, focus, search, toasts) lives in `UIState`
  on `EditorState.workspace.agent_ui`.
  """

  alias MingaAgent.Question
  alias MingaAgent.Question.Target, as: QuestionTarget
  alias MingaAgent.RuntimeState
  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.PendingQuestion

  @typedoc "Agent status (delegated from RuntimeState)."
  @type status :: RuntimeState.status()

  @typedoc "Presentation status calculated from runtime and the exact pending approval."
  @type display_status :: status() | :approval_waiting

  @typedoc "A displayed approval and its originating Session attachment."
  @type approval :: PendingApproval.t()

  @typedoc "Agent rendering cache."
  @type t :: %__MODULE__{
          runtime: RuntimeState.t(),
          error: String.t() | nil,
          spinner_timer: {:ok, :timer.tref()} | nil,
          pending_approval: approval() | nil,
          pending_question: PendingQuestion.t() | nil,
          queue_target: {pid(), MingaAgent.Session.queue_target()} | nil,
          stop_target: {pid(), {String.t(), String.t()}} | nil
        }

  defstruct runtime: %RuntimeState{},
            error: nil,
            spinner_timer: nil,
            pending_approval: nil,
            pending_question: nil,
            queue_target: nil,
            stop_target: nil

  # ── Status ──────────────────────────────────────────────────────────────────

  @doc "Returns the agent lifecycle status from RuntimeState."
  @spec status(t()) :: status()
  def status(%__MODULE__{runtime: rt}), do: rt.status

  @doc "Returns the presentation status without changing execution or busy state."
  @spec display_status(t()) :: display_status()
  def display_status(%__MODULE__{runtime: runtime, pending_approval: pending_approval}) do
    MingaAgent.Session.TurnExecution.display_status(
      runtime.status,
      PendingApproval.public(pending_approval)
    )
  end

  @doc "Sets the agent status (delegates to RuntimeState)."
  @spec set_status(t(), status()) :: t()
  def set_status(%__MODULE__{} = agent, status) do
    runtime =
      agent.runtime
      |> RuntimeState.set_status(status)
      |> maybe_clear_active_tool_name(status)

    %{agent | runtime: runtime}
  end

  @doc "Returns the active tool name from RuntimeState."
  @spec active_tool_name(t()) :: String.t() | nil
  def active_tool_name(%__MODULE__{runtime: rt}), do: rt.active_tool_name

  @doc "Sets the active tool name (delegates to RuntimeState)."
  @spec set_active_tool_name(t(), String.t() | nil) :: t()
  def set_active_tool_name(%__MODULE__{} = agent, name) do
    %{agent | runtime: RuntimeState.set_active_tool_name(agent.runtime, name)}
  end

  @doc "Clears the active tool name (delegates to RuntimeState)."
  @spec clear_active_tool_name(t()) :: t()
  def clear_active_tool_name(%__MODULE__{} = agent) do
    %{agent | runtime: RuntimeState.clear_active_tool_name(agent.runtime)}
  end

  @doc "Sets the agent into an error state with a message."
  @spec set_error(t(), String.t()) :: t()
  def set_error(%__MODULE__{} = agent, message) do
    runtime =
      agent.runtime
      |> RuntimeState.set_status(:error)
      |> RuntimeState.clear_active_tool_name()

    %{agent | runtime: runtime, error: message}
  end

  @spec maybe_clear_active_tool_name(RuntimeState.t(), status()) :: RuntimeState.t()
  defp maybe_clear_active_tool_name(runtime, :tool_executing), do: runtime

  defp maybe_clear_active_tool_name(runtime, _status),
    do: RuntimeState.clear_active_tool_name(runtime)

  # ── Cache reset ─────────────────────────────────────────────────────────────

  @doc """
  Resets the rendering cache to idle defaults.

  Called when the active tab/card no longer has a session, or when its
  session has been torn down. The session pid itself lives on the tab
  or card, not on this struct, so callers must clear that separately
  via `EditorState.set_tab_session/3` (Traditional) or by clearing the
  shell-owned session field.
  """
  @spec reset_cache(t()) :: t()
  def reset_cache(%__MODULE__{} = agent) do
    runtime =
      agent.runtime
      |> RuntimeState.set_status(:idle)
      |> RuntimeState.clear_active_tool_name()

    %{
      agent
      | runtime: runtime,
        error: nil,
        pending_approval: nil,
        pending_question: nil,
        queue_target: nil,
        stop_target: nil
    }
  end

  # ── Tool approval ──────────────────────────────────────────────────────────

  @doc "Installs a pending approval bound to its originating Session."
  @spec set_pending_approval(t(), approval()) :: t()
  def set_pending_approval(%__MODULE__{} = agent, %PendingApproval{} = approval) do
    %{agent | pending_approval: approval}
  end

  @doc "Clears the pending tool approval."
  @spec clear_pending_approval(t()) :: t()
  def clear_pending_approval(%__MODULE__{} = agent) do
    %{agent | pending_approval: nil}
  end

  @doc "Projects a saved queue action target only for the Session attached to the workspace."
  @spec project_queue_target(t(), pid(), MingaAgent.Session.queue_target() | nil) :: t()
  def project_queue_target(%__MODULE__{} = agent, _session, nil),
    do: %{agent | queue_target: nil}

  def project_queue_target(%__MODULE__{} = agent, session, {_, _, _} = target),
    do: %{agent | queue_target: {session, target}}

  @doc "Projects the active turn identity from its attached Session."
  @spec project_stop_target(t(), pid(), {String.t(), String.t()} | nil) :: t()
  def project_stop_target(%__MODULE__{} = agent, _session, nil), do: %{agent | stop_target: nil}

  def project_stop_target(%__MODULE__{} = agent, session, {_, _} = target),
    do: %{agent | stop_target: {session, target}}

  @doc "Replaces the question projection for the attached Session."
  @spec project_question(t(), pid(), {QuestionTarget.t(), Question.t()} | nil) :: t()
  def project_question(%__MODULE__{} = agent, _session, nil),
    do: %{agent | pending_question: nil}

  def project_question(
        %__MODULE__{pending_question: %PendingQuestion{session: session, target: target}} = agent,
        session,
        {target, _question}
      ),
      do: agent

  def project_question(%__MODULE__{} = agent, session, {target, question}),
    do: %{agent | pending_question: PendingQuestion.new(session, target, question)}

  @doc "Clears only the question retired by its originating Session."
  @spec retire_question(t(), pid(), QuestionTarget.t()) :: t()
  def retire_question(
        %__MODULE__{pending_question: %PendingQuestion{session: session, target: target}} = agent,
        session,
        target
      ),
      do: %{agent | pending_question: nil}

  def retire_question(%__MODULE__{} = agent, _session, _target), do: agent

  @doc "Returns the exact displayed approval attachment or a distinct refusal."
  @spec approval_for(t(), ApprovalTarget.t()) ::
          {:ok, approval()} | {:error, :approval_not_presented | :stale_attachment}
  def approval_for(
        %__MODULE__{
          pending_approval: %PendingApproval{approval: %PublicApproval{target: target}} = approval
        },
        %ApprovalTarget{} = target
      ),
      do: {:ok, approval}

  def approval_for(%__MODULE__{pending_approval: nil}, %ApprovalTarget{}),
    do: {:error, :approval_not_presented}

  def approval_for(%__MODULE__{}, %ApprovalTarget{}), do: {:error, :stale_attachment}

  @doc "Clears only the approval still bound to the resolved target and Session."
  @spec clear_approval(t(), ApprovalTarget.t(), pid()) :: t()
  def clear_approval(
        %__MODULE__{
          pending_approval: %PendingApproval{
            session_pid: session_pid,
            approval: %PublicApproval{target: target}
          }
        } = agent,
        %ApprovalTarget{} = target,
        session_pid
      )
      when is_pid(session_pid),
      do: %{agent | pending_approval: nil}

  def clear_approval(%__MODULE__{} = agent, %ApprovalTarget{}, session_pid)
      when is_pid(session_pid),
      do: agent

  @doc "Applies the render-cache fields returned by an agent session snapshot."
  @spec apply_session_snapshot(
          t(),
          pid(),
          status(),
          PublicApproval.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) :: t()
  def apply_session_snapshot(
        %__MODULE__{} = agent,
        session_pid,
        status,
        pending_approval,
        error,
        active_tool_name
      )
      when is_pid(session_pid) do
    runtime =
      agent.runtime
      |> RuntimeState.set_status(status)
      |> apply_active_tool_name(status, active_tool_name)

    %{
      agent
      | runtime: runtime,
        pending_approval: bind_approval(session_pid, pending_approval),
        error: error
    }
  end

  @spec bind_approval(pid(), PublicApproval.t() | nil) :: approval() | nil
  defp bind_approval(_session_pid, nil), do: nil

  defp bind_approval(session_pid, %PublicApproval{} = approval),
    do: PendingApproval.new(session_pid, approval)

  @spec apply_active_tool_name(RuntimeState.t(), status(), String.t() | nil) :: RuntimeState.t()
  defp apply_active_tool_name(runtime, :tool_executing, active_tool_name) do
    RuntimeState.set_active_tool_name(runtime, active_tool_name)
  end

  defp apply_active_tool_name(runtime, _status, _active_tool_name) do
    RuntimeState.clear_active_tool_name(runtime)
  end

  # ── Spinner timer ───────────────────────────────────────────────────────────

  @doc "Starts the spinner timer if not already running."
  @spec start_spinner_timer(t()) :: t()
  def start_spinner_timer(%__MODULE__{spinner_timer: nil} = agent) do
    timer = :timer.send_interval(100, :agent_spinner_tick)
    %{agent | spinner_timer: timer}
  end

  def start_spinner_timer(%__MODULE__{} = agent), do: agent

  @doc "Stops the spinner timer if running."
  @spec stop_spinner_timer(t()) :: t()
  def stop_spinner_timer(%__MODULE__{spinner_timer: nil} = agent), do: agent

  def stop_spinner_timer(%__MODULE__{spinner_timer: {:ok, ref}} = agent) do
    :timer.cancel(ref)
    %{agent | spinner_timer: nil}
  end

  # ── Queries ─────────────────────────────────────────────────────────────────

  @doc "Returns true if the agent is actively working."
  @spec busy?(t()) :: boolean()
  def busy?(%__MODULE__{runtime: rt}), do: RuntimeState.busy?(rt)
end
