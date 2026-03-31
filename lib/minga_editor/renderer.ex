defmodule MingaEditor.Renderer do
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

  alias MingaEditor.Dashboard
  alias MingaEditor.DisplayList
  alias MingaEditor.DisplayList.{Cursor, Frame, Overlay}
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderPipeline
  alias MingaEditor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @type visual_selection :: MingaEditor.Renderer.Context.visual_selection()

  @doc """
  Renders the current editor state and returns updated state.

  The returned state contains per-window render caches that enable
  dirty-line tracking on subsequent frames. Callers must use the
  returned state for the optimization to work.

  For the dashboard home screen, returns state with dashboard state
  initialized (if needed). No windows to cache.
  """
  @spec render(state()) :: state()
  def render(%{shell: shell} = state) do
    shell.render(state)
  end

  @doc """
  Renders the dashboard home screen (no active buffer).

  Called by Shell.Traditional.render when no file buffers are open.
  """
  @spec render_dashboard(state()) :: state()
  def render_dashboard(%{workspace: %{buffers: %{active: nil}}} = state) do
    rows = state.workspace.viewport.rows
    cols = state.workspace.viewport.cols
    viewport = state.workspace.viewport

    # Dashboard state is initialized by the editor when buffers empty,
    # but fall back to an empty state if somehow nil.
    dash_state = state.shell_state.dashboard || Dashboard.new_state()

    splash_draws = Dashboard.render(cols, rows, state.theme, dash_state)

    # Render picker overlay on top of the dashboard if one is open
    # (e.g. :find_file or :project_switch from a dashboard quick action).
    {picker_draws, picker_cursor} = PickerUI.render(state, viewport)

    overlays =
      if picker_draws == [] do
        []
      else
        [%Overlay{draws: picker_draws, cursor: picker_cursor}]
      end

    # Use the picker cursor when a picker is open, otherwise park
    # the cursor at 0,0 (invisible behind the dashboard).
    cursor =
      case picker_cursor do
        {row, col} -> Cursor.new(row, col, :beam)
        nil -> Cursor.new(0, 0, :block)
      end

    frame = %Frame{
      cursor: cursor,
      splash: splash_draws,
      overlays: overlays
    }

    commands = DisplayList.to_commands(frame)
    MingaEditor.Frontend.send_commands(state.port_manager, commands)
    state
  end

  @doc """
  Runs the full render pipeline (content, chrome, compose, emit).

  Called by Shell.Traditional.render for normal buffer rendering.
  """
  @spec render_buffer(state()) :: state()
  def render_buffer(state) do
    RenderPipeline.run(state)
  rescue
    e ->
      msg = Exception.message(e)
      trace = Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 500)
      Minga.Log.warning(:render, "Render pipeline crashed: #{msg}\n#{trace}")
      MingaEditor.log_to_messages("[render] frame dropped: #{msg}")
      state
  end
end
