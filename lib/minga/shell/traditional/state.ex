defmodule Minga.Shell.Traditional.State do
  @moduledoc """
  Presentation state for the traditional tab-based editor shell.

  These fields are presentation concerns: they control how the editor
  looks and behaves visually, but have no effect on the core editing
  model. Each field was migrated from `Minga.Editor.State` as part of
  Phase F of the Core/Shell separation.

  ## Batch 1 fields

  - `nav_flash` — cursor line flash after large jumps
  - `hover_popup` — LSP hover popup (positioned text overlay)
  - `dashboard` — home screen state (cursor, items) when no buffers open
  - `status_msg` — transient status message in the modeline
  """

  @type t :: %__MODULE__{
          nav_flash: Minga.Editor.NavFlash.t() | nil,
          hover_popup: Minga.Editor.HoverPopup.t() | nil,
          dashboard: Minga.Editor.Dashboard.state() | nil,
          status_msg: String.t() | nil,
          picker_ui: Minga.Editor.State.Picker.t(),
          prompt_ui: Minga.Editor.State.Prompt.t(),
          whichkey: Minga.Editor.State.WhichKey.t()
        }

  defstruct nav_flash: nil,
            hover_popup: nil,
            dashboard: nil,
            status_msg: nil,
            picker_ui: %Minga.Editor.State.Picker{},
            prompt_ui: %Minga.Editor.State.Prompt{},
            whichkey: %Minga.Editor.State.WhichKey{}
end
