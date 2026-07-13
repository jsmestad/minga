defmodule MingaEditor.Commands.Tool do
  @moduledoc """
  Commands for the tool manager: install, uninstall, update, list, and manage.

  Provides `:ToolInstall`, `:ToolUninstall`, `:ToolUpdate`, `:ToolList`,
  and `:tool_manage` (picker UI) commands.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias Minga.Tool.Manager, as: ToolManager
  alias MingaEditor.UI.Picker.Sources.Tool, as: PickerSource
  alias MingaEditor.UI.Picker.Sources.ToolUninstall, as: UninstallPickerSource
  alias MingaEditor.UI.Picker.Sources.ToolUpdate, as: UpdatePickerSource

  @type state :: EditorState.t()

  command(:tool_install, "Install a tool", requires_buffer: false)
  command(:tool_uninstall, "Uninstall a tool", requires_buffer: false)
  command(:tool_update, "Update a tool", requires_buffer: false)
  command(:tool_list, "List installed tools", requires_buffer: false)
  command(:tool_manage, "Manage tools", requires_buffer: false)

  @doc "Executes a named tool action (from :ToolInstall name, etc.)."
  @spec execute_named(state(), :install | :uninstall | :update, String.t()) :: state()
  def execute_named(state, :install, name_str) do
    name = String.to_existing_atom(name_str)

    case ToolManager.install(name) do
      :ok ->
        NoticeWorkflow.publish(state, "Installing #{name_str}...")

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Cannot install #{name_str}: #{reason}"
        )
    end
  rescue
    ArgumentError ->
      NoticeWorkflow.publish(state, "Unknown tool: #{name_str}")
  end

  def execute_named(state, :uninstall, name_str) do
    name = String.to_existing_atom(name_str)

    case ToolManager.uninstall(name) do
      :ok ->
        NoticeWorkflow.publish(state, "Uninstalled #{name_str}")

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Cannot uninstall #{name_str}: #{reason}"
        )
    end
  rescue
    ArgumentError ->
      NoticeWorkflow.publish(state, "Unknown tool: #{name_str}")
  end

  def execute_named(state, :update, name_str) do
    name = String.to_existing_atom(name_str)

    case ToolManager.update(name) do
      :ok ->
        NoticeWorkflow.publish(state, "Updating #{name_str}...")

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Cannot update #{name_str}: #{reason}"
        )
    end
  rescue
    ArgumentError ->
      NoticeWorkflow.publish(state, "Unknown tool: #{name_str}")
  end

  @doc "Executes a tool management command."
  @spec execute(state(), atom()) :: state()
  def execute(state, :tool_install) do
    PickerUI.open(state, PickerSource)
  end

  def execute(state, :tool_uninstall) do
    if ToolManager.all_installed() == [] do
      NoticeWorkflow.publish(state, "No tools installed")
    else
      PickerUI.open(state, UninstallPickerSource)
    end
  end

  def execute(state, :tool_update) do
    if ToolManager.all_installed() == [] do
      NoticeWorkflow.publish(state, "No tools installed")
    else
      PickerUI.open(state, UpdatePickerSource)
    end
  end

  def execute(state, :tool_list) do
    installed = ToolManager.all_installed()

    if installed == [] do
      NoticeWorkflow.publish(state, "No tools installed")
    else
      lines =
        installed
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn inst ->
          "  #{inst.name} v#{inst.version} (#{inst.method})"
        end)

      msg = "Installed tools:\n#{Enum.join(lines, "\n")}"
      NoticeWorkflow.publish(state, msg)
    end
  end

  def execute(state, :tool_manage) do
    PickerUI.open(state, PickerSource)
  end
end
