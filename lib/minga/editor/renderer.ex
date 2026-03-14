defmodule Minga.Editor.Renderer do
  @moduledoc """
  Buffer and UI rendering for the editor.

  This module is the public API for rendering. It delegates to
  `RenderPipeline`, which decomposes rendering into seven named stages:
  Invalidation, Layout, Scroll, Content, Chrome, Compose, Emit.

  `render/1` returns the updated editor state with per-window render
  caches populated. Callers must use the returned state so that
  dirty-line tracking works across frames.

  Sub-modules handle focused rendering concerns:

  * `Renderer.Gutter`          — line number rendering
  * `Renderer.Line`            — line content and selection rendering
  * `Renderer.SearchHighlight` — search/substitute highlight overlays
  * `Renderer.Minibuffer`      — command/search/status line
  * `Renderer.Caps`            — capability-aware rendering helpers
  * `Renderer.Regions`         — region definition commands
  * `DisplayList`              — frame assembly and protocol conversion
  """

  alias Minga.Editor.Dashboard
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DisplayList.{Cursor, Frame}
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.State, as: EditorState
  alias Minga.Port.Manager, as: PortManager

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc """
  Represents the bounds of a visual selection for rendering.

  * `nil` — no active selection
  * `{:char, start_pos, end_pos}` — characterwise selection
  * `{:line, start_line, end_line}` — linewise selection
  """
  @type visual_selection ::
          nil
          | {:char, {non_neg_integer(), non_neg_integer()},
             {non_neg_integer(), non_neg_integer()}}
          | {:line, non_neg_integer(), non_neg_integer()}

  @doc """
  Renders the current editor state and returns updated state.

  The returned state contains per-window render caches that enable
  dirty-line tracking on subsequent frames. Callers must use the
  returned state for the optimization to work.

  For the dashboard home screen, returns state with dashboard state
  initialized (if needed). No windows to cache.
  """
  @spec render(state()) :: state()
  def render(%{buffers: %{active: nil}} = state) do
    rows = state.viewport.rows
    cols = state.viewport.cols

    # Dashboard state is initialized by the editor when buffers empty,
    # but fall back to an empty state if somehow nil.
    dash_state = state.dashboard || Dashboard.new_state()

    splash_draws = Dashboard.render(cols, rows, state.theme, dash_state)

    frame = %Frame{
      cursor: Cursor.new(0, 0, :block),
      splash: splash_draws
    }

    commands = DisplayList.to_commands(frame)
    PortManager.send_commands(state.port_manager, commands)
    state
  end

  def render(state) do
    RenderPipeline.run(state)
  end
end
