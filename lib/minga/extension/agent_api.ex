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

  @typedoc "Summary of an active agent session."
  @type session_summary :: %{
          id: String.t(),
          pid: pid(),
          status: :idle | :plan | :thinking | :tool_executing | :error,
          label: String.t(),
          model: String.t(),
          active_tool: String.t() | nil,
          created_at: DateTime.t()
        }

  @typedoc "Detailed info for a specific agent session."
  @type session_info :: %{
          id: String.t(),
          pid: pid(),
          status: :idle | :plan | :thinking | :tool_executing | :error,
          label: String.t(),
          model: String.t(),
          active_tool: String.t() | nil,
          created_at: DateTime.t(),
          cost: float(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          turn_count: non_neg_integer()
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
    :exit, _ -> []
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
        metadata = session_metadata(pid, id)

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
           turn_count: metadata.turn_count
         }}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Subscribes the calling process to agent lifecycle events.

  After calling this, the process receives messages in the standard
  event bus format:

  - `{:minga_event, :agent_session_stopped, %SessionStoppedEvent{session_id, pid, reason}}`
  - `{:minga_event, :agent_hook, %AgentHookEvent{event, phase, tool_name, ...}}`
  - `{:minga_event, :buffer_changed, %BufferChangedEvent{source: {:agent, pid, tool_call_id}, ...}}`

  Subscribe to `:buffer_changed` separately if you need edit-level
  granularity (e.g., for ghost cursors tracking edit positions).
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
  for all buffer edits, including agent-sourced ones. Filter on
  `source: {:agent, session_pid, tool_call_id}` to isolate agent edits.
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
    :exit, _ -> %{status: :idle, pending_approval: nil, error: nil, active_tool_name: nil}
  end

  @spec session_metadata(pid(), String.t()) :: MingaAgent.SessionMetadata.t()
  defp session_metadata(pid, id) do
    MingaAgent.Session.metadata(pid)
  catch
    :exit, _ ->
      %MingaAgent.SessionMetadata{
        id: id,
        model_name: "unknown",
        created_at: DateTime.utc_now(),
        last_message_at: DateTime.utc_now()
      }
  end
end
