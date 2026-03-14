defmodule Minga.Input.AgentMouse do
  @moduledoc """
  Position-based mouse handler for agent chat regions.

  Intercepts mouse events (scroll, click) when the mouse position falls
  inside an agent chat region, regardless of `keymap_scope`. Mouse routing
  is position-based (where is the cursor on screen?) not scope-based (which
  pane has keyboard focus?). This is the fundamental difference between
  mouse and keyboard dispatch.

  Handles two kinds of agent regions:

  * **Agent chat window** (split pane): a window in the `WindowTree` with
    `{:agent_chat, _}` content. Hit-tested via `WindowTree.window_at/4`.

  * **Agent side panel** (bottom panel): the `Layout.agent_panel` rect
    rendered by `ChromeHelpers.render_agent_panel_from_layout`.

  Within each region, the handler subdivides into chat area vs input area
  using the same layout math as `Agent.View.Renderer` (shared public
  helpers `compute_input_height/2` and `input_inner_width/1`).

  Events outside agent regions pass through to the next handler in the
  surface stack (ultimately `ModeFSM` for buffer-level mouse handling).
  """

  @behaviour Minga.Input.Handler

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Renderer, as: ViewRenderer
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.Window.Content
  alias Minga.Editor.WindowTree
  alias Minga.Mode

  # Scroll 3 lines per wheel tick (matches Editor.Mouse TUI behavior).
  @scroll_lines 3

  # Mouse event fields grouped for dispatch without exceeding max arity.
  # Modifiers and click_count are threaded through for future use
  # (Shift+click selection, double-click word select, etc.) per AGENTS.md
  # requirement to always pass modifiers through.
  @typep mouse_event :: %{
           button: atom(),
           mods: non_neg_integer(),
           event_type: atom(),
           click_count: pos_integer()
         }

  # ── Handler callbacks ──────────────────────────────────────────────────────

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  @impl true
  @spec handle_mouse(
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  def handle_mouse(state, row, col, button, mods, event_type, click_count) do
    layout = Layout.get(state)
    evt = %{button: button, mods: mods, event_type: event_type, click_count: click_count}

    case identify_agent_region(state, layout, row, col) do
      {:agent_chat_window, win_id} ->
        {:handled, dispatch_window(state, layout, win_id, row, col, evt)}

      {:agent_panel, panel_rect} ->
        {:handled, dispatch_panel(state, panel_rect, row, col, evt)}

      :not_agent ->
        {:passthrough, state}
    end
  end

  # ── Region identification ──────────────────────────────────────────────────

  @spec identify_agent_region(EditorState.t(), Layout.t(), integer(), integer()) ::
          {:agent_chat_window, pos_integer()}
          | {:agent_panel, Layout.rect()}
          | :not_agent

  defp identify_agent_region(state, layout, row, col) do
    case find_agent_chat_window_at(state, layout, row, col) do
      {:ok, win_id} ->
        {:agent_chat_window, win_id}

      :not_found ->
        case layout.agent_panel do
          {pr, pc, pw, ph} when row >= pr and row < pr + ph and col >= pc and col < pc + pw ->
            {:agent_panel, {pr, pc, pw, ph}}

          _ ->
            :not_agent
        end
    end
  end

  @spec find_agent_chat_window_at(EditorState.t(), Layout.t(), integer(), integer()) ::
          {:ok, pos_integer()} | :not_found
  defp find_agent_chat_window_at(%{windows: %{tree: nil}}, _layout, _row, _col), do: :not_found

  defp find_agent_chat_window_at(state, layout, row, col) do
    case WindowTree.window_at(state.windows.tree, layout.editor_area, row, col) do
      {:ok, win_id, _rect} ->
        window = Map.get(state.windows.map, win_id)

        if window != nil and Content.agent_chat?(window.content) do
          {:ok, win_id}
        else
          :not_found
        end

      :error ->
        :not_found
    end
  end

  # ── Agent chat window (split pane) dispatch ────────────────────────────────

  @spec dispatch_window(
          EditorState.t(),
          Layout.t(),
          pos_integer(),
          integer(),
          integer(),
          mouse_event()
        ) ::
          EditorState.t()

  defp dispatch_window(state, layout, win_id, _row, col, %{
         button: :wheel_down,
         event_type: :press
       }) do
    scroll_in_window(state, layout, win_id, col, @scroll_lines)
  end

  defp dispatch_window(state, layout, win_id, _row, col, %{button: :wheel_up, event_type: :press}) do
    scroll_in_window(state, layout, win_id, col, -@scroll_lines)
  end

  defp dispatch_window(state, layout, win_id, row, col, %{button: :left, event_type: :press}) do
    state = maybe_focus_window(state, win_id)
    content_rect = window_content_rect(layout, win_id)
    handle_agent_click(state, content_rect, row, col)
  end

  defp dispatch_window(state, _layout, _win_id, _row, _col, _evt), do: state

  @spec maybe_focus_window(EditorState.t(), pos_integer()) :: EditorState.t()
  defp maybe_focus_window(state, win_id) do
    if state.windows.active != win_id do
      EditorState.focus_window(state, win_id)
    else
      state
    end
  end

  @spec window_content_rect(Layout.t(), pos_integer()) :: Layout.rect()
  defp window_content_rect(layout, win_id) do
    %{content: rect} = Map.fetch!(layout.window_layouts, win_id)
    rect
  end

  @spec scroll_in_window(EditorState.t(), Layout.t(), pos_integer(), integer(), integer()) ::
          EditorState.t()
  defp scroll_in_window(state, layout, win_id, col, delta) do
    {_cr, cc, cw, _ch} = window_content_rect(layout, win_id)
    agentic = AgentAccess.agentic(state)
    chat_width = max(div(cw * agentic.chat_width_pct, 100), 20)
    chat_right_edge = cc + chat_width

    if col < chat_right_edge do
      scroll_chat(state, delta)
    else
      scroll_preview(state, delta)
    end
  end

  # ── Agent side panel (bottom panel) dispatch ───────────────────────────────

  @spec dispatch_panel(EditorState.t(), Layout.rect(), integer(), integer(), mouse_event()) ::
          EditorState.t()

  defp dispatch_panel(state, _rect, _row, _col, %{button: :wheel_down, event_type: :press}) do
    scroll_chat(state, @scroll_lines)
  end

  defp dispatch_panel(state, _rect, _row, _col, %{button: :wheel_up, event_type: :press}) do
    scroll_chat(state, -@scroll_lines)
  end

  defp dispatch_panel(state, rect, row, col, %{button: :left, event_type: :press}) do
    handle_agent_click(state, rect, row, col)
  end

  defp dispatch_panel(state, _rect, _row, _col, _evt), do: state

  # ── Shared click logic ─────────────────────────────────────────────────────

  @spec handle_agent_click(EditorState.t(), Layout.rect(), integer(), integer()) ::
          EditorState.t()
  defp handle_agent_click(state, {cr, _cc, cw, ch}, row, _col) do
    panel = AgentAccess.panel(state)
    input_lines = PanelState.input_lines(panel)
    inner_width = ViewRenderer.input_inner_width(cw)
    input_height = ViewRenderer.compute_input_height(input_lines, inner_width)

    # Input area occupies the bottom `input_height` rows of the content rect
    input_start_row = cr + ch - input_height

    if row >= input_start_row do
      state = AgentAccess.update_agent(state, &AgentState.focus_input(&1, true))
      put_in(state.vim, %{state.vim | mode: :insert, mode_state: Mode.initial_state()})
    else
      AgentAccess.update_agent(state, &AgentState.focus_input(&1, false))
    end
  end

  # ── Shared scroll helpers ──────────────────────────────────────────────────

  @spec scroll_chat(EditorState.t(), pos_integer() | neg_integer()) :: EditorState.t()
  defp scroll_chat(state, delta) when delta > 0 do
    AgentAccess.update_agent(state, &AgentState.scroll_down(&1, delta))
  end

  defp scroll_chat(state, delta) when delta < 0 do
    AgentAccess.update_agent(state, &AgentState.scroll_up(&1, abs(delta)))
  end

  @spec scroll_preview(EditorState.t(), pos_integer() | neg_integer()) :: EditorState.t()
  defp scroll_preview(state, delta) when delta > 0 do
    AgentAccess.update_agentic(state, &ViewState.scroll_viewer_down(&1, delta))
  end

  defp scroll_preview(state, delta) when delta < 0 do
    AgentAccess.update_agentic(state, &ViewState.scroll_viewer_up(&1, abs(delta)))
  end
end
