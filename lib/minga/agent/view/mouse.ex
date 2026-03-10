defmodule Minga.Agent.View.Mouse do
  @moduledoc """
  Mouse event handling for the full-screen agentic view.

  Hit-tests against the agentic view layout regions (chat panel, file viewer,
  input area, separator) and dispatches to the appropriate handler.

  Returns `{:handled, state}` for events within agent-owned regions, or
  `{:passthrough, state}` for shared chrome (tab bar, modeline) so the
  editor's mouse handler can process those uniformly.

  ## Regions

      ┌──────── tab bar (row 0) ────────────┐  ← shared chrome (:passthrough)
      ├──────── title bar (row 1) ──────────┤  ← agent-owned
      │ chat panel  │sep│ file viewer       │  ← agent-owned
      │             │   │                   │
      │ input area  │   │ (continues)       │
      ├──────── modeline ──────────────────-┤  ← shared chrome (:passthrough)
      └──────── minibuffer ────────────────-┘  ← shared chrome (:passthrough)
  """

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Mouse, as: MouseState

  @scroll_lines 3
  # Must match @max_input_lines in Renderer to keep hit-testing aligned.
  @max_input_lines 8

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @type result :: {:handled, state()} | {:passthrough, state()}

  @doc """
  Dispatches a mouse event within the agentic view.

  Returns `{:handled, state}` for agent-owned regions (chat, input,
  file viewer, separator, title bar). Returns `{:passthrough, state}`
  for shared chrome (tab bar, modeline) so those events flow through
  to the editor mouse handler.
  """
  @spec handle(state(), integer(), integer(), atom(), non_neg_integer(), atom(), pos_integer()) ::
          result()

  # Ignore negative coordinates
  def handle(state, row, _col, _button, _mods, _type, _cc) when row < 0,
    do: {:passthrough, state}

  def handle(state, _row, col, _button, _mods, _type, _cc) when col < 0,
    do: {:passthrough, state}

  # ── Separator drag (in progress) ──

  def handle(
        %{mouse: %MouseState{resize_dragging: {:agent_separator, _}}} = state,
        _r,
        col,
        :left,
        _m,
        :drag,
        _cc
      ) do
    {:handled, handle_separator_drag(state, col)}
  end

  def handle(
        %{mouse: %MouseState{resize_dragging: {:agent_separator, _}}} = state,
        _r,
        _c,
        :left,
        _m,
        :release,
        _cc
      ) do
    {:handled, %{state | mouse: MouseState.stop_resize(state.mouse)}}
  end

  # ── Scroll wheel ──

  def handle(state, row, col, :wheel_down, _mods, :press, _cc) do
    dispatch_by_region(state, row, col, fn s, region ->
      handle_scroll(s, region, @scroll_lines)
    end)
  end

  def handle(state, row, col, :wheel_up, _mods, :press, _cc) do
    dispatch_by_region(state, row, col, fn s, region ->
      handle_scroll(s, region, -@scroll_lines)
    end)
  end

  # ── Left click ──

  def handle(state, row, col, :left, _mods, :press, _cc) do
    dispatch_by_region(state, row, col, fn s, region ->
      handle_click(s, region, row, col)
    end)
  end

  # ── All other events ──

  def handle(state, _row, _col, _button, _mods, _type, _cc), do: {:passthrough, state}

  # ── Region dispatch ────────────────────────────────────────────────────────

  # Shared chrome regions pass through to the editor mouse handler.
  # Agent-owned regions are handled here.
  @typep agent_region :: :title_bar | :chat | :file_viewer | :input | :separator
  @typep chrome_region :: :tab_bar | :modeline
  @typep region :: agent_region() | chrome_region() | :outside

  @spec dispatch_by_region(state(), integer(), integer(), (state(), agent_region() -> state())) ::
          result()
  defp dispatch_by_region(state, row, col, handler_fn) do
    case hit_test(state, row, col) do
      region when region in [:tab_bar, :modeline, :outside] ->
        {:passthrough, state}

      region ->
        {:handled, handler_fn.(state, region)}
    end
  end

  # ── Hit testing ────────────────────────────────────────────────────────────

  @typep layout_info :: %{
           sep_col: non_neg_integer(),
           chat_width: pos_integer(),
           input_row: non_neg_integer(),
           modeline_row: non_neg_integer(),
           panel_start: non_neg_integer()
         }

  @spec hit_test(state(), integer(), integer()) :: region()
  defp hit_test(state, row, col) do
    layout = compute_layout(state)
    classify_region(layout, row, col)
  end

  @spec classify_region(layout_info(), integer(), integer()) :: region()
  defp classify_region(layout, row, _col) when row == layout.panel_start - 2, do: :tab_bar
  defp classify_region(layout, row, _col) when row == layout.panel_start - 1, do: :title_bar
  defp classify_region(layout, row, _col) when row >= layout.modeline_row, do: :modeline

  defp classify_region(layout, row, col) when row >= layout.input_row and col < layout.chat_width,
    do: :input

  defp classify_region(layout, _row, col) when col == layout.sep_col, do: :separator
  defp classify_region(layout, _row, col) when col < layout.chat_width, do: :chat
  defp classify_region(layout, _row, col) when col > layout.sep_col, do: :file_viewer
  defp classify_region(_layout, _row, _col), do: :outside

  @spec compute_layout(state()) :: layout_info()
  defp compute_layout(state) do
    cols = state.viewport.cols
    rows = state.viewport.rows

    input_lines = state.agent.panel.input_lines
    input_height = max(min(length(input_lines), @max_input_lines), 1) + 2

    # Tab bar at row 0, title bar at row 1, content starts at row 2.
    panel_start = 2
    modeline_row = rows - 1 - 1

    # Two-column split extends from panel_start to modeline_row.
    panel_height = max(modeline_row - panel_start, 1)

    # Left column: chat on top, input at bottom.
    chat_height = max(panel_height - input_height, 1)
    input_row = panel_start + chat_height

    chat_width_pct = state.agentic.chat_width_pct
    chat_width = max(div(cols * chat_width_pct, 100), 20)
    sep_col = chat_width

    %{
      sep_col: sep_col,
      chat_width: chat_width,
      input_row: input_row,
      modeline_row: modeline_row,
      panel_start: panel_start
    }
  end

  # ── Scroll handling ────────────────────────────────────────────────────────

  @spec handle_scroll(state(), agent_region(), integer()) :: state()
  defp handle_scroll(state, :chat, delta) when delta > 0 do
    update_agent(state, &AgentState.scroll_down(&1, abs(delta)))
  end

  defp handle_scroll(state, :chat, delta) when delta < 0 do
    update_agent(state, &AgentState.scroll_up(&1, abs(delta)))
  end

  defp handle_scroll(state, :file_viewer, delta) when delta > 0 do
    update_agentic(state, &ViewState.scroll_viewer_down(&1, abs(delta)))
  end

  defp handle_scroll(state, :file_viewer, delta) when delta < 0 do
    update_agentic(state, &ViewState.scroll_viewer_up(&1, abs(delta)))
  end

  defp handle_scroll(state, _region, _delta), do: state

  # ── Click handling ─────────────────────────────────────────────────────────

  @spec handle_click(state(), agent_region(), integer(), integer()) :: state()

  defp handle_click(state, :chat, _row, _col) do
    update_agentic(state, fn av -> %{av | focus: :chat} end)
    |> update_agent(&AgentState.focus_input(&1, false))
  end

  defp handle_click(state, :file_viewer, _row, _col) do
    update_agentic(state, fn av -> %{av | focus: :file_viewer} end)
    |> update_agent(&AgentState.focus_input(&1, false))
  end

  defp handle_click(state, :input, _row, _col) do
    update_agent(state, &AgentState.focus_input(&1, true))
  end

  defp handle_click(state, :separator, _row, col) do
    %{state | mouse: MouseState.start_resize(state.mouse, :agent_separator, col)}
  end

  defp handle_click(state, _region, _row, _col), do: state

  # ── Separator drag ─────────────────────────────────────────────────────────

  @spec handle_separator_drag(state(), integer()) :: state()
  defp handle_separator_drag(state, col) do
    cols = state.viewport.cols
    new_pct = div(col * 100, max(cols, 1))
    clamped = new_pct |> max(30) |> min(80)

    state
    |> update_agentic(fn av -> %{av | chat_width_pct: clamped} end)
    |> then(fn s ->
      %{s | mouse: MouseState.update_resize(s.mouse, :agent_separator, col)}
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec update_agent(state(), (AgentState.t() -> AgentState.t())) :: state()
  defp update_agent(state, fun) do
    %{state | agent: fun.(state.agent)}
  end

  @spec update_agentic(state(), (ViewState.t() -> ViewState.t())) :: state()
  defp update_agentic(state, fun) do
    %{state | agentic: fun.(state.agentic)}
  end
end
