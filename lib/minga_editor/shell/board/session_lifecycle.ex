defmodule MingaEditor.Shell.Board.SessionLifecycle do
  @moduledoc """
  Session lifecycle helpers for Board cards.

  Board cards store agent session PIDs directly, but `MingaAgent.SessionManager` owns process lifecycle and broadcasts stop events. Keeping start/stop here prevents keyboard and GUI Board paths from drifting into different ownership patterns.
  """

  alias MingaAgent.Session, as: AgentSession
  alias MingaAgent.SessionManager

  @doc "Starts a managed agent session and subscribes the caller to its events."
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    case SessionManager.start_session(opts) do
      {:ok, _session_id, pid} ->
        subscribe(pid)

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Stops a managed agent session by PID. Unknown or already-dead PIDs are treated as no-ops."
  @spec stop(pid() | nil) :: :ok | {:error, :not_found}
  def stop(pid) when is_pid(pid) do
    SessionManager.stop_session_by_pid(pid)
  catch
    :exit, _ -> :ok
  end

  def stop(nil), do: :ok

  @spec subscribe(pid()) :: {:ok, pid()} | {:error, term()}
  defp subscribe(pid) do
    AgentSession.subscribe(pid)
    {:ok, pid}
  catch
    :exit, reason ->
      stop(pid)
      {:error, reason}
  end
end
