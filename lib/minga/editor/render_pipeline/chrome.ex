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
  alias Minga.Editor.RenderPipeline.ChromeHelpers
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll
  alias Minga.Editor.SignatureHelp
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Port.Capabilities

  # ── Result struct ──────────────────────────────────────────────────────────

  @enforce_keys []
  defstruct modeline_draws: %{},
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
          modeline_draws: %{non_neg_integer() => [DisplayList.draw()]},
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
    if Capabilities.gui?(state.capabilities) do
      __MODULE__.GUI.build(state, layout, scrolls, cursor_info)
    else
      __MODULE__.TUI.build(state, layout, scrolls, cursor_info)
    end
  end

  # ── Shared helpers (used by both TUI and GUI submodules) ───────────────────

  @doc """
  Builds modeline draws for agent chat windows.

  Agent chat windows are not part of the scroll pipeline (they don't have
  buffer viewports), so their modelines are rendered separately here.
  """
  @spec render_agent_modelines(state(), Layout.t(), map(), list()) :: {map(), list()}
  def render_agent_modelines(state, layout, modeline_draws, modeline_click_regions) do
    layout.window_layouts
    |> Enum.reduce({modeline_draws, modeline_click_regions}, fn {win_id, win_layout},
                                                                {draws_acc, regions_acc} ->
      window = Map.get(state.windows.map, win_id)

      if window != nil and Content.agent_chat?(window.content) do
        {draws, regions} = ChromeHelpers.render_agent_modeline(state, win_layout)
        {Map.put(draws_acc, win_id, draws), regions ++ regions_acc}
      else
        {draws_acc, regions_acc}
      end
    end)
  end

  @doc "Renders the hover popup overlay draws."
  @spec render_hover_popup(state()) :: [DisplayList.draw()]
  def render_hover_popup(%{hover_popup: nil}), do: []

  def render_hover_popup(%{hover_popup: popup, viewport: vp, theme: theme}) do
    HoverPopup.render(popup, {vp.rows, vp.cols}, theme)
  end

  @doc "Renders signature help overlay draws."
  @spec render_signature_help(state()) :: [DisplayList.draw()]
  def render_signature_help(%{signature_help: nil}), do: []

  def render_signature_help(%{signature_help: sh, viewport: vp, theme: theme}) do
    SignatureHelp.render(sh, {vp.rows, vp.cols}, theme)
  end
end
