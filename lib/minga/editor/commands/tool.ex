defmodule Minga.Editor.Commands.Tool do
  @moduledoc """
  Commands for the tool manager: install, uninstall, update, list, and manage.

  Provides `:ToolInstall`, `:ToolUninstall`, `:ToolUpdate`, `:ToolList`,
  and `:tool_manage` (picker UI) commands.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Command
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Tool.Manager, as: ToolManager
  alias Minga.Tool.PickerSource
  alias Minga.Tool.UninstallPickerSource
  alias Minga.Tool.UpdatePickerSource

  @type state :: EditorState.t()

  @impl true
  @spec __commands__() :: [Command.t()]
  def __commands__ do
    [
      %Command{
        name: :tool_install,
        description: "Install a tool",
        execute: fn state -> execute(state, :tool_install) end,
        requires_buffer: false
      },
      %Command{
        name: :tool_uninstall,
        description: "Uninstall a tool",
        execute: fn state -> execute(state, :tool_uninstall) end,
        requires_buffer: false
      },
      %Command{
        name: :tool_update,
        description: "Update a tool",
        execute: fn state -> execute(state, :tool_update) end,
        requires_buffer: false
      },
      %Command{
        name: :tool_list,
        description: "List installed tools",
        execute: fn state -> execute(state, :tool_list) end,
        requires_buffer: false
      },
      %Command{
        name: :tool_manage,
        description: "Manage tools",
        execute: fn state -> execute(state, :tool_manage) end,
        requires_buffer: false
      }
    ]
  end

  @doc "Executes a named tool action (from :ToolInstall name, etc.)."
  @spec execute_named(state(), :install | :uninstall | :update, String.t()) :: state()
  def execute_named(state, :install, name_str) do
    name = String.to_existing_atom(name_str)

    case ToolManager.install(name) do
      :ok -> %{state | status_msg: "Installing #{name_str}..."}
      {:error, reason} -> %{state | status_msg: "Cannot install #{name_str}: #{reason}"}
    end
  rescue
    ArgumentError -> %{state | status_msg: "Unknown tool: #{name_str}"}
  end

  def execute_named(state, :uninstall, name_str) do
    name = String.to_existing_atom(name_str)

    case ToolManager.uninstall(name) do
      :ok -> %{state | status_msg: "Uninstalled #{name_str}"}
      {:error, reason} -> %{state | status_msg: "Cannot uninstall #{name_str}: #{reason}"}
    end
  rescue
    ArgumentError -> %{state | status_msg: "Unknown tool: #{name_str}"}
  end

  def execute_named(state, :update, name_str) do
    name = String.to_existing_atom(name_str)

    case ToolManager.update(name) do
      :ok -> %{state | status_msg: "Updating #{name_str}..."}
      {:error, reason} -> %{state | status_msg: "Cannot update #{name_str}: #{reason}"}
    end
  rescue
    ArgumentError -> %{state | status_msg: "Unknown tool: #{name_str}"}
  end

  @doc "Executes a tool management command."
  @spec execute(state(), atom()) :: state()
  def execute(state, :tool_install) do
    PickerUI.open(state, PickerSource)
  end

  def execute(state, :tool_uninstall) do
    if ToolManager.all_installed() == [] do
      %{state | status_msg: "No tools installed"}
    else
      PickerUI.open(state, UninstallPickerSource)
    end
  end

  def execute(state, :tool_update) do
    if ToolManager.all_installed() == [] do
      %{state | status_msg: "No tools installed"}
    else
      PickerUI.open(state, UpdatePickerSource)
    end
  end

  def execute(state, :tool_list) do
    installed = ToolManager.all_installed()

    if installed == [] do
      %{state | status_msg: "No tools installed"}
    else
      lines =
        installed
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn inst ->
          "  #{inst.name} v#{inst.version} (#{inst.method})"
        end)

      msg = "Installed tools:\n#{Enum.join(lines, "\n")}"
      %{state | status_msg: msg}
    end
  end

  def execute(state, :tool_manage) do
    PickerUI.open(state, PickerSource)
  end
end
