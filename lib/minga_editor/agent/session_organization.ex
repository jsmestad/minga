defmodule MingaEditor.Agent.SessionOrganization do
  @moduledoc "Changes the organization of the exact displayed local saved Agent session."

  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionTarget
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.State.TabBar

  @type origin :: %{owner: non_neg_integer(), target: ConnectionTarget.t()}
  @type change :: {:rename, String.t()} | {:archive, boolean()}
  @type result :: :ok | {:ok, String.t()} | {:error, term()}

  @doc "Captures the exact local conversation behind the visible Agent workspace."
  @spec origin(State.t()) :: origin() | nil
  def origin(%State{
        shell_runtime: %{state: %{tab_bar: %TabBar{} = tabs}} = runtime,
        workspace: %{
          agent_ui: %{
            connection: %{
              target: %ConnectionTarget{session: session} = target,
              persistent_drafts?: true
            }
          }
        }
      })
      when node(session) == node() do
    case Runtime.active_session(runtime) do
      ^session -> %{owner: TabBar.active_workspace_id(tabs), target: target}
      _other -> nil
    end
  end

  def origin(_state), do: nil

  @doc "Schedules one metadata update without blocking the editor or retargeting after a switch."
  @spec start(State.t(), origin(), change()) :: State.t()
  def start(state, %{target: target} = displayed, change) do
    editor = self()

    work = fn ->
      send(
        editor,
        {:agent_session_organization_result, displayed, change, apply_change(target, change)}
      )
    end

    case Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, work) do
      {:ok, _worker} ->
        state

      {:error, _reason} ->
        NoticeWorkflow.publish(state, "Could not start the session metadata update.")
    end
  end

  @doc false
  @spec receive_result(State.t(), origin(), change(), result()) :: State.t()
  def receive_result(state, displayed, change, result) do
    if origin(state) == displayed do
      state |> NoticeWorkflow.publish(message(change, result)) |> MingaEditor.schedule_render(16)
    else
      state
    end
  end

  @spec apply_change(ConnectionTarget.t(), change()) :: result()
  defp apply_change(target, change) do
    case change do
      {:rename, title} -> Session.rename_conversation(target, title)
      {:archive, archived?} -> Session.set_archived(target, archived?)
    end
  catch
    :exit, {:timeout, _call} -> {:error, :unconfirmed}
    :exit, _reason -> {:error, :stale_target}
  end

  @spec message(change(), result()) :: String.t()
  defp message({:rename, _}, {:ok, title}), do: "Agent session renamed: #{title}"

  defp message({:archive, true}, :ok),
    do: "Agent session archived. Find it in Browse archived sessions."

  defp message({:archive, false}, :ok), do: "Agent session restored to recent sessions."

  defp message({:rename, _}, {:error, :stale_target}),
    do: "Session changed. Reopen Rename Agent session."

  defp message({:archive, _}, {:error, :stale_target}),
    do: "Session changed. Reopen the intended session."

  defp message({:rename, _}, {:error, :invalid_session_title}),
    do: "Enter a single-line name of 1 to 256 bytes."

  defp message({:rename, _}, {:error, :no_saved_conversation}),
    do: "Save a conversation before renaming it."

  defp message({:archive, _}, {:error, :no_saved_conversation}),
    do: "Save a conversation before changing its archive status."

  defp message({:rename, _}, {:error, :unconfirmed}),
    do: "Rename could not be confirmed. Reopen Sessions to check."

  defp message({:archive, _}, {:error, :unconfirmed}),
    do: "Archive change could not be confirmed. Reopen Sessions to check."

  defp message(change, {:error, {kind, _write, _sync}})
       when kind in [:session_rename_uncertain, :session_archive_uncertain],
       do: message(change, {:error, :unconfirmed})

  defp message({:rename, _}, {:error, _reason}), do: "Could not save the session name."
  defp message({:archive, _}, {:error, _reason}), do: "Could not save the session archive status."
end
