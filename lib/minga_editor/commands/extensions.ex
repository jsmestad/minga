defmodule MingaEditor.Commands.Extensions do
  @moduledoc """
  Extension management commands: list, update, and inspect extensions.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @spec list(state()) :: state()
  def list(state), do: PickerUI.open(state, MingaEditor.UI.Picker.ExtensionListSource)

  @spec update_all(state()) :: state()
  def update_all(state) do
    alias Minga.Extension.Updater

    Task.start(fn -> Updater.check_all() end)

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Checking for extension updates..."
    )
  end

  @spec update(state()) :: state()
  def update(state) do
    PickerUI.open(state, MingaEditor.UI.Picker.ExtensionSource)
  end

  @spec apply_updates(state()) :: state()
  def apply_updates(state) do
    alias MingaEditor.Editing
    alias Minga.Extension.Updater

    ms = Editing.mode_state(state)
    Task.start(fn -> Updater.apply_accepted(ms) end)

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Applying extension updates...")
  end

  @spec confirm_details(state()) :: state()
  def confirm_details(state) do
    alias MingaEditor.Editing
    alias Minga.Extension.Updater

    ms = Editing.mode_state(state)
    update = Enum.at(ms.updates, ms.current)
    details = Updater.details(update.name)
    Minga.Log.info(:editor, details)
    state
  end

  command(:extension_list, "List extensions", requires_buffer: true, execute: &list/1)

  command(:extension_update_all, "Check all extension updates",
    requires_buffer: true,
    execute: &update_all/1
  )

  command(:extension_update, "Update extension", requires_buffer: true, execute: &update/1)

  command(:apply_extension_updates, "Apply extension updates",
    requires_buffer: true,
    execute: &apply_updates/1
  )

  command(:extension_confirm_details, "Extension update details",
    requires_buffer: true,
    execute: &confirm_details/1
  )
end
