defmodule Minga.Popup.Lifecycle do
  @moduledoc """
  Pure state transformations for opening and closing popup windows.

  Popup windows are managed splits (or floating overlays) governed by
  `Popup.Rule` structs. Opening a popup snapshots the current window tree
  so closing it restores the original layout.

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

  1. `close_popup/2` reads the window's `popup_meta` to find the saved tree.
  2. Restores the window tree to the snapshot, removes the popup window
     from the map, and returns focus to the previously active window.
  """

  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Popup.Active, as: PopupActive
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
  @spec open_popup(state(), String.t(), pid()) :: {:ok, state()} | :no_match
  def open_popup(state, buffer_name, buffer_pid)
      when is_binary(buffer_name) and is_pid(buffer_pid) do
    case PopupRegistry.match(buffer_name) do
      {:ok, rule} ->
        {:ok, apply_rule(state, rule, buffer_pid)}

      :none ->
        :no_match
    end
  end

  @doc """
  Closes the popup window with the given id.

  Restores the window tree to the snapshot taken when the popup was opened,
  removes the popup window from the map, and returns focus to the previously
  active window. The underlying buffer is kept alive (not killed).

  Returns state unchanged if the window id doesn't exist or isn't a popup.
  """
  @spec close_popup(state(), Window.id()) :: state()
  def close_popup(state, window_id) when is_integer(window_id) do
    case Map.fetch(state.windows.map, window_id) do
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
    close_popup(state, state.windows.active)
  end

  @doc """
  Closes all open popup windows.

  Used on tab switch to clean up transient popups. Closes popups in
  reverse order of creation (LIFO) to avoid tree restore conflicts.
  """
  @spec close_all_popups(state()) :: state()
  def close_all_popups(state) do
    popup_ids =
      state.windows.map
      |> Enum.filter(fn {_id, w} -> Window.popup?(w) end)
      |> Enum.sort_by(fn {id, _w} -> id end, :desc)
      |> Enum.map(fn {id, _w} -> id end)

    Enum.reduce(popup_ids, state, fn id, acc -> close_popup(acc, id) end)
  end

  @doc """
  Returns true if the active window is a popup.
  """
  @spec active_is_popup?(state()) :: boolean()
  def active_is_popup?(state) do
    case Map.fetch(state.windows.map, state.windows.active) do
      {:ok, window} -> Window.popup?(window)
      :error -> false
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec apply_rule(state(), Rule.t(), pid()) :: state()
  defp apply_rule(%{windows: ws} = state, %Rule{display: :split} = rule, buffer_pid) do
    # Snapshot current layout for restore
    previous_tree = ws.tree
    previous_active = ws.active

    # Create the popup window
    next_id = ws.next_id
    {rows, cols} = viewport_size(state)
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
        active = PopupActive.new(rule, next_id, previous_tree, previous_active)
        popup_window = %{popup_window | popup_meta: active}

        # Update state
        new_map = Map.put(ws.map, next_id, popup_window)
        new_windows = %{ws | tree: new_tree, map: new_map, next_id: next_id + 1}

        state = %{state | windows: new_windows}

        # Optionally switch focus to the popup
        state =
          if rule.focus do
            %{state | windows: %{state.windows | active: next_id}}
          else
            state
          end

        Layout.invalidate(state)

      :error ->
        state
    end
  end

  # Float display mode is a placeholder until #343 lands.
  # For now, fall back to split behavior.
  defp apply_rule(state, %Rule{display: :float} = rule, buffer_pid) do
    apply_rule(state, %{rule | display: :split}, buffer_pid)
  end

  @spec do_close(state(), Window.id(), PopupActive.t()) :: state()
  defp do_close(state, window_id, %PopupActive{} = meta) do
    ws = state.windows

    # If the popup is focused, switch focus to the previously active window
    state =
      if ws.active == window_id do
        # Restore focus to the previous active window, or find any non-popup window
        restore_id =
          if Map.has_key?(ws.map, meta.previous_active) do
            meta.previous_active
          else
            find_non_popup_window(ws.map, window_id)
          end

        %{state | windows: %{ws | active: restore_id}}
      else
        state
      end

    ws = state.windows

    # Restore the tree snapshot if available, otherwise just remove the split
    new_tree =
      case meta.previous_tree do
        nil ->
          # No snapshot (edge case). Just remove the split.
          case WindowTree.close(ws.tree, window_id) do
            {:ok, tree} -> tree
            :error -> ws.tree
          end

        tree ->
          tree
      end

    # Remove the popup window from the map
    new_map = Map.delete(ws.map, window_id)
    new_windows = %{ws | tree: new_tree, map: new_map}
    state = %{state | windows: new_windows}

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

  @spec viewport_size(state()) :: {pos_integer(), pos_integer()}
  defp viewport_size(%{viewport: %Viewport{rows: r, cols: c}}), do: {r, c}
  defp viewport_size(_state), do: {24, 80}

  @spec find_non_popup_window(%{Window.id() => Window.t()}, Window.id()) :: Window.id()
  defp find_non_popup_window(window_map, exclude_id) do
    case Enum.find(window_map, fn {id, w} -> id != exclude_id and not Window.popup?(w) end) do
      {id, _window} -> id
      nil -> exclude_id
    end
  end
end
