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
  alias MingaEditor.Renderer.CommandCompletionUI
  alias MingaEditor.Renderer.Minibuffer
  alias MingaEditor.Renderer.Regions
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.Shell.Traditional.Chrome.Helpers, as: ChromeHelpers
  alias MingaEditor.Shell.Traditional.Modeline
  alias MingaEditor.Shell.Traditional.GitStatusRenderer
  alias MingaEditor.Shell.Traditional.TreeRenderer
  alias MingaEditor.Session.ChromeState
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
  def build(state, layout, scrolls, cursor_info) do
    full_viewport = state.terminal_viewport

    # Global status bar (one render for the focused window)
    {status_bar_draws, status_bar_data, modeline_click_regions} =
      build_status_bar(state, layout, Map.get(scrolls, state.workspace.windows.active))

    stable_fp = stable_chrome_fingerprint(state, layout, status_bar_data)

    stable =
      case state.caches.chrome_prev_result do
        %Chrome{stable_fingerprint: ^stable_fp} = prev ->
          prev

        _ ->
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

          # Sidebar: git status panel replaces file tree when active
          tree_draws = sidebar_draws(state, layout)

          # Minibuffer
          {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer
          minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

          # Tab bar
          {tab_bar_draws, tab_bar_regions} = ChromeHelpers.render_tab_bar(state, layout)

          # Region definitions
          regions = Regions.define_regions(layout)

          %Chrome{
            stable_fingerprint: stable_fp,
            tab_bar: tab_bar_draws,
            tab_bar_click_regions: tab_bar_regions,
            minibuffer: [minibuffer_draw],
            separators: separator_draws,
            file_tree: tree_draws,
            regions: regions
          }
      end

    # Overlays (all types for TUI)
    {minibuffer_row_for_overlay, _, _, _} = layout.minibuffer

    status_bar_bottom =
      case layout.status_bar do
        {sb_row, _, _, sb_h} -> sb_row + sb_h
        nil -> 0
      end

    overlays =
      build_overlays(
        state,
        full_viewport,
        cursor_info,
        minibuffer_row_for_overlay,
        status_bar_bottom
      )

    %Chrome{
      status_bar_draws: status_bar_draws,
      status_bar_data: status_bar_data,
      modeline_click_regions: modeline_click_regions,
      tab_bar: stable.tab_bar,
      tab_bar_click_regions: stable.tab_bar_click_regions,
      minibuffer: stable.minibuffer,
      separators: stable.separators,
      file_tree: stable.file_tree,
      agent_panel: [],
      overlays: overlays,
      regions: stable.regions,
      stable_fingerprint: stable_fp
    }
  end

  @spec sidebar_draws(state(), Layout.t()) :: [DisplayList.draw()]
  defp sidebar_draws(%{workspace: %{keymap_scope: :git_status}} = state, layout) do
    GitStatusRenderer.render(state, layout.file_tree)
  end

  defp sidebar_draws(state, _layout), do: TreeRenderer.render(state)

  @spec stable_chrome_fingerprint(state(), Layout.t(), StatusBarData.t()) :: integer()
  defp stable_chrome_fingerprint(state, layout, status_bar_data) do
    :erlang.phash2({
      layout.editor_area,
      layout.horizontal_separators,
      layout.minibuffer,
      layout.status_bar,
      state.workspace.windows.tree,
      state.workspace.file_tree,
      state.workspace.keymap_scope,
      ChromeState.from_editor_state(state),
      state.shell_state |> Map.get(:git_status_panel),
      state.shell_state |> Map.get(:git_status_tui_state),
      state.workspace.editing.mode,
      state.workspace.editing.mode_state,
      status_bar_dirty?(status_bar_data),
      state.shell_state.status_msg,
      state.theme
    })
  end

  @spec build_status_bar(state(), Layout.t(), map() | nil) ::
          {[DisplayList.draw()], StatusBarData.t(),
           [MingaEditor.Shell.Traditional.Modeline.click_region()]}
  defp build_status_bar(_state, %{status_bar: nil}, _active_scroll) do
    {[], nil, []}
  end

  defp build_status_bar(state, layout, active_scroll) do
    {sb_row, _sb_col, sb_width, _sb_h} = layout.status_bar
    status_bar_data = cached_or_fresh_status_bar_data(state, active_scroll)
    modeline_data = StatusBarData.to_modeline_data(status_bar_data)
    {draws, click_regions} = Modeline.render(sb_row, sb_width, modeline_data, state.theme)
    {draws, status_bar_data, click_regions}
  end

  @spec cached_or_fresh_status_bar_data(state(), map() | nil) :: StatusBarData.t()
  defp cached_or_fresh_status_bar_data(state, _active_scroll) do
    StatusBarData.from_state(state)
  catch
    :exit, _ -> StatusBarData.from_state(state)
  end

  @spec status_bar_dirty?(StatusBarData.t()) :: boolean()
  defp status_bar_dirty?({:buffer, %{dirty: dirty}}), do: dirty
  defp status_bar_dirty?({:agent, %{dirty: dirty}}), do: dirty

  # ── Overlays ──────────────────────────────────────────────────────────────

  @spec build_overlays(
          state(),
          MingaEditor.Viewport.t(),
          Cursor.t() | nil,
          non_neg_integer(),
          non_neg_integer()
        ) :: [Overlay.t()]
  defp build_overlays(state, viewport, cursor_info, minibuffer_row, status_bar_bottom) do
    render_overlays_flag = Caps.render_overlays?(state.capabilities)

    {picker_draws, picker_cursor} = PickerUI.render(state, viewport)
    {prompt_draws, prompt_cursor} = MingaEditor.PromptUI.render(state, viewport)

    whichkey_draws =
      if render_overlays_flag,
        do: ChromeHelpers.render_whichkey(state, viewport),
        else: []

    completion_draws = build_completion_draws(state, cursor_info)

    command_completion_draws =
      build_command_completion_draws(state, viewport, minibuffer_row, status_bar_bottom)

    hover_draws = Chrome.render_hover_popup(state)
    sig_help_draws = Chrome.render_signature_help(state)
    float_overlays = PopupLifecycle.render_float_overlays(state)

    (float_overlays ++
       [
         %Overlay{draws: hover_draws},
         %Overlay{draws: sig_help_draws},
         %Overlay{draws: whichkey_draws},
         %Overlay{draws: completion_draws},
         %Overlay{draws: command_completion_draws},
         %Overlay{draws: picker_draws, cursor: picker_cursor},
         %Overlay{draws: prompt_draws, cursor: prompt_cursor}
       ])
    |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)
  end

  @spec build_completion_draws(state(), Cursor.t() | nil) :: [DisplayList.draw()]
  defp build_completion_draws(state, %Cursor{row: cur_row, col: cur_col}) do
    CompletionUI.render(
      MingaEditor.State.ModalOverlay.completion(state),
      %{
        cursor_row: cur_row,
        cursor_col: cur_col,
        viewport_rows: state.terminal_viewport.rows,
        viewport_cols: state.terminal_viewport.cols
      },
      state.theme
    )
  end

  defp build_completion_draws(_state, nil), do: []

  @spec build_command_completion_draws(
          state(),
          MingaEditor.Viewport.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp build_command_completion_draws(state, viewport, minibuffer_row, top_boundary) do
    CommandCompletionUI.render(
      ModalOverlay.command_completion(state),
      %{
        minibuffer_row: minibuffer_row,
        top_boundary: top_boundary,
        viewport_rows: viewport.rows,
        viewport_cols: viewport.cols
      },
      state.theme
    )
  end
end
