defmodule MingaEditor.UI.Prompt.WorkspaceRename do
  @moduledoc """
  Prompt handler for renaming the active workspace.

  Opens a text input with the current workspace name prefilled.
  On submit, renames the workspace (marks as custom so auto-naming stops).
  """

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaEditor.State.TabBar

  @impl true
  @spec label() :: String.t()
  def label, do: "Rename workspace: "

  @impl true
  @spec on_submit(String.t(), map()) :: map()
  def on_submit(text, %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state) do
    trimmed = String.trim(text)

    if trimmed == "" do
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        state,
        "Workspace name cannot be empty"
      )
    else
      ws_id = TabBar.active_workspace_id(tb)
      tb = TabBar.rename_workspace(tb, ws_id, trimmed)

      state
      |> MingaEditor.WorkspaceWorkflow.install_tab_bar(tb)
      |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("Renamed: #{trimmed}")
    end
  end

  def on_submit(_text, state), do: state
end
