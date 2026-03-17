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
  """
  @spec build_chrome(
          state(),
          Layout.t(),
          %{Window.id() => WindowScroll.t()},
          Cursor.t() | nil
        ) :: t()
  def build_chrome(state, layout, scrolls, cursor_info) do
    full_viewport = state.viewport

    # Modeline per buffer window.
    # In GUI mode with a single window, skip modeline draws (SwiftUI status bar
    # handles it). Keep modeline for splits so each window shows its own status.
    gui_single_window? = Capabilities.gui?(state.capabilities) && !EditorState.split?(state)

    {modeline_draws, modeline_click_regions} =
      if gui_single_window? do
        {%{}, []}
      else
        Enum.reduce(scrolls, {%{}, []}, fn {win_id, scroll}, {draws_acc, regions_acc} ->
          {draws, regions} = ChromeHelpers.render_window_modeline(state, scroll)
          {Map.put(draws_acc, win_id, draws), regions ++ regions_acc}
        end)
      end

    # Modeline per agent chat window (skipped in scrolls, rendered here)
    {modeline_draws, modeline_click_regions} =
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

    # File tree: skip cell-grid rendering in GUI mode (SwiftUI renders it natively)
    tree_draws =
      if Capabilities.gui?(state.capabilities) do
        []
      else
        TreeRenderer.render(state)
      end

    # Agent panel: rendered through buffer pipeline via {:agent_chat, _} windows.
    agent_draws = []

    # Minibuffer
    {minibuffer_row, _mbc, _mbw, _mbh} = layout.minibuffer
    minibuffer_draw = Minibuffer.render(state, minibuffer_row, full_viewport.cols)

    # Overlays
    render_overlays_flag = Caps.render_overlays?(state.capabilities)
    {picker_draws, picker_cursor} = PickerUI.render(state, full_viewport)

    gui_mode? = Capabilities.gui?(state.capabilities)

    # Skip which-key and completion draws in GUI mode (SwiftUI renders them)
    whichkey_draws =
      if gui_mode? or not render_overlays_flag do
        []
      else
        ChromeHelpers.render_whichkey(state, full_viewport)
      end

    completion_draws =
      if gui_mode? do
        []
      else
        case cursor_info do
          %Cursor{row: cur_row, col: cur_col} ->
            CompletionUI.render(
              state.completion,
              %{
                cursor_row: cur_row,
                cursor_col: cur_col,
                viewport_rows: full_viewport.rows,
                viewport_cols: full_viewport.cols
              },
              state.theme
            )

          nil ->
            []
        end
      end

    # Hover popup overlay
    hover_draws = render_hover_popup(state)

    # Signature help overlay
    sig_help_draws = render_signature_help(state)

    # Float popup overlays (from the popup system)
    float_overlays = PopupLifecycle.render_float_overlays(state)

    overlays =
      (float_overlays ++
         [
           %Overlay{draws: hover_draws},
           %Overlay{draws: sig_help_draws},
           %Overlay{draws: whichkey_draws},
           %Overlay{draws: completion_draws},
           %Overlay{draws: picker_draws, cursor: picker_cursor}
         ])
      |> Enum.reject(fn %Overlay{draws: d} -> d == [] end)

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
      agent_panel: agent_draws,
      overlays: overlays,
      regions: regions
    }
  end

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
