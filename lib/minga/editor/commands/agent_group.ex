defmodule Minga.Editor.Commands.AgentGroup do
  @moduledoc """
  Workspace management commands.

  These commands handle workspace navigation and switching. Workspaces
  are a progressive grouping layer over tabs: when agents are running,
  their files are grouped into workspace sections.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Editor.State.TabBar

  @type state :: map()

  @doc "Switch to the next workspace."
  @spec agent_group_next(state()) :: state()
  def agent_group_next(%{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.next_agent_group(tb)}
  end

  @doc "Switch to the previous workspace."
  @spec agent_group_prev(state()) :: state()
  def agent_group_prev(%{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.prev_agent_group(tb)}
  end

  @doc "Switch to the next agent workspace (skips manual)."
  @spec agent_group_next_agent(state()) :: state()
  def agent_group_next_agent(%{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.next_agent_group(tb)}
  end

  @doc "Switch to the first ungrouped (user) tab."
  @spec switch_to_ungrouped(state()) :: state()
  def switch_to_ungrouped(%{tab_bar: %TabBar{} = tb} = state) do
    case TabBar.tabs_in_group(tb, 0) do
      [first | _] -> %{state | tab_bar: %{tb | active_id: first.id}}
      [] -> state
    end
  end

  @doc "Switch to last active workspace (toggle between current and manual)."
  @spec agent_group_toggle(state()) :: state()
  def agent_group_toggle(%{tab_bar: %TabBar{} = tb} = state) do
    current_ws = TabBar.active_group_id(tb)
    new_id = if current_ws == 0, do: last_agent_id(tb), else: 0
    %{state | tab_bar: TabBar.switch_to_group(tb, new_id)}
  end

  @doc """
  Close the active workspace and migrate its tabs to manual.

  The manual workspace (id 0) cannot be closed.
  """
  @spec agent_group_close(state()) :: state()
  def agent_group_close(%{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.remove_group(tb, TabBar.active_group_id(tb))}
  end

  @doc "Open the workspace picker."
  @spec agent_group_list(state()) :: state()
  def agent_group_list(state) do
    Minga.Editor.PickerUI.open(state, Minga.Picker.AgentGroupSource)
  end

  @doc "Open the icon picker for the active workspace."
  @spec agent_group_set_icon(state()) :: state()
  def agent_group_set_icon(state) do
    Minga.Editor.PickerUI.open(state, Minga.Picker.AgentGroupIconSource)
  end

  @doc """
  Rename the active workspace.

  GUI: the inline TextField in the workspace indicator handles rename
  natively (double-click or context menu). This keyboard path opens the
  prompt UI with the current name prefilled, which works in both TUI
  (minibuffer) and GUI (native prompt rendering).
  """
  @spec agent_group_rename(state()) :: state()
  def agent_group_rename(%{tab_bar: %TabBar{} = tb} = state) do
    ws = TabBar.active_group(tb)
    current_name = if ws, do: ws.label, else: ""

    Minga.Editor.PromptUI.open(state, Minga.Prompt.AgentGroupRename, default: current_name)
  end

  @doc "Jump to workspace by number (1-based, 0 = manual workspace)."
  @spec workspace_goto(state(), non_neg_integer()) :: state()
  def workspace_goto(%{tab_bar: %TabBar{} = tb} = state, number) do
    ws =
      case number do
        0 -> TabBar.get_group(tb, 0)
        n -> Enum.at(tb.agent_groups, n)
      end

    case ws do
      nil -> state
      %{id: id} -> %{state | tab_bar: TabBar.switch_to_group(tb, id)}
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
