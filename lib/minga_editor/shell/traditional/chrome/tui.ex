defmodule MingaEditor.Shell.Traditional.Chrome.TUI do
  @moduledoc """
  TUI chrome builder.

  Builds all non-content UI draws for the Zig/libvaxis terminal frontend:
  modeline per window, tab bar, minibuffer, file tree, separators,
  and all overlays (picker, which-key, completion, hover, signature help).
  """

  alias MingaEditor.CompletionUI
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, Overlay}
  alias MingaEditor.Layout
  alias MingaEditor.PickerUI
  alias MingaEditor.Renderer.Caps
  alias MingaEditor.Renderer.Minibuffer
  alias MingaEditor.Renderer.Regions
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.Shell.Traditional.Chrome.Helpers, as: ChromeHelpers
  alias MingaEditor.Shell.Traditional.Modeline
  alias MingaEditor.Shell.Traditional.TreeRenderer
  alias MingaEditor.UI.Popup.Lifecycle, as: PopupLifecycle

  @typedoc "Internal editor state."
  @type state :: EditorState.t() | MingaEditor.RenderPipeline.Input.t()

  @doc """
  Builds TUI chrome: global status bar, tab bar, minibuffer, file tree,
  separators (vertical + horizontal), and all overlays.
  """
  @spec build(
          state(),
          Layout.t(),
          %{MingaEditor.Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build(state, layout, _scrolls, cursor_info) do
    full_viewport = state.workspace.viewport

    # Global status bar (one render for the focused window)
    {status_bar_draws, status_bar_data, modeline_click_regions} =
      build_status_bar(state, layout)

    # Vertical split borders
    vertical_separators =
      if MingaEditor.State.Windows.split?(state.workspace.windows) do
        ChromeHelpers.render_separators(
          state.workspace.windows.tree,
          layout.editor_area,
          elem(layout.editor_area, 3),
          state.theme
        )
      else
        []
      end

    # Horizontal split separators (filename bars)
    horizontal_separators =
      ChromeHelpers.render_horizontal_separators(layout.horizontal_separators, state.theme)

    separator_draws = vertical_separators ++ horizontal_separators

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
      status_bar_draws: status_bar_draws,
      status_bar_data: status_bar_data,
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

  @spec build_status_bar(state(), Layout.t()) ::
          {[DisplayList.draw()], StatusBarData.t(),
           [MingaEditor.Shell.Traditional.Modeline.click_region()]}
  defp build_status_bar(_state, %{status_bar: nil}) do
    {[], nil, []}
  end

  defp build_status_bar(state, layout) do
    {sb_row, _sb_col, sb_width, _sb_h} = layout.status_bar
    status_bar_data = StatusBarData.from_state(state)
    modeline_data = StatusBarData.to_modeline_data(status_bar_data)
    {draws, click_regions} = Modeline.render(sb_row, sb_width, modeline_data, state.theme)
    {draws, status_bar_data, click_regions}
  end

  # ── Overlays ──────────────────────────────────────────────────────────────

  @spec build_overlays(state(), MingaEditor.Viewport.t(), Cursor.t() | nil) :: [Overlay.t()]
  defp build_overlays(state, viewport, cursor_info) do
    render_overlays_flag = Caps.render_overlays?(state.capabilities)

    {picker_draws, picker_cursor} = PickerUI.render(state, viewport)
    {prompt_draws, prompt_cursor} = MingaEditor.PromptUI.render(state, viewport)

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
         %Overlay{draws: picker_draws, cursor: picker_cursor},
         %Overlay{draws: prompt_draws, cursor: prompt_cursor}
       ])
    |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)
  end

  @spec build_completion_draws(state(), Cursor.t() | nil) :: [DisplayList.draw()]
  defp build_completion_draws(state, %Cursor{row: cur_row, col: cur_col}) do
    CompletionUI.render(
      state.workspace.completion,
      %{
        cursor_row: cur_row,
        cursor_col: cur_col,
        viewport_rows: state.workspace.viewport.rows,
        viewport_cols: state.workspace.viewport.cols
      },
      state.theme
    )
  end

  defp build_completion_draws(_state, nil), do: []
end
