defmodule MingaEditor.State.Agent do
  @moduledoc """
  Agent session lifecycle state: session pid, status, approvals.

  Lifecycle monitoring (Process.monitor) is handled exclusively by
  `MingaAgent.SessionManager`, which broadcasts `:agent_session_stopped`
  events via `Minga.Events`. The Editor subscribes to those events
  instead of monitoring session PIDs directly.

  UI state (scroll, prompt, focus, search, toasts) lives in `UIState`
  on `EditorState.agent_ui`. This module holds only process-aware,
  action-heavy fields that manage the agent session.
  """

  @typedoc "Agent status."
  @type status :: :idle | :thinking | :tool_executing | :error | nil

  @typedoc "Pending tool approval data."
  @type approval :: MingaAgent.ToolApproval.t()

  @typedoc "Agent session state."
  @type t :: %__MODULE__{
          session: pid() | nil,
          status: status(),
          error: String.t() | nil,
          spinner_timer: {:ok, :timer.tref()} | nil,
          buffer: pid() | nil,
          pending_approval: approval() | nil,
          session_history: [pid()]
        }

  defstruct session: nil,
            status: nil,
            error: nil,
            spinner_timer: nil,
            buffer: nil,
            pending_approval: nil,
            session_history: []

  # ── Status ──────────────────────────────────────────────────────────────────

  @doc "Sets the agent status."
  @spec set_status(t(), status()) :: t()
  def set_status(%__MODULE__{} = agent, status), do: %{agent | status: status}

  @doc "Sets the agent into an error state with a message."
  @spec set_error(t(), String.t()) :: t()
  def set_error(%__MODULE__{} = agent, message) do
    %{agent | status: :error, error: message}
  end

  # ── Session lifecycle ───────────────────────────────────────────────────────

  @doc "Stores the session pid and sets status to :idle. Archives the previous session. Lifecycle monitoring is handled by SessionManager."
  @spec set_session(t(), pid()) :: t()
  def set_session(%__MODULE__{session: nil} = agent, pid) when is_pid(pid) do
    %{agent | session: pid, status: :idle}
  end

  def set_session(%__MODULE__{session: old_pid} = agent, pid)
      when is_pid(pid) and is_pid(old_pid) do
    history = [old_pid | agent.session_history] |> Enum.uniq()
    %{agent | session: pid, status: :idle, session_history: history}
  end

  @doc "Sets the agent buffer pid."
  @spec set_buffer(t(), pid()) :: t()
  def set_buffer(%__MODULE__{} = agent, pid) when is_pid(pid) do
    %{agent | buffer: pid}
  end

  @doc "Returns all session pids (active + history), most recent first."
  @spec all_sessions(t()) :: [pid()]
  def all_sessions(%__MODULE__{session: nil} = agent), do: agent.session_history

  def all_sessions(%__MODULE__{} = agent) do
    [agent.session | agent.session_history]
  end

  @doc "Switches to a session from history, moving current to history. Lifecycle monitoring is handled by SessionManager."
  @spec switch_session(t(), pid()) :: t()
  def switch_session(%__MODULE__{session: nil} = agent, pid)
      when is_pid(pid) do
    history = List.delete(agent.session_history, pid)
    %{agent | session: pid, status: :idle, session_history: history}
  end

  def switch_session(%__MODULE__{session: current} = agent, pid)
      when is_pid(pid) and is_pid(current) do
    history =
      [current | agent.session_history]
      |> List.delete(pid)
      |> Enum.uniq()

    %{agent | session: pid, status: :idle, session_history: history}
  end

  @doc "Clears the session reference and resets status to :idle. Lifecycle monitoring is handled by SessionManager."
  @spec clear_session(t()) :: t()
  def clear_session(%__MODULE__{} = agent) do
    %{agent | session: nil, status: :idle}
  end

  # ── Tool approval ──────────────────────────────────────────────────────────

  @doc "Sets a pending tool approval."
  @spec set_pending_approval(t(), approval()) :: t()
  def set_pending_approval(%__MODULE__{} = agent, approval) when is_map(approval) do
    %{agent | pending_approval: approval}
  end

  @doc "Clears the pending tool approval."
  @spec clear_pending_approval(t()) :: t()
  def clear_pending_approval(%__MODULE__{} = agent) do
    %{agent | pending_approval: nil}
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
  def busy?(%__MODULE__{status: s}) when s in [:thinking, :tool_executing], do: true
  def busy?(%__MODULE__{}), do: false
end
