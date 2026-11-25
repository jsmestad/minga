defmodule MingaEditor.Commands.GitStatus do
  @moduledoc """
  Git status panel commands that run without a selected file: push, pull and fetch.

  The panel's keys (`P`, `l`, `f`) run them, and so does a click on a clean tree's next step, which names the command it runs.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.GitStatus.Panel
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.State, as: EditorState

  @type state :: EditorState.t()

  command(:git_status_push, "Push to remote", requires_buffer: false)
  command(:git_status_pull, "Pull from remote", requires_buffer: false)
  command(:git_status_fetch, "Fetch from remote", requires_buffer: false)

  @spec execute(state(), :git_status_push | :git_status_pull | :git_status_fetch) :: state()
  def execute(state, :git_status_push), do: panel_action(state, :git_push)
  def execute(state, :git_status_pull), do: panel_action(state, :git_pull)
  def execute(state, :git_status_fetch), do: panel_action(state, :git_fetch)

  @doc "Runs a whole-repository action on the open git status panel; without one, nothing happens."
  @spec panel_action(
          state(),
          :git_stage_all | :git_unstage_all | :git_push | :git_pull | :git_fetch
        ) :: state()
  def panel_action(state, operation) do
    case SidebarWorkflow.git_status_panel(state) do
      %Panel{id: panel_id} -> GuiActionHandler.dispatch(state, {operation, panel_id})
      nil -> state
    end
  end
end
