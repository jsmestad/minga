defmodule Minga.Extension.AgentAPI do
  @moduledoc """
  Read-only facade for querying agent session state from extensions.

  Extensions use this module instead of importing `MingaAgent.Session`
  or `MingaAgent.SessionManager` directly. The facade returns plain maps
  with a stable shape, shielding extensions from internal refactors.

  All functions are safe to call with dead PIDs or when no sessions
  exist; they return empty results rather than crashing.

  ## Usage

      sessions = Minga.Extension.AgentAPI.list_sessions()
      # => [%{id: "1", pid: #PID<0.1234.0>, status: :thinking, ...}, ...]

      info = Minga.Extension.AgentAPI.session_info(pid)
      # => {:ok, %{id: "1", status: :thinking, cost: 0.042, ...}}

      Minga.Extension.AgentAPI.subscribe()
      # subscribes calling process to agent lifecycle events
  """

  require Logger

  @typedoc "Agent session status."
  @type session_status :: :idle | :plan | :thinking | :tool_executing | :error

  @typedoc "Summary of an active agent session."
  @type session_summary :: %{
          id: String.t(),
          pid: pid(),
          status: session_status(),
          label: String.t(),
          model: String.t(),
          active_tool: String.t() | nil,
          created_at: DateTime.t()
        }

  @typedoc "Detailed info for a specific agent session."
  @type session_info :: %{
          id: String.t(),
          pid: pid(),
          status: session_status(),
          label: String.t(),
          model: String.t(),
          active_tool: String.t() | nil,
          created_at: DateTime.t(),
          cost: float(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          turn_count: non_neg_integer(),
          files_touched: [String.t()]
        }

  @doc """
  Lists all active agent sessions with a summary for each.

  Returns an empty list if no sessions are running or the session
  manager is unavailable.
  """
  @spec list_sessions() :: [session_summary()]
  def list_sessions do
    MingaAgent.SessionManager.list_sessions()
    |> Enum.map(&session_entry_to_summary/1)
  catch
    :exit, {:noproc, _} ->
      []

    :exit, {:normal, _} ->
      []

    :exit, reason ->
      Logger.warning("AgentAPI.list_sessions/0 caught unexpected exit: #{inspect(reason)}")
      []
  end

  @doc """
  Returns detailed info for a specific session by PID.

  Includes cost, token usage, and turn count in addition to the
  summary fields. Returns `{:error, :not_found}` if the PID is dead
  or not a known session.
  """
  @spec session_info(pid()) :: {:ok, session_info()} | {:error, :not_found}
  def session_info(pid) when is_pid(pid) do
    case MingaAgent.SessionManager.session_id_for_pid(pid) do
      {:ok, id} ->
        snapshot = MingaAgent.Session.editor_snapshot(pid)
        usage = MingaAgent.Session.usage(pid)
        metadata = MingaAgent.Session.metadata(pid)

        touched =
          pid
          |> MingaAgent.Session.touched_files()
          |> Enum.map(& &1.path)

        {:ok,
         %{
           id: id,
           pid: pid,
           status: snapshot.status,
           label: metadata.title || metadata.first_prompt || "agent",
           model: metadata.model_name,
           active_tool: snapshot.active_tool_name,
           created_at: metadata.created_at,
           cost: usage.cost,
           input_tokens: usage.input,
           output_tokens: usage.output,
           turn_count: metadata.turn_count,
           files_touched: touched
         }}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  catch
    :exit, {:noproc, _} ->
      {:error, :not_found}

    :exit, {:normal, _} ->
      {:error, :not_found}

    :exit, reason ->
      Logger.warning("AgentAPI.session_info/1 caught unexpected exit: #{inspect(reason)}")
      {:error, :not_found}
  end

  @doc """
  Subscribes the calling process to agent lifecycle events.

  After calling this, the process receives messages in the standard
  event bus format:

  - `{:minga_event, :agent_session_stopped, %MingaAgent.SessionManager.SessionStoppedEvent{session_id: id, pid: pid, reason: reason}}`
  - `{:minga_event, :agent_hook, %Minga.Events.AgentHookEvent{event: event, phase: phase, tool_name: name, ...}}`

  Subscribe to `:buffer_changed` separately via `subscribe_edits/0` if you
  need edit-level granularity (e.g., for ghost cursors tracking edit positions).

  Note: `:agent_session_started` and `:agent_status_changed` events will be
  added incrementally as the internal event infrastructure expands. For now,
  extensions can poll `list_sessions/0` or use `:agent_hook` phase transitions
  to infer session activity.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Minga.Events.subscribe(:agent_session_stopped)
    Minga.Events.subscribe(:agent_hook)
    :ok
  end

  @doc """
  Subscribes the calling process to agent edit events.

  After calling this, the process receives `:buffer_changed` events
  for all buffer edits, including agent-sourced ones. To isolate
  agent edits, pattern-match on the `source` field inside the struct:

      receive do
        {:minga_event, :buffer_changed, %Minga.Events.BufferChangedEvent{source: {:agent, session_pid, tool_call_id}} = event} ->
          # this edit came from an agent session
      end
  """
  @spec subscribe_edits() :: :ok
  def subscribe_edits do
    Minga.Events.subscribe(:buffer_changed)
    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  @spec session_entry_to_summary({String.t(), pid(), MingaAgent.SessionMetadata.t()}) ::
          session_summary()
  defp session_entry_to_summary({id, pid, metadata}) do
    snapshot = safe_editor_snapshot(pid)

    %{
      id: id,
      pid: pid,
      status: snapshot.status,
      label: metadata.title || metadata.first_prompt || "agent",
      model: metadata.model_name,
      active_tool: snapshot.active_tool_name,
      created_at: metadata.created_at
    }
  end

  @spec safe_editor_snapshot(pid()) :: MingaAgent.Session.editor_snapshot()
  defp safe_editor_snapshot(pid) do
    MingaAgent.Session.editor_snapshot(pid)
  catch
    :exit, {:noproc, _} ->
      %{status: :error, pending_approval: nil, error: nil, active_tool_name: nil}

    :exit, {:normal, _} ->
      %{status: :error, pending_approval: nil, error: nil, active_tool_name: nil}

    :exit, reason ->
      Logger.warning("AgentAPI.safe_editor_snapshot/1 caught unexpected exit: #{inspect(reason)}")
      %{status: :error, pending_approval: nil, error: nil, active_tool_name: nil}
  end
end
