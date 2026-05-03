defmodule MingaEditor.State.Agent do
  @moduledoc """
  Agent rendering cache: status, error, pending approval, spinner timer,
  and the agent buffer pid.

  This struct is **not** the source of truth for the active agent session.
  The session pid lives on the active `Tab` (Traditional shell) or the
  zoomed `Card` (Board shell). `MingaEditor.State.AgentAccess.session/1`
  reads it through the `Shell.active_session/1` callback.

  After a tab switch, `MingaEditor.State.rebuild_agent_from_session/2`
  repopulates the cache fields below from the incoming tab's session
  process via `MingaAgent.Session.editor_snapshot/1`.

  Domain-only state (status, model, provider, session ID) lives in the
  composed `MingaAgent.RuntimeState` struct at `runtime`. Lifecycle
  monitoring (Process.monitor) is handled exclusively by
  `MingaAgent.SessionManager`, which broadcasts `:agent_session_stopped`
  events via `Minga.Events`.

  UI state (scroll, prompt, focus, search, toasts) lives in `UIState`
  on `EditorState.workspace.agent_ui`.
  """

  alias MingaAgent.RuntimeState

  @typedoc "Agent status (delegated from RuntimeState)."
  @type status :: RuntimeState.status()

  @typedoc "Pending tool approval data."
  @type approval :: MingaAgent.ToolApproval.t()

  @typedoc "Agent rendering cache."
  @type t :: %__MODULE__{
          runtime: RuntimeState.t(),
          error: String.t() | nil,
          spinner_timer: {:ok, :timer.tref()} | nil,
          buffer: pid() | nil,
          pending_approval: approval() | nil
        }

  defstruct runtime: %RuntimeState{},
            error: nil,
            spinner_timer: nil,
            buffer: nil,
            pending_approval: nil

  # ── Status ──────────────────────────────────────────────────────────────────

  @doc "Returns the agent lifecycle status from RuntimeState."
  @spec status(t()) :: status()
  def status(%__MODULE__{runtime: rt}), do: rt.status

  @doc "Sets the agent status (delegates to RuntimeState)."
  @spec set_status(t(), status()) :: t()
  def set_status(%__MODULE__{} = agent, status) do
    %{agent | runtime: RuntimeState.set_status(agent.runtime, status)}
  end

  @doc "Sets the agent into an error state with a message."
  @spec set_error(t(), String.t()) :: t()
  def set_error(%__MODULE__{} = agent, message) do
    %{agent | runtime: RuntimeState.set_status(agent.runtime, :error), error: message}
  end

  # ── Cache reset ─────────────────────────────────────────────────────────────

  @doc """
  Resets the rendering cache to idle defaults.

  Called when the active tab/card no longer has a session, or when its
  session has been torn down. The session pid itself lives on the tab
  or card, not on this struct, so callers must clear that separately
  via `EditorState.set_tab_session/3` (Traditional) or by clearing the
  card's `:session` field (Board).
  """
  @spec reset_cache(t()) :: t()
  def reset_cache(%__MODULE__{} = agent) do
    %{
      agent
      | runtime: RuntimeState.set_status(agent.runtime, :idle),
        error: nil,
        pending_approval: nil
    }
  end

  # ── Buffer ──────────────────────────────────────────────────────────────────

  @doc "Sets the agent buffer pid."
  @spec set_buffer(t(), pid()) :: t()
  def set_buffer(%__MODULE__{} = agent, pid) when is_pid(pid) do
    %{agent | buffer: pid}
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
  def busy?(%__MODULE__{runtime: rt}), do: RuntimeState.busy?(rt)
end
