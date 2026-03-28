defmodule Minga.Editor.RenderPipeline.Chrome do
  @moduledoc """
  Chrome result struct and shared helpers.

  The `%Chrome{}` struct is the output of any shell's chrome builder.
  Shared helpers (`render_hover_popup/1`, `render_signature_help/1`)
  are used by both TUI and GUI chrome builders.

  The chrome dispatcher lives in each shell's chrome module
  (e.g., `Shell.Traditional.Chrome`).
  """

  alias Minga.Editor.DisplayList
  alias Minga.Editor.HoverPopup
  alias Minga.Editor.MinibufferData
  alias Minga.Editor.SignatureHelp
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.StatusBar.Data, as: StatusBarData

  # ── Result struct ──────────────────────────────────────────────────────────

  defstruct status_bar_draws: [],
            status_bar_data: nil,
            minibuffer_data: nil,
            modeline_click_regions: [],
            tab_bar: [],
            tab_bar_click_regions: [],
            minibuffer: [],
            separators: [],
            file_tree: [],
            agent_panel: [],
            overlays: [],
            regions: []

  @type t :: %__MODULE__{
          status_bar_draws: [DisplayList.draw()],
          status_bar_data: StatusBarData.t() | nil,
          minibuffer_data: MinibufferData.t() | nil,
          modeline_click_regions: [Minga.Shell.Traditional.Modeline.click_region()],
          tab_bar: [DisplayList.draw()],
          tab_bar_click_regions: [Minga.Shell.Traditional.TabBarRenderer.click_region()],
          minibuffer: [DisplayList.draw()],
          separators: [DisplayList.draw()],
          file_tree: [DisplayList.draw()],
          agent_panel: [DisplayList.draw()],
          overlays: [DisplayList.Overlay.t()],
          regions: [binary()]
        }

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  # ── Shared helpers (used by shell chrome builders) ─────────────────────────

  @doc "Renders the hover popup overlay draws."
  @spec render_hover_popup(state()) :: [DisplayList.draw()]
  def render_hover_popup(%{shell_state: %{hover_popup: nil}}), do: []

  def render_hover_popup(%{
        shell_state: %{hover_popup: popup},
        workspace: %{viewport: vp},
        theme: theme
      }) do
    HoverPopup.render(popup, {vp.rows, vp.cols}, theme)
  end

  @doc "Renders signature help overlay draws."
  @spec render_signature_help(state()) :: [DisplayList.draw()]
  def render_signature_help(%{shell_state: %{signature_help: nil}}), do: []

  def render_signature_help(%{
        shell_state: %{signature_help: sh},
        workspace: %{viewport: vp},
        theme: theme
      }) do
    SignatureHelp.render(sh, {vp.rows, vp.cols}, theme)
  end
end
