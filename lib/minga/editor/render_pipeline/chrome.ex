defmodule Minga.Editor.RenderPipeline.Chrome do
  @moduledoc """
  Stage 5: Chrome.

  Dispatches to `Chrome.TUI` or `Chrome.GUI` based on frontend capabilities.
  Both return the same `Chrome.t()` struct. Shared helpers used by both
  submodules live here.

  TUI chrome includes everything: modeline, tab bar, minibuffer, file tree,
  separators, and all overlays (picker, which-key, completion, hover, etc.).

  GUI chrome includes only Metal-rendered elements: modeline (for splits),
  minibuffer, separators, and hover/signature overlays. SwiftUI handles
  tab bar, file tree, picker, which-key, and completion natively.
  """

  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.Cursor
  alias Minga.Editor.HoverPopup
  alias Minga.Editor.Layout
  alias Minga.Editor.MinibufferData
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll
  alias Minga.Editor.SignatureHelp
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.StatusBar.Data, as: StatusBarData
  alias Minga.Editor.Window

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
          modeline_click_regions: [Minga.Editor.Modeline.click_region()],
          tab_bar: [DisplayList.draw()],
          tab_bar_click_regions: [Minga.Editor.TabBarRenderer.click_region()],
          minibuffer: [DisplayList.draw()],
          separators: [DisplayList.draw()],
          file_tree: [DisplayList.draw()],
          agent_panel: [DisplayList.draw()],
          overlays: [DisplayList.Overlay.t()],
          regions: [binary()]
        }

  # ── Stage dispatcher ───────────────────────────────────────────────────────

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Builds all non-content UI draws.

  Dispatches to `Chrome.TUI.build/4` or `Chrome.GUI.build/4` based on
  frontend capabilities. Both return the same `Chrome.t()` struct.
  """
  @spec build_chrome(
          state(),
          Layout.t(),
          %{Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: t()
  def build_chrome(state, layout, scrolls, cursor_info) do
    if Minga.Frontend.gui?(state.capabilities) do
      __MODULE__.GUI.build(state, layout, scrolls, cursor_info)
    else
      __MODULE__.TUI.build(state, layout, scrolls, cursor_info)
    end
  end

  # ── Shared helpers (used by both TUI and GUI submodules) ───────────────────

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
