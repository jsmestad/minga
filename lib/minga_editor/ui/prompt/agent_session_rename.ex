defmodule MingaEditor.UI.Prompt.AgentSessionRename do
  @moduledoc "Renames the saved conversation selected when the shared prompt opened."

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionTarget
  alias MingaEditor.PromptUI
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.State.TabBar

  @typep origin :: %{owner: non_neg_integer(), target: ConnectionTarget.t()}
  @typep result :: {:ok, String.t()} | {:error, term()}

  @spec open(State.t()) :: State.t()
  def open(state) do
    case origin(state) do
      nil -> NoticeWorkflow.publish(state, "Open a saved local Agent session to rename it.")
      origin -> PromptUI.open(state, __MODULE__, context: origin)
    end
  end

  @impl true
  @spec label() :: String.t()
  def label, do: "Rename Agent session: "

  @impl true
  @spec on_submit(String.t(), State.t()) :: State.t()
  def on_submit(title, state), do: on_submit(title, state, nil)

  @impl true
  @spec on_submit(String.t(), State.t(), origin() | nil) :: State.t()
  def on_submit(title, state, %{target: _target} = displayed) do
    if origin(state) == displayed,
      do: start_rename(state, displayed, title),
      else: on_submit(title, state, nil)
  end

  def on_submit(_title, state, nil),
    do: NoticeWorkflow.publish(state, "Session changed. Reopen Rename Agent session.")

  @spec start_rename(State.t(), origin(), String.t()) :: State.t()
  defp start_rename(state, %{target: target} = displayed, title) do
    editor = self()

    work = fn ->
      send(editor, {:agent_session_rename_result, displayed, rename(target, title)})
    end

    case Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, work) do
      {:ok, _worker} -> state
      {:error, _reason} -> NoticeWorkflow.publish(state, "Could not start the session rename.")
    end
  end

  @doc false
  @spec receive_result(State.t(), origin(), result()) :: State.t()
  def receive_result(state, displayed, result) do
    if origin(state) == displayed do
      state |> NoticeWorkflow.publish(message(result)) |> MingaEditor.schedule_render(16)
    else
      state
    end
  end

  @spec rename(ConnectionTarget.t(), String.t()) :: result()
  defp rename(target, title) do
    Session.rename_conversation(target, title)
  catch
    :exit, {:timeout, _call} -> {:error, :unconfirmed}
    :exit, _reason -> {:error, :stale_target}
  end

  @spec origin(State.t()) :: origin() | nil
  defp origin(%State{
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

  defp origin(_state), do: nil

  @spec message(result()) :: String.t()
  defp message({:ok, title}), do: "Agent session renamed: #{title}"
  defp message({:error, :stale_target}), do: "Session changed. Reopen Rename Agent session."

  defp message({:error, :invalid_session_title}),
    do: "Enter a single-line name of 1 to 256 bytes."

  defp message({:error, :no_saved_conversation}), do: "Save a conversation before renaming it."

  defp message({:error, :unconfirmed}),
    do: "Rename could not be confirmed. Reopen Sessions to check."

  defp message({:error, {:session_rename_uncertain, _write, _sync}}),
    do: message({:error, :unconfirmed})

  defp message({:error, _reason}), do: "Could not save the session name."
end
