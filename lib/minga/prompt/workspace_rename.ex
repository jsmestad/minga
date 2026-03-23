defmodule Minga.Prompt.WorkspaceRename do
  @moduledoc """
  Prompt handler for renaming the active workspace.

  Opens a text input with the current workspace name prefilled.
  On submit, renames the workspace (marks as custom so auto-naming stops).
  """

  @behaviour Minga.Prompt.Handler

  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Workspace

  @impl true
  @spec label() :: String.t()
  def label, do: "Rename workspace: "

  @impl true
  @spec on_submit(String.t(), map()) :: map()
  def on_submit(text, %{tab_bar: %TabBar{} = tb} = state) do
    trimmed = String.trim(text)

    if trimmed == "" do
      %{state | status_msg: "Workspace name cannot be empty"}
    else
      ws_id = TabBar.active_workspace_id(tb)
      tb = TabBar.update_workspace(tb, ws_id, &Workspace.rename(&1, trimmed))
      %{state | tab_bar: tb, status_msg: "Renamed: #{trimmed}"}
    end
  end

  def on_submit(_text, state), do: state

  @impl true
  @spec on_cancel(map()) :: map()
  def on_cancel(state), do: state
end
