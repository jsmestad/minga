defmodule MingaEditor.Input.Completion do
  @moduledoc """
  Input handler for the completion popup in insert mode.

  When a completion popup is visible and the editor is in insert mode,
  intercepts navigation keys (C-n, C-p, arrows), accept keys (Tab, Enter),
  and Escape. Mouse clicks on candidates select and confirm them; scroll
  wheel scrolls the candidate list. Other keys pass through to the mode
  FSM for normal insert handling.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  import Bitwise

  alias Minga.Buffer
  alias Minga.Editing.Completion
  alias MingaEditor.CompletionHandling
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  @ctrl MingaEditor.Input.mod_ctrl()
  @escape 27
  @tab 9
  @enter 13
  @arrow_up 0x415B1B
  @arrow_down 0x425B1B

  @max_rows 10

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(
        %{workspace: %{editing: %{mode: :insert}, completion: %Completion{} = completion}} = state,
        cp,
        mods
      ) do
    case do_handle(state, completion, cp, mods) do
      {:handled, new_state} -> {:handled, new_state}
      :passthrough -> {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @impl true
  @spec handle_mouse(
          state(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: MingaEditor.Input.Handler.result()

  # Completion popup active: intercept scroll and clicks
  def handle_mouse(
        %{workspace: %{editing: %{mode: :insert}, completion: %Completion{} = completion}} = state,
        row,
        col,
        button,
        _mods,
        :press,
        _cc
      ) do
    case button do
      :wheel_down ->
        {:handled,
         EditorState.update_workspace(
           state,
           &WorkspaceState.set_completion(&1, Completion.move_down(completion))
         )}

      :wheel_up ->
        {:handled,
         EditorState.update_workspace(
           state,
           &WorkspaceState.set_completion(&1, Completion.move_up(completion))
         )}

      :left ->
        handle_completion_click(state, completion, row, col)

      _ ->
        {:passthrough, state}
    end
  end

  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _cc) do
    {:passthrough, state}
  end

  # ── Completion click ─────────────────────────────────────────────────────

  @spec handle_completion_click(EditorState.t(), Completion.t(), integer(), integer()) ::
          MingaEditor.Input.Handler.result()
  defp handle_completion_click(state, completion, row, col) do
    {visible, _selected_offset} = Completion.visible_items(completion)
    item_count = min(length(visible), @max_rows)

    # Popup position: same logic as CompletionUI
    {cursor_row, cursor_col} = cursor_screen_pos(state)
    space_below = state.workspace.viewport.rows - cursor_row - 2

    popup_start_row =
      if space_below >= item_count do
        cursor_row + 1
      else
        cursor_row - item_count
      end

    # Check popup width for column hit-test
    label_widths =
      Enum.map(Enum.take(visible, item_count), fn item -> String.length(item.label) + 4 end)

    popup_width = label_widths |> Enum.max(fn -> 20 end) |> max(20) |> min(50)
    popup_width = min(popup_width, state.workspace.viewport.cols - cursor_col)
    start_col = min(cursor_col, max(0, state.workspace.viewport.cols - popup_width))

    clicked_idx = row - popup_start_row

    if clicked_idx >= 0 and clicked_idx < item_count and
         col >= start_col and col < start_col + popup_width do
      # Navigate to the clicked item and accept it
      target_item = Enum.at(visible, clicked_idx)

      if target_item do
        # Set selection to the clicked index, then accept
        adjusted = set_completion_selected(completion, clicked_idx)
        new_state = MingaEditor.do_accept_completion(state, adjusted)
        {:handled, new_state}
      else
        {:handled, state}
      end
    else
      # Click outside popup: dismiss completion
      {:handled, MingaEditor.do_dismiss_completion(state)}
    end
  end

  @spec cursor_screen_pos(EditorState.t()) :: {non_neg_integer(), non_neg_integer()}
  defp cursor_screen_pos(state) do
    buf = state.workspace.buffers.active

    if buf do
      {line, col} = Buffer.cursor(buf)
      screen_row = line - state.workspace.viewport.top
      total_lines = Buffer.line_count(buf)

      number_w =
        if state.line_numbers == :none,
          do: 0,
          else: Viewport.gutter_width(total_lines)

      gutter_w = MingaEditor.Renderer.Gutter.total_width(number_w)
      screen_col = col + gutter_w - state.workspace.viewport.left

      {max(screen_row, 0), max(screen_col, 0)}
    else
      {0, 0}
    end
  end

  @spec set_completion_selected(Completion.t(), non_neg_integer()) :: Completion.t()
  defp set_completion_selected(%Completion{} = completion, idx) do
    # The visible items are a window into filtered. We need to compute
    # the absolute index in filtered from the visible window offset.
    {_visible, _selected_offset} = Completion.visible_items(completion)
    total = length(completion.filtered)
    scroll_start = max(0, completion.selected - div(completion.max_visible, 2))
    scroll_start = min(scroll_start, max(0, total - completion.max_visible))
    absolute_idx = min(scroll_start + idx, total - 1)
    %{completion | selected: absolute_idx}
  end

  # ── Key handling ─────────────────────────────────────────────────────────

  @spec do_handle(EditorState.t(), Completion.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | :passthrough

  # Escape: dismiss completion and stay in insert mode
  defp do_handle(state, _completion, @escape, _mods) do
    {:handled, MingaEditor.do_dismiss_completion(state)}
  end

  # C-n or arrow down: move selection down
  defp do_handle(state, completion, cp, mods)
       when (cp == ?n and band(mods, @ctrl) != 0) or cp == @arrow_down do
    state =
      EditorState.update_workspace(
        state,
        &WorkspaceState.set_completion(&1, Completion.move_down(completion))
      )

    {:handled, CompletionHandling.maybe_resolve_selected(state)}
  end

  # C-p or arrow up: move selection up
  defp do_handle(state, completion, cp, mods)
       when (cp == ?p and band(mods, @ctrl) != 0) or cp == @arrow_up do
    state =
      EditorState.update_workspace(
        state,
        &WorkspaceState.set_completion(&1, Completion.move_up(completion))
      )

    {:handled, CompletionHandling.maybe_resolve_selected(state)}
  end

  # Tab or Enter: accept the selected completion
  defp do_handle(state, completion, cp, _mods) when cp in [@tab, @enter] do
    new_state = MingaEditor.do_accept_completion(state, completion)
    {:handled, new_state}
  end

  # All other keys: pass through
  defp do_handle(_state, _completion, _cp, _mods), do: :passthrough
end
