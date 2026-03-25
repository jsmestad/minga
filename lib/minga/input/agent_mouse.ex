defmodule Minga.Input.AgentMouse do
  @moduledoc """
  Position-based mouse handler for agent-specific UI regions.

  Only intercepts mouse events that require agent-specific handling:

  * **Prompt area clicks** (split pane and side panel): focus/unfocus the
    input field and transition to insert mode.
  * **Preview pane scroll** (split pane): scroll the file viewer preview
    when the mouse is in the preview column.
  * **Side panel interactions**: scroll and click handling for the bottom
    panel, which uses UIState.scroll (not the standard viewport).

  Chat content scroll and clicks in the split pane pass through to
  `Editor.Mouse` (via `ModeFSM`) after unpinning the window so the
  viewport follows the cursor. Chat content clicks unfocus the prompt
  input and passthrough for standard buffer mouse handling.

  Events outside agent regions pass through to the next handler in the
  surface stack.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Agent.UIState
  alias Minga.Agent.View.PromptRenderer
  alias Minga.Config.Options
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.Window.Content
  alias Minga.Editor.WindowTree

  # Mouse event fields grouped for dispatch without exceeding max arity.
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
        dispatch_window(state, layout, win_id, row, col, evt)

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
  defp find_agent_chat_window_at(%{workspace: %{windows: %{tree: nil}}}, _layout, _row, _col),
    do: :not_found

  defp find_agent_chat_window_at(state, layout, row, col) do
    case WindowTree.window_at(state.workspace.windows.tree, layout.editor_area, row, col) do
      {:ok, win_id, _rect} ->
        window = Map.get(state.workspace.windows.map, win_id)

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
          {:handled | :passthrough, EditorState.t()}

  # Scroll: check column to differentiate chat vs preview pane.
  # Chat scroll unpins and passes through to Editor.Mouse.
  # Preview scroll is handled here (unique, no standard handler).
  defp dispatch_window(state, layout, win_id, _row, col, %{
         button: button,
         event_type: :press
       })
       when button in [:wheel_down, :wheel_up] do
    {_cr, cc, cw, _ch} = window_content_rect(layout, win_id)
    view = AgentAccess.view(state)
    chat_width = max(div(cw * view.chat_width_pct, 100), 20)

    if col < cc + chat_width do
      # Chat area scroll: unpin and passthrough to Editor.Mouse
      state = unpin_agent_chat_window(state)
      {:passthrough, state}
    else
      # Preview area scroll: handled here (unique)
      delta = if button == :wheel_down, do: scroll_lines(), else: -scroll_lines()
      {:handled, scroll_preview(state, delta)}
    end
  end

  # Left click: focus window, then check prompt vs chat area.
  defp dispatch_window(state, layout, win_id, row, col, %{button: :left, event_type: :press}) do
    state = maybe_focus_window(state, win_id)
    content_rect = window_content_rect(layout, win_id)

    if click_in_prompt?(content_rect, row, state) do
      {:handled, handle_prompt_click(state, content_rect, row, col)}
    else
      # Chat content click: unfocus prompt, passthrough to ModeFSM
      state = unfocus_input(state)
      {:passthrough, state}
    end
  end

  # Drag and release: passthrough to ModeFSM for visual mode selection
  defp dispatch_window(state, _layout, _win_id, _row, _col, %{button: :left}) do
    {:passthrough, state}
  end

  defp dispatch_window(state, _layout, _win_id, _row, _col, _evt), do: {:handled, state}

  # ── Agent side panel (bottom panel) dispatch ───────────────────────────────

  @spec dispatch_panel(EditorState.t(), Layout.rect(), integer(), integer(), mouse_event()) ::
          EditorState.t()

  defp dispatch_panel(state, _rect, _row, _col, %{button: :wheel_down, event_type: :press}) do
    scroll_panel_chat(state, scroll_lines())
  end

  defp dispatch_panel(state, _rect, _row, _col, %{button: :wheel_up, event_type: :press}) do
    scroll_panel_chat(state, -scroll_lines())
  end

  defp dispatch_panel(state, rect, row, col, %{button: :left, event_type: :press}) do
    handle_prompt_click(state, rect, row, col)
  end

  defp dispatch_panel(state, _rect, _row, _col, _evt), do: state

  # ── Prompt click logic ─────────────────────────────────────────────────────

  @spec handle_prompt_click(EditorState.t(), Layout.rect(), integer(), integer()) ::
          EditorState.t()
  defp handle_prompt_click(state, {cr, _cc, cw, ch}, row, _col) do
    panel = AgentAccess.panel(state)
    input_lines = UIState.input_lines(panel)
    box_width = PromptRenderer.input_box_width(cw)
    inner_width = PromptRenderer.input_inner_width(box_width)
    input_height = PromptRenderer.compute_input_height(input_lines, inner_width)

    input_start_row = cr + ch - input_height - PromptRenderer.input_v_gap()

    if row >= input_start_row do
      state = AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, true))
      EditorState.transition_mode(state, :insert)
    else
      AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, false))
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec unfocus_input(EditorState.t()) :: EditorState.t()
  defp unfocus_input(state) do
    AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, false))
  end

  @spec click_in_prompt?(Layout.rect(), non_neg_integer(), EditorState.t()) :: boolean()
  defp click_in_prompt?({row_off, _col, width, height}, click_row, state) do
    prompt_h = PromptRenderer.prompt_height(state, width)
    chat_h = max(height - prompt_h - 1, 1)
    click_row >= row_off + chat_h
  end

  @spec maybe_focus_window(EditorState.t(), pos_integer()) :: EditorState.t()
  defp maybe_focus_window(state, win_id) do
    if state.workspace.windows.active != win_id do
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

  @spec unpin_agent_chat_window(EditorState.t()) :: EditorState.t()
  defp unpin_agent_chat_window(state) do
    case EditorState.find_agent_chat_window(state) do
      nil ->
        state

      {win_id, _window} ->
        EditorState.update_window(state, win_id, fn w -> %{w | pinned: false} end)
    end
  end

  # Side panel chat scroll: updates UIState.scroll (used by the panel
  # renderer) and the window viewport for pinned state tracking.
  @spec scroll_panel_chat(EditorState.t(), pos_integer() | neg_integer()) :: EditorState.t()
  defp scroll_panel_chat(state, delta) do
    state =
      if delta > 0 do
        AgentAccess.update_agent_ui(state, &UIState.scroll_down(&1, delta))
      else
        AgentAccess.update_agent_ui(state, &UIState.scroll_up(&1, abs(delta)))
      end

    EditorState.scroll_agent_chat_window(state, delta)
  end

  @spec scroll_preview(EditorState.t(), pos_integer() | neg_integer()) :: EditorState.t()
  defp scroll_preview(state, delta) when delta > 0 do
    AgentAccess.update_agent_ui(state, &UIState.scroll_viewer_down(&1, delta))
  end

  defp scroll_preview(state, delta) when delta < 0 do
    AgentAccess.update_agent_ui(state, &UIState.scroll_viewer_up(&1, abs(delta)))
  end

  @spec scroll_lines() :: pos_integer()
  defp scroll_lines do
    Options.get(:scroll_lines)
  end
end
