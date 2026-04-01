defmodule MingaEditor.UI.Prompt.AgentGroupRename do
  @moduledoc """
  Prompt handler for renaming the active workspace.

  Opens a text input with the current workspace name prefilled.
  On submit, renames the workspace (marks as custom so auto-naming stops).
  """

  @behaviour MingaEditor.UI.Prompt.Handler

  alias MingaEditor.State.AgentGroup
  alias MingaEditor.State.TabBar

  @impl true
  @spec label() :: String.t()
  def label, do: "Rename workspace: "

  @impl true
  @spec on_submit(String.t(), map()) :: map()
  def on_submit(text, %{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    trimmed = String.trim(text)

    if trimmed == "" do
      ss = state.shell_state
      %{state | shell_state: %{ss | status_msg: "Workspace name cannot be empty"}}
    else
      ws_id = TabBar.active_group_id(tb)
      tb = TabBar.update_group(tb, ws_id, &AgentGroup.rename(&1, trimmed))
      ss = state.shell_state
      %{state | shell_state: %{ss | tab_bar: tb, status_msg: "Renamed: #{trimmed}"}}
    end
  end

  def on_submit(_text, state), do: state

  @impl true
  @spec on_cancel(map()) :: map()
  def on_cancel(state), do: state
end
