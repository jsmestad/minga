defmodule Minga.Agent.View.Mouse do
  @moduledoc """
  Mouse event handling for the full-screen agentic view.

  Hit-tests against the agentic view layout regions (chat panel, file viewer,
  input area, separator) and dispatches to the appropriate handler. All
  functions are pure `state -> state` transformations.

  ## Regions

  The agentic view layout is:

      ┌──────── tab bar (row 0) ────────────┐
      ├──────── title bar (row 1) ──────────┤
      │ chat panel  │sep│ file viewer       │
      │             │   │                   │
      │ input area  │   │ (continues)       │
      ├──────── modeline ──────────────────-┤
      └──────── minibuffer ────────────────-┘

  The two-column split extends the full height. The input area lives
  inside the left column. Mouse events are routed based on which
  region they land in.
  """

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Mouse, as: MouseState

  @scroll_lines 3

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Dispatches a mouse event within the agentic view."
  @spec handle(state(), integer(), integer(), atom(), non_neg_integer(), atom(), pos_integer()) ::
          state()

  # Ignore negative coordinates
  def handle(state, row, _col, _button, _mods, _type, _cc) when row < 0, do: state
  def handle(state, _row, col, _button, _mods, _type, _cc) when col < 0, do: state

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
    handle_separator_drag(state, col)
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
    %{state | mouse: MouseState.stop_resize(state.mouse)}
  end

  # ── Scroll wheel ──

  def handle(state, row, col, :wheel_down, _mods, :press, _cc) do
    region = hit_test(state, row, col)
    handle_scroll(state, region, @scroll_lines)
  end

  def handle(state, row, col, :wheel_up, _mods, :press, _cc) do
    region = hit_test(state, row, col)
    handle_scroll(state, region, -@scroll_lines)
  end

  # ── Left click ──

  def handle(state, row, col, :left, _mods, :press, _cc) do
    region = hit_test(state, row, col)
    handle_click(state, region, row, col)
  end

  # ── Ignore all other events ──

  def handle(state, _row, _col, _button, _mods, _type, _cc), do: state

  # ── Hit testing ────────────────────────────────────────────────────────────

  @typep region :: :title | :chat | :file_viewer | :input | :separator | :modeline | :outside

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

    cond do
      row < layout.panel_start -> :title
      row >= layout.modeline_row -> :modeline
      row >= layout.input_row and col < layout.chat_width -> :input
      col == layout.sep_col -> :separator
      col < layout.chat_width -> :chat
      col > layout.sep_col -> :file_viewer
      true -> :outside
    end
  end

  @spec compute_layout(state()) :: layout_info()
  defp compute_layout(state) do
    cols = state.viewport.cols
    rows = state.viewport.rows

    input_lines = state.agent.panel.input_lines
    input_height = min(length(input_lines), 5) + 2

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

  @spec handle_scroll(state(), region(), integer()) :: state()
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

  @spec handle_click(state(), region(), integer(), integer()) :: state()

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
    # Convert column to percentage
    new_pct = div(col * 100, max(cols, 1))
    # Clamp to 30-80% range (matching ViewState constraints)
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
