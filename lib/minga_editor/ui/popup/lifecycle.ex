defmodule MingaEditor.UI.Popup.Lifecycle do
  @moduledoc """
  Pure state transformations for opening and closing popup windows.

  Popup windows are managed splits (or floating overlays) governed by
  `Popup.Rule` structs. Closing a popup surgically removes its window
  from the current tree via `WindowTree.close/2`, so multiple popups
  can coexist without interfering with each other.

  All functions are `state -> state` transformations with no side effects.
  The Editor GenServer calls these and handles rendering afterward.

  ## Open flow

  1. Caller provides a buffer name and pid.
  2. `open_popup/3` checks `Popup.Registry` for a matching rule.
  3. If a rule matches and `display: :split`, a managed split is created
     via `WindowTree.split/4` and the new window gets `popup_meta` set.
  4. If no rule matches, returns state unchanged (caller should fall back
     to normal buffer opening).

  ## Close flow

  1. `close_popup/2` removes the popup window from the current tree via
     `WindowTree.close/2` (like `delete-window` in Emacs).
  2. Removes the popup window from the map and returns focus to the
     previously active window.

  This surgical approach lets multiple popups coexist: closing one only
  removes its own window without affecting other open popups.
  """

  alias MingaEditor.FloatingWindow
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.UI.Popup.Active, as: PopupActive
  alias Minga.Popup.Registry, as: PopupRegistry
  alias Minga.Popup.Rule

  @type state :: EditorState.t()

  @doc """
  Attempts to open a buffer as a popup.

  Checks the popup registry for a matching rule. If found, creates a
  managed split popup and returns `{:ok, new_state}`. If no rule matches,
  returns `:no_match` so the caller can fall back to normal buffer opening.

  The popup buffer is added to the buffer list (if not already there) and
  displayed in a new split pane. The original layout is snapshotted for
  restore on close.
  """
  @spec open_popup(state(), String.t(), pid(), keyword()) :: {:ok, state()} | :no_match
  def open_popup(state, buffer_name, buffer_pid, opts \\ [])
      when is_binary(buffer_name) and is_pid(buffer_pid) do
    registry = Keyword.get(opts, :registry, Minga.Popup.Registry)

    case PopupRegistry.match(buffer_name, registry) do
      {:ok, rule} ->
        {:ok, apply_rule(state, rule, buffer_pid)}

      :none ->
        :no_match
    end
  end

  @doc """
  Closes the popup window with the given id.

  Removes the popup's window from the current tree via `WindowTree.close/2`,
  removes it from the window map, and returns focus to the previously
  active window. The underlying buffer is kept alive (not killed).

  Returns state unchanged if the window id doesn't exist or isn't a popup.
  """
  @spec close_popup(state(), Window.id()) :: state()
  def close_popup(state, window_id) when is_integer(window_id) do
    case Windows.fetch(state.workspace.windows, window_id) do
      {:ok, %Window{popup_meta: %PopupActive{} = meta}} ->
        do_close(state, window_id, meta)

      _ ->
        state
    end
  end

  @doc """
  Closes the currently active window if it's a popup.

  Convenience for the common case of dismissing the focused popup.
  Returns state unchanged if the active window isn't a popup.
  """
  @spec close_active_popup(state()) :: state()
  def close_active_popup(state) do
    close_popup(state, state.workspace.windows.active)
  end

  @doc """
  Closes all open popup windows.

  Used on tab switch to clean up transient popups. Closes popups in
  reverse order of creation (LIFO) to avoid tree restore conflicts.
  """
  @spec close_all_popups(state()) :: state()
  def close_all_popups(state) do
    popup_ids =
      state.workspace.windows
      |> Windows.popup_windows()
      |> Enum.sort_by(fn {id, _w} -> id end, :desc)
      |> Enum.map(fn {id, _w} -> id end)

    Enum.reduce(popup_ids, state, fn id, acc -> close_popup(acc, id) end)
  end

  @doc """
  Returns true if the active window is a popup.
  """
  @spec active_is_popup?(state()) :: boolean()
  def active_is_popup?(state) do
    case Windows.active_struct(state.workspace.windows) do
      %Window{} = window -> Window.popup?(window)
      nil -> false
    end
  end

  @doc """
  Returns true when the click at `{row, col}` falls inside any float
  popup's bounding box. Used by the input layer to decide whether a
  click should be swallowed or should dismiss the popup.
  """
  @spec click_inside_float?(state(), integer(), integer()) :: boolean()
  def click_inside_float?(state, row, col) do
    state.workspace.windows
    |> Windows.popup_windows()
    |> Enum.any?(fn {_id, w} ->
      float_popup?(w) and inside_float_box?(state, w, row, col)
    end)
  end

  @spec float_popup?(Window.t()) :: boolean()
  defp float_popup?(%Window{popup_meta: %PopupActive{rule: %Rule{display: :float}}}), do: true
  defp float_popup?(_), do: false

  @spec inside_float_box?(state(), Window.t(), integer(), integer()) :: boolean()
  defp inside_float_box?(state, window, row, col) do
    rule = window.popup_meta.rule
    vp = state.frontend.terminal_viewport

    box_w = resolve_float_dim(float_width(rule), vp.cols)
    box_h = resolve_float_dim(float_height(rule), vp.rows)
    box_row = max(div(vp.rows - box_h, 2), 0)
    box_col = max(div(vp.cols - box_w, 2), 0)

    row >= box_row and row < box_row + box_h and
      col >= box_col and col < box_col + box_w
  end

  @spec resolve_float_dim(FloatingWindow.Spec.size(), pos_integer()) :: pos_integer()
  defp resolve_float_dim({:percent, pct}, total), do: max(div(total * pct, 100), 1)
  defp resolve_float_dim({:cols, n}, _total), do: n
  defp resolve_float_dim({:rows, n}, _total), do: n

  @spec float_width(Rule.t()) :: FloatingWindow.Spec.size()
  defp float_width(%Rule{width: nil, size: size}), do: size
  defp float_width(%Rule{width: w}), do: w

  @spec float_height(Rule.t()) :: FloatingWindow.Spec.size()
  defp float_height(%Rule{height: nil, size: size}), do: size
  defp float_height(%Rule{height: h}), do: h

  # ── Private ────────────────────────────────────────────────────────────────

  @spec apply_rule(state(), Rule.t(), pid()) :: state()
  defp apply_rule(%{workspace: %{windows: ws}} = state, %Rule{display: :split} = rule, buffer_pid) do
    previous_active = ws.active

    {next_id, ws} = Windows.allocate_id(ws)
    rows = state.frontend.terminal_viewport.rows
    cols = state.frontend.terminal_viewport.cols
    popup_window = Window.new(next_id, buffer_pid, rows, cols)

    # Determine split direction from the rule's side
    direction = split_direction(rule.side)

    # Determine which window to split and how to arrange the tree.
    # For bottom/right: the popup goes in the second (right/bottom) position.
    # For top/left: the popup goes in the first (left/top) position.
    active_id = ws.active
    tree = ws.tree || WindowTree.new(active_id)

    case WindowTree.split(tree, active_id, direction, next_id) do
      {:ok, new_tree} ->
        # For top/left popups, swap the children so the popup is first
        new_tree = maybe_swap_children(new_tree, next_id, rule.side)

        # Compute split size
        new_tree = apply_split_size(new_tree, next_id, rule, state)

        # Attach popup metadata to the new window
        active = PopupActive.new(rule, previous_active)
        popup_window = %{popup_window | popup_meta: active}

        # Update state
        windows =
          ws
          |> Windows.set_tree(new_tree)
          |> Windows.add_window(popup_window)

        state = update_popup_windows(state, windows, next_id, rule.focus)

        Layout.invalidate(state)

      :error ->
        state
    end
  end

  defp apply_rule(%{workspace: %{windows: ws}} = state, %Rule{display: :float} = rule, buffer_pid) do
    previous_active = ws.active

    # Create the popup window (not added to the tree, only the map)
    {next_id, ws} = Windows.allocate_id(ws)
    rows = state.frontend.terminal_viewport.rows
    cols = state.frontend.terminal_viewport.cols
    popup_window = Window.new(next_id, buffer_pid, rows, cols)

    # Attach popup metadata
    active = PopupActive.new(rule, previous_active)
    popup_window = %{popup_window | popup_meta: active}

    # Add window to map but NOT to the tree (floats overlay the layout)
    windows = Windows.add_window(ws, popup_window)
    state = update_popup_windows(state, windows, next_id, rule.focus)

    Layout.invalidate(state)
  end

  @spec update_popup_windows(state(), Windows.t(), Window.id(), boolean()) :: state()
  defp update_popup_windows(state, windows, next_id, true) do
    state = %{
      state
      | workspace: MingaEditor.Session.State.set_windows(state.workspace, windows)
    }

    MingaEditor.WindowFocus.focus(state, next_id)
  end

  defp update_popup_windows(state, windows, _next_id, false) do
    %{state | workspace: MingaEditor.Session.State.set_windows(state.workspace, windows)}
  end

  @spec do_close(state(), Window.id(), PopupActive.t()) :: state()
  defp do_close(state, window_id, %PopupActive{} = meta) do
    focused? = state.workspace.windows.active == window_id
    state = maybe_restore_popup_focus(state, window_id, meta, focused?)
    finish_popup_close(state, window_id, meta, focused?)
  end

  @spec maybe_restore_popup_focus(state(), Window.id(), PopupActive.t(), boolean()) :: state()
  defp maybe_restore_popup_focus(state, window_id, meta, true) do
    windows = state.workspace.windows
    candidates = restore_candidates(windows, window_id, meta.previous_active)

    case restore_first_focus(state, candidates) do
      {:ok, restored} -> restored
      :error -> repair_popup_focus(state, windows, window_id, meta.previous_active)
    end
  end

  defp maybe_restore_popup_focus(state, _window_id, _meta, false), do: state

  @spec restore_first_focus(state(), [Window.id()]) :: {:ok, state()} | :error
  defp restore_first_focus(state, candidates) do
    Enum.reduce_while(candidates, :error, fn candidate_id, :error ->
      case MingaEditor.WindowFocus.restore_focus(state, candidate_id) do
        {:ok, restored} -> {:halt, {:ok, restored}}
        :error -> {:cont, :error}
      end
    end)
  end

  @spec repair_popup_focus(state(), Windows.t(), Window.id(), Window.id()) :: state()
  defp repair_popup_focus(state, windows, window_id, previous_active) do
    case non_popup_window_ids(windows, window_id, previous_active) do
      [fallback_id | _] ->
        case MingaEditor.WindowFocus.repair_focus(state, fallback_id) do
          {:ok, repaired} -> repaired
          :error -> state
        end

      [] ->
        state
    end
  end

  @spec restore_candidates(Windows.t(), Window.id(), Window.id()) :: [Window.id()]
  defp restore_candidates(windows, window_id, previous_active) do
    [previous_active | non_popup_window_ids(windows, window_id, previous_active)]
    |> Enum.reject(&(&1 == window_id))
    |> Enum.uniq()
  end

  @spec non_popup_window_ids(Windows.t(), Window.id(), Window.id()) :: [Window.id()]
  defp non_popup_window_ids(%Windows{map: window_map}, window_id, previous_active) do
    ids =
      window_map
      |> Enum.filter(fn {id, window} -> id != window_id and not Window.popup?(window) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if previous_active in ids,
      do: [previous_active | List.delete(ids, previous_active)],
      else: ids
  end

  @spec finish_popup_close(state(), Window.id(), PopupActive.t(), boolean()) :: state()
  defp finish_popup_close(
         %{workspace: %{windows: %{active: active}}} = state,
         window_id,
         _meta,
         true
       )
       when active == window_id,
       do: state

  defp finish_popup_close(state, window_id, meta, _focused?) do
    # Remove just this popup's window from the current tree (like
    # delete-window in Emacs). We used to restore a full tree snapshot,
    # but that clobbers any other popups that were opened after this one.
    new_windows = remove_popup_window(state.workspace.windows, window_id, meta)

    state = %{
      state
      | workspace: MingaEditor.Session.State.set_windows(state.workspace, new_windows)
    }

    Layout.invalidate(state)
  end

  @spec split_direction(Rule.side()) :: WindowTree.direction()
  defp split_direction(:bottom), do: :horizontal
  defp split_direction(:top), do: :horizontal
  defp split_direction(:right), do: :vertical
  defp split_direction(:left), do: :vertical

  @spec maybe_swap_children(WindowTree.t(), Window.id(), Rule.side()) :: WindowTree.t()
  defp maybe_swap_children({:split, dir, first, second, size}, _popup_id, side)
       when side in [:top, :left] do
    {:split, dir, second, first, size}
  end

  defp maybe_swap_children(tree, _popup_id, _side), do: tree

  @spec apply_split_size(WindowTree.t(), Window.id(), Rule.t(), state()) :: WindowTree.t()
  defp apply_split_size({:split, dir, left, right, _size}, _popup_id, rule, state) do
    total = available_total(dir, state)
    popup_size = compute_popup_size(rule.size, total)

    # The popup_size is the size of the popup pane. The first child's
    # size is stored in the tree. For bottom/right popups, the first
    # child (editor) gets total - popup_size. For top/left, the first
    # child (popup) gets popup_size directly.
    first_size =
      case rule.side do
        side when side in [:bottom, :right] -> max(total - popup_size, 1)
        side when side in [:top, :left] -> max(popup_size, 1)
      end

    {:split, dir, left, right, first_size}
  end

  @spec available_total(WindowTree.direction(), state()) :: pos_integer()
  defp available_total(:horizontal, state) do
    layout = Layout.get(state)
    elem(layout.editor_area, 3)
  end

  defp available_total(:vertical, state) do
    layout = Layout.get(state)
    elem(layout.editor_area, 2)
  end

  @spec compute_popup_size(Rule.size(), pos_integer()) :: pos_integer()
  defp compute_popup_size({:percent, pct}, total), do: max(div(total * pct, 100), 1)
  defp compute_popup_size({:rows, n}, _total), do: max(n, 1)
  defp compute_popup_size({:cols, n}, _total), do: max(n, 1)

  @spec remove_popup_window(Windows.t(), Window.id(), PopupActive.t()) :: Windows.t()
  defp remove_popup_window(ws, window_id, %PopupActive{rule: %Rule{display: :float}}) do
    Windows.delete_window(ws, window_id)
  end

  defp remove_popup_window(ws, window_id, %PopupActive{}) do
    case Windows.remove_window(ws, window_id) do
      {:ok, windows} -> windows
      :error -> Windows.delete_window(ws, window_id)
    end
  end
end
