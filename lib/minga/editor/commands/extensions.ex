defmodule Minga.Editor.Commands.Extensions do
  @moduledoc """
  Extension management commands: list, update, and inspect extensions.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @spec list(state()) :: state()
  def list(state) do
    alias Minga.Extension.Registry, as: ExtRegistry
    alias Minga.Extension.Supervisor, as: ExtSupervisor

    extensions = ExtSupervisor.list_extensions()
    all_entries = ExtRegistry.all()

    msg =
      case extensions do
        [] ->
          "No extensions loaded"

        exts ->
          lines =
            Enum.map(exts, fn {name, version, status} ->
              source_label = format_source_label(name, all_entries)
              "  #{name} v#{version} [#{status}] (#{source_label})"
            end)

          ["Extensions:" | lines] |> Enum.join("\n")
      end

    %{state | status_msg: msg}
  end

  @spec update_all(state()) :: state()
  def update_all(state) do
    alias Minga.Extension.Updater

    Task.start(fn -> Updater.check_all() end)
    %{state | status_msg: "Checking for extension updates..."}
  end

  @spec update(state()) :: state()
  def update(state) do
    PickerUI.open(state, Minga.Picker.ExtensionSource)
  end

  @spec apply_updates(state()) :: state()
  def apply_updates(state) do
    alias Minga.Extension.Updater

    ms = state.vim.mode_state
    Task.start(fn -> Updater.apply_accepted(ms) end)

    %{state | status_msg: "Applying extension updates..."}
  end

  @spec confirm_details(state()) :: state()
  def confirm_details(state) do
    alias Minga.Extension.Updater

    ms = state.vim.mode_state
    update = Enum.at(ms.updates, ms.current)
    details = Updater.details(update.name)
    Minga.Editor.log_to_messages(details)
    state
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec format_source_label(atom(), [{atom(), Minga.Extension.Entry.t()}]) :: String.t()
  defp format_source_label(name, all_entries) do
    case List.keyfind(all_entries, name, 0) do
      {_, %{source_type: :path, path: path}} -> "path: #{path}"
      {_, %{source_type: :git, git: %{url: url}}} -> "git: #{url}"
      {_, %{source_type: :hex, hex: %{package: pkg}}} -> "hex: #{pkg}"
      _ -> "unknown"
    end
  end

  @impl Minga.Command.Provider
  def __commands__ do
    [
      %Minga.Command{
        name: :extension_list,
        description: "List extensions",
        requires_buffer: true,
        execute: &list/1
      },
      %Minga.Command{
        name: :extension_update_all,
        description: "Check all extension updates",
        requires_buffer: true,
        execute: &update_all/1
      },
      %Minga.Command{
        name: :extension_update,
        description: "Update extension",
        requires_buffer: true,
        execute: &update/1
      },
      %Minga.Command{
        name: :apply_extension_updates,
        description: "Apply extension updates",
        requires_buffer: true,
        execute: &apply_updates/1
      },
      %Minga.Command{
        name: :extension_confirm_details,
        description: "Extension update details",
        requires_buffer: true,
        execute: &confirm_details/1
      }
    ]
  end
end
