defmodule Minga.Popup.Lifecycle do
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

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.DisplayList
  alias Minga.Editor.FloatingWindow
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Face
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

  @doc """
  Renders floating popup overlays for all float-mode popup windows.

  Called by the render pipeline's Chrome stage. Returns a list of
  `DisplayList.Overlay` structs, one per float popup. Split-mode
  popups are rendered as normal windows and are not included here.
  """
  @spec render_float_overlays(state()) :: [DisplayList.Overlay.t()]
  def render_float_overlays(state) do
    state.windows.map
    |> Enum.filter(fn {_id, w} -> float_popup?(w) end)
    |> Enum.map(fn {_id, window} -> render_float_overlay(state, window) end)
  end

  @doc """
  Returns true when the click at `{row, col}` falls inside any float
  popup's bounding box. Used by the input layer to decide whether a
  click should be swallowed or should dismiss the popup.
  """
  @spec click_inside_float?(state(), integer(), integer()) :: boolean()
  def click_inside_float?(state, row, col) do
    state.windows.map
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
    vp = state.viewport

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

  @spec render_float_overlay(state(), Window.t()) :: DisplayList.Overlay.t()
  defp render_float_overlay(state, window) do
    rule = window.popup_meta.rule
    vp = state.viewport
    theme = state.theme.popup

    # Build content draws from the buffer
    content = build_float_content(window.buffer, rule, vp, theme)

    # Build the floating window spec
    spec = %FloatingWindow.Spec{
      title: buffer_title(window.buffer),
      content: content,
      width: float_width(rule),
      height: float_height(rule),
      position: :center,
      border: rule.border,
      theme: theme,
      viewport: {vp.rows, vp.cols}
    }

    draws = FloatingWindow.render(spec)
    %DisplayList.Overlay{draws: draws}
  end

  @spec build_float_content(pid(), Rule.t(), Viewport.t(), map()) :: [DisplayList.draw()]
  defp build_float_content(buffer_pid, rule, vp, theme) do
    # Compute interior dimensions to know how many lines to fetch
    spec = %FloatingWindow.Spec{
      title: nil,
      width: float_width(rule),
      height: float_height(rule),
      border: rule.border,
      theme: theme,
      viewport: {vp.rows, vp.cols}
    }

    {interior_h, interior_w} = FloatingWindow.interior_size(spec)

    # Fetch buffer lines (with a short timeout to avoid blocking the render)
    lines =
      if is_pid(buffer_pid) do
        try do
          snapshot = BufferServer.render_snapshot(buffer_pid, 0, interior_h)
          snapshot.lines
        catch
          :exit, _ -> []
        end
      else
        []
      end

    # Convert lines to draw tuples (relative to interior origin)
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, row} ->
      if row < interior_h do
        text = String.slice(line, 0, interior_w)
        [DisplayList.draw(row, 0, text, Face.new(fg: theme.fg, bg: theme.bg))]
      else
        []
      end
    end)
  end

  @spec buffer_title(pid()) :: String.t() | nil
  defp buffer_title(pid) when is_pid(pid) do
    BufferServer.buffer_name(pid)
  catch
    :exit, _ -> nil
  end

  defp buffer_title(_), do: nil

  @spec float_width(Rule.t()) :: FloatingWindow.Spec.size()
  defp float_width(%Rule{width: nil, size: size}), do: size
  defp float_width(%Rule{width: w}), do: w

  @spec float_height(Rule.t()) :: FloatingWindow.Spec.size()
  defp float_height(%Rule{height: nil, size: size}), do: size
  defp float_height(%Rule{height: h}), do: h

  # ── Private ────────────────────────────────────────────────────────────────

  @spec apply_rule(state(), Rule.t(), pid()) :: state()
  defp apply_rule(%{windows: ws} = state, %Rule{display: :split} = rule, buffer_pid) do
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
        active = PopupActive.new(rule, next_id, previous_active)
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

  defp apply_rule(%{windows: ws} = state, %Rule{display: :float} = rule, buffer_pid) do
    previous_active = ws.active

    # Create the popup window (not added to the tree, only the map)
    next_id = ws.next_id
    {rows, cols} = viewport_size(state)
    popup_window = Window.new(next_id, buffer_pid, rows, cols)

    # Attach popup metadata
    active = PopupActive.new(rule, next_id, previous_active)
    popup_window = %{popup_window | popup_meta: active}

    # Add window to map but NOT to the tree (floats overlay the layout)
    new_map = Map.put(ws.map, next_id, popup_window)
    new_windows = %{ws | map: new_map, next_id: next_id + 1}
    state = %{state | windows: new_windows}

    # Optionally switch focus to the popup
    state =
      if rule.focus do
        %{state | windows: %{state.windows | active: next_id}}
      else
        state
      end

    Layout.invalidate(state)
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

    # Remove just this popup's window from the current tree (like
    # delete-window in Emacs). We used to restore a full tree snapshot,
    # but that clobbers any other popups that were opened after this one.
    new_tree =
      case WindowTree.close(ws.tree, window_id) do
        {:ok, tree} -> tree
        :error -> ws.tree
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
