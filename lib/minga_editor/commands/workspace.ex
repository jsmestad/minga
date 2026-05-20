defmodule MingaEditor.Commands.Workspace do
  @moduledoc """
  Workspace navigation and management commands.

  All navigation commands route through `EditorState.switch_tab/2` so
  the outgoing tab's context is snapshotted and the incoming tab's
  context is restored. Never mutate `tab_bar.active_id` directly.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar

  @type state :: EditorState.t()

  @doc "Switch to the next workspace's first tab."
  @spec workspace_next(state()) :: state()
  def workspace_next(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    switch_via_workspace(state, TabBar.next_agent_workspace(tb))
  end

  @doc "Switch to the previous workspace's first tab."
  @spec workspace_prev(state()) :: state()
  def workspace_prev(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    switch_via_workspace(state, TabBar.prev_agent_workspace(tb))
  end

  @doc "Switch to the first manual workspace tab."
  @spec switch_to_manual_workspace(state()) :: state()
  def switch_to_manual_workspace(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    case TabBar.tabs_in_workspace(tb, 0) do
      [first | _] -> EditorState.switch_tab(state, first.id)
      [] -> state
    end
  end

  @doc "Toggle between manual workspace tabs and the last agent workspace."
  @spec workspace_toggle(state()) :: state()
  def workspace_toggle(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    current_ws = TabBar.active_workspace_id(tb)
    target_workspace_id = if current_ws == 0, do: last_agent_id(tb), else: 0
    target_tb = TabBar.switch_to_workspace(tb, target_workspace_id)
    switch_via_workspace(state, target_tb)
  end

  @doc """
  Close the active workspace and migrate its tabs to the manual workspace.

  The manual workspace (id 0) cannot be closed.
  """
  @spec workspace_close(state()) :: state()
  def workspace_close(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    EditorState.set_tab_bar(state, TabBar.remove_workspace(tb, TabBar.active_workspace_id(tb)))
  end

  @doc "Open the workspace picker."
  @spec workspace_list(state()) :: state()
  def workspace_list(state) do
    MingaEditor.PickerUI.open(state, MingaEditor.UI.Picker.WorkspaceSource)
  end

  @doc "Open the icon picker for the active workspace."
  @spec workspace_set_icon(state()) :: state()
  def workspace_set_icon(state) do
    MingaEditor.PickerUI.open(state, MingaEditor.UI.Picker.WorkspaceIconSource)
  end

  @doc """
  Rename the active workspace.

  GUI: the inline TextField in the group indicator handles rename
  natively (double-click or context menu). This keyboard path opens the
  prompt UI with the current name prefilled, which works in both TUI
  (minibuffer) and GUI (native prompt rendering).
  """
  @spec workspace_rename(state()) :: state()
  def workspace_rename(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    ws = TabBar.active_workspace(tb)
    current_name = if ws, do: ws.label, else: ""

    MingaEditor.PromptUI.open(state, MingaEditor.UI.Prompt.WorkspaceRename, default: current_name)
  end

  @doc "Jump to workspace by number (1-based, 0 = manual workspace)."
  @spec workspace_goto(state(), non_neg_integer()) :: state()
  def workspace_goto(%{shell_state: %{tab_bar: %TabBar{}}} = state, 0) do
    switch_to_manual_workspace(state)
  end

  def workspace_goto(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, number) do
    case Enum.at(agent_workspaces(tb), number - 1) do
      nil -> state
      %{id: id} -> switch_via_workspace(state, TabBar.switch_to_workspace(tb, id))
    end
  end

  @doc "Jump directly to a workspace by id."
  @spec workspace_goto_by_id(state(), non_neg_integer()) :: state()
  def workspace_goto_by_id(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, workspace_id) do
    switch_via_workspace(state, TabBar.switch_to_workspace(tb, workspace_id))
  end

  # Takes a TabBar with a potentially new active_id from a workspace switch.
  # Routes through EditorState.switch_tab so snapshots and restores happen properly.
  # No-op if the active tab didn't change.
  @spec switch_via_workspace(state(), TabBar.t()) :: state()
  defp switch_via_workspace(state, %TabBar{active_id: new_id}) do
    if new_id == state.shell_state.tab_bar.active_id do
      state
    else
      EditorState.switch_tab(state, new_id)
    end
  end

  # Find the last (most recently added) agent workspace id.
  @spec last_agent_id(TabBar.t()) :: non_neg_integer()
  defp last_agent_id(%TabBar{} = tb) do
    case List.last(agent_workspaces(tb)) do
      nil -> 0
      ws -> ws.id
    end
  end

  @spec agent_workspaces(TabBar.t()) :: [MingaEditor.State.Workspace.t()]
  defp agent_workspaces(%TabBar{workspaces: workspaces}) do
    Enum.filter(workspaces, &(&1.kind == :agent))
  end

  command(:workspace_next, "Next workspace", execute: &workspace_next/1)
  command(:workspace_prev, "Previous workspace", execute: &workspace_prev/1)

  command(:workspace_next_agent, "Next agent workspace", execute: &workspace_next/1)

  command(:manual_workspace, "Switch to manual workspace", execute: &switch_to_manual_workspace/1)
  command(:workspace_toggle, "Toggle last workspace", execute: &workspace_toggle/1)
  command(:workspace_close, "Close workspace", execute: &workspace_close/1)
  command(:workspace_list, "List workspaces", execute: &workspace_list/1)
  command(:workspace_rename, "Rename workspace", execute: &workspace_rename/1)
  command(:workspace_set_icon, "Set workspace icon", execute: &workspace_set_icon/1)

  numbered_commands(:workspace_goto, 1..9, "Workspace",
    argument: :number,
    execute: &workspace_goto/2
  )
end
