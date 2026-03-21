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
  alias Minga.Editor.MinibufferData
  alias Minga.Editor.Renderer.Minibuffer
  alias Minga.Editor.Renderer.Regions
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.ChromeHelpers
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.StatusBar.Data, as: StatusBarData
  alias Minga.Popup.Lifecycle, as: PopupLifecycle

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc """
  Builds GUI chrome: status bar data (for SwiftUI encoding), horizontal separators
  in the Metal surface, minibuffer, and Metal-rendered overlays (hover, signature
  help, float popups). SwiftUI handles tab bar, file tree, picker, which-key,
  and completion natively.
  """
  @spec build(
          state(),
          Layout.t(),
          %{Minga.Editor.Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: Chrome.t()
  def build(state, layout, _scrolls, _cursor_info) do
    full_viewport = state.viewport

    # Compute status bar data (used by Emit.GUI to encode the 0x76 opcode).
    # No cell rendering for the GUI — SwiftUI owns the status bar surface.
    status_bar_data = StatusBarData.from_state(state)

    # Vertical split borders (still drawn in Metal)
    vertical_separators =
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

    # Horizontal split separators (filename bars, drawn in Metal)
    horizontal_separators =
      ChromeHelpers.render_horizontal_separators(layout.horizontal_separators, state.theme)

    separator_draws = vertical_separators ++ horizontal_separators

    # Minibuffer (rendered in Metal for backward compat; covered by native SwiftUI view)
    {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer
    minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    # Structured minibuffer data for native SwiftUI rendering (0x7F opcode)
    minibuffer_data = MinibufferData.from_state(state)

    # Overlays: only hover popup, signature help, and float popups.
    # Picker, which-key, and completion are handled by SwiftUI.
    overlays = build_overlays(state)

    # Region definitions
    regions = Regions.define_regions(layout)

    %Chrome{
      status_bar_draws: [],
      status_bar_data: status_bar_data,
      minibuffer_data: minibuffer_data,
      modeline_click_regions: [],
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
