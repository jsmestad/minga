defmodule MingaEditor.Commands.AgentGroup do
  @moduledoc """
  Agent group navigation and management commands.

  All navigation commands route through `EditorState.switch_tab/2` so
  the outgoing tab's context is snapshotted and the incoming tab's
  context is restored. Never mutate `tab_bar.active_id` directly.
  """

  @behaviour Minga.Command.Provider

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar

  @type state :: EditorState.t()

  @doc "Switch to the next agent group's first tab."
  @spec agent_group_next(state()) :: state()
  def agent_group_next(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    switch_via_group(state, TabBar.next_agent_group(tb))
  end

  @doc "Switch to the previous agent group's first tab."
  @spec agent_group_prev(state()) :: state()
  def agent_group_prev(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    switch_via_group(state, TabBar.prev_agent_group(tb))
  end

  @doc "Switch to the next agent group (same as next)."
  @spec agent_group_next_agent(state()) :: state()
  def agent_group_next_agent(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    switch_via_group(state, TabBar.next_agent_group(tb))
  end

  @doc "Switch to the first ungrouped (user) tab."
  @spec switch_to_ungrouped(state()) :: state()
  def switch_to_ungrouped(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    case TabBar.tabs_in_group(tb, 0) do
      [first | _] -> EditorState.switch_tab(state, first.id)
      [] -> state
    end
  end

  @doc "Toggle between ungrouped tabs and the last agent group."
  @spec agent_group_toggle(state()) :: state()
  def agent_group_toggle(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    current_ws = TabBar.active_group_id(tb)
    target_group_id = if current_ws == 0, do: last_agent_id(tb), else: 0
    target_tb = TabBar.switch_to_group(tb, target_group_id)
    switch_via_group(state, target_tb)
  end

  @doc """
  Close the active agent group and migrate its tabs to ungrouped.

  The ungrouped group (id 0) cannot be closed.
  """
  @spec agent_group_close(state()) :: state()
  def agent_group_close(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    EditorState.set_tab_bar(state, TabBar.remove_group(tb, TabBar.active_group_id(tb)))
  end

  @doc "Open the agent group picker."
  @spec agent_group_list(state()) :: state()
  def agent_group_list(state) do
    MingaEditor.PickerUI.open(state, MingaEditor.UI.Picker.AgentGroupSource)
  end

  @doc "Open the icon picker for the active agent group."
  @spec agent_group_set_icon(state()) :: state()
  def agent_group_set_icon(state) do
    MingaEditor.PickerUI.open(state, MingaEditor.UI.Picker.AgentGroupIconSource)
  end

  @doc """
  Rename the active agent group.

  GUI: the inline TextField in the group indicator handles rename
  natively (double-click or context menu). This keyboard path opens the
  prompt UI with the current name prefilled, which works in both TUI
  (minibuffer) and GUI (native prompt rendering).
  """
  @spec agent_group_rename(state()) :: state()
  def agent_group_rename(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    ws = TabBar.active_group(tb)
    current_name = if ws, do: ws.label, else: ""

    MingaEditor.PromptUI.open(state, MingaEditor.UI.Prompt.AgentGroupRename,
      default: current_name
    )
  end

  @doc "Jump to agent group by number (1-based, 0 = ungrouped)."
  @spec workspace_goto(state(), non_neg_integer()) :: state()
  def workspace_goto(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, number) do
    ws =
      case number do
        0 -> TabBar.get_group(tb, 0)
        n -> Enum.at(tb.agent_groups, n)
      end

    case ws do
      nil -> state
      %{id: id} -> switch_via_group(state, TabBar.switch_to_group(tb, id))
    end
  end

  # Takes a TabBar with a potentially new active_id (from a group switch
  # operation) and routes through EditorState.switch_tab so snapshots
  # and restores happen properly. No-op if the active tab didn't change.
  @spec switch_via_group(state(), TabBar.t()) :: state()
  defp switch_via_group(state, %TabBar{active_id: new_id}) do
    if new_id == state.shell_state.tab_bar.active_id do
      state
    else
      EditorState.switch_tab(state, new_id)
    end
  end

  # Find the last (most recently added) agent workspace id.
  @spec last_agent_id(TabBar.t()) :: non_neg_integer()
  defp last_agent_id(%TabBar{agent_groups: groups}) do
    case List.last(groups) do
      nil -> 0
      ws -> ws.id
    end
  end

  @workspace_command_specs [
    {:agent_group_next, "Next workspace", :agent_group_next},
    {:agent_group_prev, "Previous workspace", :agent_group_prev},
    {:agent_group_next_agent, "Next agent workspace", :agent_group_next_agent},
    {:ungrouped_tabs, "Switch to my tabs", :switch_to_ungrouped},
    {:agent_group_toggle, "Toggle last workspace", :agent_group_toggle},
    {:agent_group_close, "Close workspace", :agent_group_close},
    {:agent_group_list, "List agent groups", :agent_group_list},
    {:agent_group_rename, "Rename workspace", :agent_group_rename},
    {:agent_group_set_icon, "Set workspace icon", :agent_group_set_icon}
  ]

  @impl Minga.Command.Provider
  def __commands__ do
    dispatched =
      Enum.map(@workspace_command_specs, fn {cmd_name, desc, fun_name} ->
        %Minga.Command{
          name: cmd_name,
          description: desc,
          requires_buffer: false,
          execute: fn state -> apply(__MODULE__, fun_name, [state]) end
        }
      end)

    # Numbered workspace jumps (SPC TAB 1..9)
    numbered =
      for n <- 1..9 do
        %Minga.Command{
          name: :"workspace_goto_#{n}",
          description: "Workspace #{n}",
          requires_buffer: false,
          execute: fn state -> workspace_goto(state, n) end
        }
      end

    dispatched ++ numbered
  end
end
