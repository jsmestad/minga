defmodule Minga.Editor.RenderPipeline.Chrome.TUI do
  @moduledoc """
  TUI chrome builder.

  Builds all non-content UI draws for the Zig/libvaxis terminal frontend:
  modeline per window, tab bar, minibuffer, file tree, separators,
  and all overlays (picker, which-key, completion, hover, signature help).
  """

  alias Minga.Editor.CompletionUI
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Overlay}
  alias Minga.Editor.Layout
  alias Minga.Editor.PickerUI
  alias Minga.Editor.Renderer.Caps
  alias Minga.Editor.Renderer.Minibuffer
  alias Minga.Editor.Renderer.Regions
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.ChromeHelpers
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.TreeRenderer
  alias Minga.Popup.Lifecycle, as: PopupLifecycle

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Builds TUI chrome: modeline, tab bar, minibuffer, file tree,
  separators, and all overlays.
  """
  @spec build(
          state(),
          Layout.t(),
          %{Minga.Editor.Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build(state, layout, scrolls, cursor_info) do
    full_viewport = state.viewport

    # Modeline per buffer window
    {modeline_draws, modeline_click_regions} =
      Enum.reduce(scrolls, {%{}, []}, fn {_win_id, scroll}, {draws_acc, regions_acc} ->
        {draws, regions} = ChromeHelpers.render_window_modeline(state, scroll)
        {Map.put(draws_acc, scroll.win_id, draws), regions ++ regions_acc}
      end)

    # Modeline per agent chat window
    {modeline_draws, modeline_click_regions} =
      Chrome.render_agent_modelines(state, layout, modeline_draws, modeline_click_regions)

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

    # Overlays (all types for TUI)
    overlays = build_overlays(state, full_viewport, cursor_info)

    # Tab bar
    {tab_bar_draws, tab_bar_regions} = ChromeHelpers.render_tab_bar(state, layout)

    # Region definitions
    regions = Regions.define_regions(layout)

    %Chrome{
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

  # ── Overlays ──────────────────────────────────────────────────────────────

  @spec build_overlays(state(), Minga.Editor.Viewport.t(), Cursor.t() | nil) :: [Overlay.t()]
  defp build_overlays(state, viewport, cursor_info) do
    render_overlays_flag = Caps.render_overlays?(state.capabilities)

    {picker_draws, picker_cursor} = PickerUI.render(state, viewport)

    whichkey_draws =
      if render_overlays_flag,
        do: ChromeHelpers.render_whichkey(state, viewport),
        else: []

    completion_draws = build_completion_draws(state, cursor_info)
    hover_draws = Chrome.render_hover_popup(state)
    sig_help_draws = Chrome.render_signature_help(state)
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
end
