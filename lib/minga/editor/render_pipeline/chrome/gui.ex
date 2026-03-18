defmodule Minga.Editor.RenderPipeline.Chrome.GUI do
  @moduledoc """
  GUI chrome builder.

  Builds non-content UI draws for the Metal/SwiftUI frontend. Most chrome
  (tab bar, file tree, picker, which-key, completion) is handled natively
  by SwiftUI and excluded here. Only Metal-rendered elements are included:
  modeline (for splits), minibuffer, separators, and hover/signature overlays.
  """

  alias Minga.Editor.DisplayList.{Cursor, Overlay}
  alias Minga.Editor.Layout
  alias Minga.Editor.Renderer.Minibuffer
  alias Minga.Editor.Renderer.Regions
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.ChromeHelpers
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll

  alias Minga.Editor.State, as: EditorState
  alias Minga.Popup.Lifecycle, as: PopupLifecycle

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Builds GUI chrome: modeline (splits only), minibuffer, separators,
  and Metal-rendered overlays (hover, signature help, float popups).
  """
  @spec build(
          state(),
          Layout.t(),
          %{Minga.Editor.Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build(state, layout, scrolls, _cursor_info) do
    full_viewport = state.viewport

    # Modeline only for splits (SwiftUI status bar handles single window)
    {modeline_draws, modeline_click_regions} =
      if EditorState.split?(state) do
        Enum.reduce(scrolls, {%{}, []}, fn {_win_id, scroll}, {draws_acc, regions_acc} ->
          {draws, regions} = ChromeHelpers.render_window_modeline(state, scroll)
          {Map.put(draws_acc, scroll.win_id, draws), regions ++ regions_acc}
        end)
      else
        {%{}, []}
      end

    # Modeline per agent chat window
    {modeline_draws, modeline_click_regions} =
      Chrome.render_agent_modelines(state, layout, modeline_draws, modeline_click_regions)

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

    # Overlays: only hover popup, signature help, and float popups.
    # Picker, which-key, and completion are handled by SwiftUI.
    overlays = build_overlays(state)

    # Region definitions
    regions = Regions.define_regions(layout)

    %Chrome{
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

  # ── Overlays ──────────────────────────────────────────────────────────────

  @spec build_overlays(state()) :: [Overlay.t()]
  defp build_overlays(state) do
    hover_draws = Chrome.render_hover_popup(state)
    sig_help_draws = Chrome.render_signature_help(state)
    float_overlays = PopupLifecycle.render_float_overlays(state)

    (float_overlays ++
       [
         %Overlay{draws: hover_draws},
         %Overlay{draws: sig_help_draws}
       ])
    |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)
  end
end
