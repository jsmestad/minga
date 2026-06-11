defmodule MingaEditor.RenderPipeline.Chrome do
  @moduledoc """
  Chrome result struct and shared helpers.

  The `%Chrome{}` struct is the output of any shell's chrome builder.
  Shared helpers (`render_hover_popup/1`, `render_signature_help/1`)
  are used by both TUI and GUI chrome builders.

  The chrome dispatcher lives in each shell's chrome module
  (e.g., `Shell.Traditional.Chrome`).
  """

  alias MingaEditor.DisplayList
  alias MingaEditor.MinibufferData
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.StatusBar.Data, as: StatusBarData

  # ── Result struct ──────────────────────────────────────────────────────────

  defstruct status_bar_data: nil,
            minibuffer_data: nil,
            modeline_click_regions: [],
            tab_bar_click_regions: [],
            overlays: []

  @type t :: %__MODULE__{
          status_bar_data: StatusBarData.t() | nil,
          minibuffer_data: MinibufferData.t() | nil,
          modeline_click_regions: [MingaEditor.Shell.Traditional.Modeline.click_region()],
          tab_bar_click_regions: [MingaEditor.Shell.Traditional.TabBarRenderer.click_region()],
          overlays: [DisplayList.Overlay.t()]
        }

  @typedoc "Editor state or render pipeline input."
  @type state :: MingaEditor.State.t() | Input.t()
end
