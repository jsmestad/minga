defmodule Minga.Editor.Commands.Workspace do
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
  @spec workspace_next(state()) :: state()
  def workspace_next(%{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.next_workspace(tb)}
  end

  @doc "Switch to the previous workspace."
  @spec workspace_prev(state()) :: state()
  def workspace_prev(%{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.prev_workspace(tb)}
  end

  @doc "Switch to the next agent workspace (skips manual)."
  @spec workspace_next_agent(state()) :: state()
  def workspace_next_agent(%{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.next_agent_workspace(tb)}
  end

  @doc "Switch to the manual workspace."
  @spec workspace_manual(state()) :: state()
  def workspace_manual(%{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.switch_workspace(tb, 0)}
  end

  @doc "Switch to last active workspace (toggle between current and manual)."
  @spec workspace_toggle_last(state()) :: state()
  def workspace_toggle_last(%{tab_bar: %TabBar{} = tb} = state) do
    current_ws = TabBar.active_workspace_id(tb)
    new_id = if current_ws == 0, do: last_agent_id(tb), else: 0
    %{state | tab_bar: TabBar.switch_workspace(tb, new_id)}
  end

  @doc """
  Close the active workspace and migrate its tabs to manual.

  The manual workspace (id 0) cannot be closed.
  """
  @spec workspace_close(state()) :: state()
  def workspace_close(%{tab_bar: %TabBar{} = tb} = state) do
    %{state | tab_bar: TabBar.remove_workspace(tb, TabBar.active_workspace_id(tb))}
  end

  @doc "Open the workspace picker."
  @spec workspace_list(state()) :: state()
  def workspace_list(state) do
    Minga.Editor.PickerUI.open(state, Minga.Picker.WorkspaceSource)
  end

  @doc "Jump to workspace by number (1-based, 0 = manual workspace)."
  @spec workspace_goto(state(), non_neg_integer()) :: state()
  def workspace_goto(%{tab_bar: %TabBar{} = tb} = state, number) do
    ws =
      case number do
        0 -> TabBar.get_workspace(tb, 0)
        n -> Enum.at(tb.workspaces, n)
      end

    case ws do
      nil -> state
      %{id: id} -> %{state | tab_bar: TabBar.switch_workspace(tb, id)}
    end
  end

  # Find the last (most recently added) agent workspace id.
  @spec last_agent_id(TabBar.t()) :: non_neg_integer()
  defp last_agent_id(%TabBar{workspaces: workspaces}) do
    case Enum.filter(workspaces, &(&1.kind == :agent)) |> List.last() do
      nil -> 0
      ws -> ws.id
    end
  end

  @workspace_command_specs [
    {:workspace_next, "Next workspace", :workspace_next},
    {:workspace_prev, "Previous workspace", :workspace_prev},
    {:workspace_next_agent, "Next agent workspace", :workspace_next_agent},
    {:workspace_manual, "Switch to manual workspace", :workspace_manual},
    {:workspace_toggle_last, "Toggle last workspace", :workspace_toggle_last},
    {:workspace_close, "Close workspace", :workspace_close},
    {:workspace_list, "List workspaces", :workspace_list}
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
