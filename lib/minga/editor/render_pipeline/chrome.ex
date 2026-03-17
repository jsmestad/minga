defmodule Minga.Editor.RenderPipeline.Chrome do
  @moduledoc """
  Stage 5: Chrome.

  Builds all non-content UI draws: modeline, tab bar, minibuffer,
  separators, file tree, agent panel sidebar, overlays (which-key,
  completion, picker, float popups), and region definitions.

  The result struct (`Chrome.t()`) is consumed by the Compose stage
  to assemble the final frame.
  """

  alias Minga.Editor.CompletionUI
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Overlay}
  alias Minga.Editor.HoverPopup
  alias Minga.Editor.Layout
  alias Minga.Editor.PickerUI
  alias Minga.Editor.Renderer.Caps
  alias Minga.Editor.Renderer.Minibuffer
  alias Minga.Editor.Renderer.Regions
  alias Minga.Editor.RenderPipeline.ChromeHelpers
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll
  alias Minga.Editor.SignatureHelp
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.TreeRenderer
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Popup.Lifecycle, as: PopupLifecycle
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
          overlays: [Overlay.t()],
          regions: [binary()]
        }

  # ── Stage function ─────────────────────────────────────────────────────────

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Builds all non-content UI draws: modeline, minibuffer, separators,
  file tree, agent panel sidebar, overlays, and region definitions.

  Dispatches to `build_gui_chrome` or `build_tui_chrome` based on
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
      build_gui_chrome(state, layout, scrolls, cursor_info)
    else
      build_tui_chrome(state, layout, scrolls, cursor_info)
    end
  end

  # ── TUI path ───────────────────────────────────────────────────────────────

  @spec build_tui_chrome(
          state(),
          Layout.t(),
          %{Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: t()
  defp build_tui_chrome(state, layout, scrolls, cursor_info) do
    full_viewport = state.viewport

    # Modeline per buffer window
    {modeline_draws, modeline_click_regions} =
      Enum.reduce(scrolls, {%{}, []}, fn {win_id, scroll}, {draws_acc, regions_acc} ->
        {draws, regions} = ChromeHelpers.render_window_modeline(state, scroll)
        {Map.put(draws_acc, win_id, draws), regions ++ regions_acc}
      end)

    # Modeline per agent chat window (skipped in scrolls, rendered here)
    {modeline_draws, modeline_click_regions} =
      render_agent_modelines(state, layout, modeline_draws, modeline_click_regions)

    # Separators (vertical split borders)
    separator_draws =
      if EditorState.split?(state) do
        ChromeHelpers.render_separators(
          state.windows.tree,
          layout.editor_area,
          elem(layout.editor_area, 3),
          state.theme
        )
      else
        []
      end

    # File tree
    tree_draws = TreeRenderer.render(state)

    # Minibuffer
    {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer
    minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    # Overlays
    overlays = build_overlays(state, full_viewport, cursor_info, _gui_mode? = false)

    # Tab bar
    {tab_bar_draws, tab_bar_regions} = ChromeHelpers.render_tab_bar(state, layout)

    # Region definitions
    regions = Regions.define_regions(layout)

    %__MODULE__{
      modeline_draws: modeline_draws,
      modeline_click_regions: modeline_click_regions,
      tab_bar: tab_bar_draws,
      tab_bar_click_regions: tab_bar_regions,
      minibuffer: [minibuffer_draw],
      separators: separator_draws,
      file_tree: tree_draws,
      agent_panel: [],
      overlays: overlays,
      regions: regions
    }
  end

  # ── GUI path ───────────────────────────────────────────────────────────────

  @spec build_gui_chrome(
          state(),
          Layout.t(),
          %{Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: t()
  defp build_gui_chrome(state, layout, scrolls, cursor_info) do
    full_viewport = state.viewport

    # Modeline only for splits (SwiftUI status bar handles single window)
    {modeline_draws, modeline_click_regions} =
      if EditorState.split?(state) do
        Enum.reduce(scrolls, {%{}, []}, fn {win_id, scroll}, {draws_acc, regions_acc} ->
          {draws, regions} = ChromeHelpers.render_window_modeline(state, scroll)
          {Map.put(draws_acc, win_id, draws), regions ++ regions_acc}
        end)
      else
        {%{}, []}
      end

    # Modeline per agent chat window
    {modeline_draws, modeline_click_regions} =
      render_agent_modelines(state, layout, modeline_draws, modeline_click_regions)

    # Separators (still needed for splits in the Metal editor surface)
    separator_draws =
      if EditorState.split?(state) do
        ChromeHelpers.render_separators(
          state.windows.tree,
          layout.editor_area,
          elem(layout.editor_area, 3),
          state.theme
        )
      else
        []
      end

    # Minibuffer (rendered in Metal, not SwiftUI)
    {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer
    minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    # Overlays: only hover popup, signature help, and float popups
    # (picker, which-key, completion are handled by SwiftUI)
    overlays = build_overlays(state, full_viewport, cursor_info, _gui_mode? = true)

    # Region definitions
    regions = Regions.define_regions(layout)

    %__MODULE__{
      modeline_draws: modeline_draws,
      modeline_click_regions: modeline_click_regions,
      tab_bar: [],
      tab_bar_click_regions: [],
      minibuffer: [minibuffer_draw],
      separators: separator_draws,
      file_tree: [],
      agent_panel: [],
      overlays: overlays,
      regions: regions
    }
  end

  # ── Shared helpers ─────────────────────────────────────────────────────────

  @spec render_agent_modelines(state(), Layout.t(), map(), list()) :: {map(), list()}
  defp render_agent_modelines(state, layout, modeline_draws, modeline_click_regions) do
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

  # ── Overlay building ──────────────────────────────────────────────────────

  @spec build_overlays(state(), Minga.Editor.Viewport.t(), Cursor.t() | nil, boolean()) ::
          [Overlay.t()]
  defp build_overlays(state, viewport, cursor_info, gui_mode?) do
    render_overlays_flag = Caps.render_overlays?(state.capabilities)

    {picker_draws, picker_cursor} =
      if gui_mode?, do: {[], nil}, else: PickerUI.render(state, viewport)

    whichkey_draws =
      if gui_mode? or not render_overlays_flag,
        do: [],
        else: ChromeHelpers.render_whichkey(state, viewport)

    completion_draws =
      if gui_mode?,
        do: [],
        else: build_completion_draws(state, cursor_info)

    hover_draws = render_hover_popup(state)
    sig_help_draws = render_signature_help(state)
    float_overlays = PopupLifecycle.render_float_overlays(state)

    (float_overlays ++
       [
         %Overlay{draws: hover_draws},
         %Overlay{draws: sig_help_draws},
         %Overlay{draws: whichkey_draws},
         %Overlay{draws: completion_draws},
         %Overlay{draws: picker_draws, cursor: picker_cursor}
       ])
    |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)
  end

  @spec build_completion_draws(state(), Cursor.t() | nil) :: [DisplayList.draw()]
  defp build_completion_draws(state, %Cursor{row: cur_row, col: cur_col}) do
    CompletionUI.render(
      state.completion,
      %{
        cursor_row: cur_row,
        cursor_col: cur_col,
        viewport_rows: state.viewport.rows,
        viewport_cols: state.viewport.cols
      },
      state.theme
    )
  end

  defp build_completion_draws(_state, nil), do: []

  # ── Hover popup ──────────────────────────────────────────────────────────

  @spec render_hover_popup(state()) :: [DisplayList.draw()]
  defp render_hover_popup(%{hover_popup: nil}), do: []

  defp render_hover_popup(%{hover_popup: popup, viewport: vp, theme: theme}) do
    HoverPopup.render(popup, {vp.rows, vp.cols}, theme)
  end

  @spec render_signature_help(state()) :: [DisplayList.draw()]
  defp render_signature_help(%{signature_help: nil}), do: []

  defp render_signature_help(%{signature_help: sh, viewport: vp, theme: theme}) do
    SignatureHelp.render(sh, {vp.rows, vp.cols}, theme)
  end
end
