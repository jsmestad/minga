defmodule Minga.Editor.LayoutInvalidationTest do
  @moduledoc """
  Regression tests for layout cache invalidation when panels toggle.

  The render pipeline caches per-line draw commands with baked-in absolute
  screen coordinates. When a side panel opens or closes, the editor's
  column offset changes, so all cached draws become stale.

  Regression: the file tree and editor content overlapped on the first
  render after toggling the tree because the window's cached draws still
  had the old col_off=0 coordinates.
  """
  use ExUnit.Case, async: true

  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.FileTree

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_state(rows \\ 24, cols \\ 80) do
    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(rows, cols),
      mode: :normal,
      mode_state: Minga.Mode.initial_state()
    }
  end

  defp with_window(state, win_id \\ 1) do
    window = %Window{
      id: win_id,
      buffer: self(),
      viewport: Viewport.new(24, 80),
      # Simulate populated caches from a previous render
      cached_gutter: %{0 => [{0, 0, " 1", []}], 1 => [{1, 0, " 2", []}]},
      cached_content: %{0 => [{0, 4, "hello", []}], 1 => [{1, 4, "world", []}]},
      dirty_lines: %{}
    }

    %{
      state
      | windows: %Windows{
          tree: {:leaf, win_id},
          map: %{win_id => window},
          active: win_id,
          next_id: win_id + 1
        }
    }
  end

  defp with_file_tree(state, width \\ 30) do
    tree = %FileTree{root: "/tmp", width: width}
    put_in(state.file_tree.tree, tree)
  end

  # ── Unit tests: invalidate_all_windows ─────────────────────────────────────

  describe "EditorState.invalidate_all_windows/1" do
    test "clears cached draws for all windows" do
      state = new_state() |> with_window(1)
      window = EditorState.active_window_struct(state)
      assert window.cached_content != %{}, "precondition: cache should be populated"
      assert window.cached_gutter != %{}, "precondition: gutter cache should be populated"

      state = EditorState.invalidate_all_windows(state)
      window = EditorState.active_window_struct(state)

      assert window.cached_content == %{}
      assert window.cached_gutter == %{}
      assert window.dirty_lines == :all
    end

    test "invalidates all windows in a split" do
      win1 = %Window{
        id: 1,
        buffer: self(),
        viewport: Viewport.new(12, 40),
        cached_content: %{0 => [{0, 0, "a", []}]},
        dirty_lines: %{}
      }

      win2 = %Window{
        id: 2,
        buffer: self(),
        viewport: Viewport.new(12, 40),
        cached_content: %{0 => [{0, 41, "b", []}]},
        dirty_lines: %{}
      }

      state = %{
        new_state()
        | windows: %Windows{
            tree: {:split, :vertical, {:leaf, 1}, {:leaf, 2}, 0},
            map: %{1 => win1, 2 => win2},
            active: 1,
            next_id: 3
          }
      }

      state = EditorState.invalidate_all_windows(state)

      for {_id, win} <- state.windows.map do
        assert win.cached_content == %{}
        assert win.cached_gutter == %{}
        assert win.dirty_lines == :all
      end
    end
  end

  # ── Unit tests: toggle_file_tree invalidates layout ────────────────────────

  describe "layout cache invalidation on file tree toggle" do
    test "opening file tree sets layout to nil" do
      state =
        new_state()
        |> with_window()
        |> Layout.put()

      assert is_struct(state.layout, Layout), "precondition: layout should be cached"

      # Simulate opening the file tree
      state = with_file_tree(state) |> Layout.invalidate()

      assert is_nil(state.layout), "layout cache should be nil after invalidation"
    end

    test "fresh compute after invalidation includes file tree rect" do
      state =
        new_state()
        |> with_window()
        |> Layout.put()

      # Cached layout has no file tree
      assert state.layout.file_tree == nil

      # Open file tree and invalidate
      state = with_file_tree(state, 20) |> Layout.invalidate()
      assert is_nil(state.layout)

      # Recompute gives correct layout with file tree
      layout = Layout.compute(state)
      assert layout.file_tree != nil
      assert layout.file_tree == {0, 0, 20, 23}

      # Editor area starts after tree + separator
      {_r, col, _w, _h} = layout.editor_area
      assert col == 21
    end

    test "closing file tree and recomputing removes file tree rect" do
      state =
        new_state()
        |> with_window()
        |> with_file_tree(20)
        |> Layout.put()

      assert state.layout.file_tree != nil
      {_r, col, _w, _h} = state.layout.editor_area
      assert col == 21

      # Close file tree and invalidate
      state = put_in(state.file_tree.tree, nil) |> Layout.invalidate()

      layout = Layout.compute(state)
      assert layout.file_tree == nil
      {_r, col, _w, _h} = layout.editor_area
      assert col == 0
    end
  end

  # ── Integration: stale cache detection ─────────────────────────────────────

  describe "stale window cache detection" do
    test "window caches with old col_off are stale after tree toggle" do
      state = new_state() |> with_window()

      # Simulate a render cycle: compute layout, note the editor col offset
      layout_before = Layout.compute(state)
      {_r, col_before, _w, _h} = layout_before.editor_area
      assert col_before == 0, "editor starts at col 0 without tree"

      # The window has cached draws with col_off=0 baked in (see with_window helper)
      window = EditorState.active_window_struct(state)
      [{_row, cached_col, _text, _style}] = window.cached_content[0]
      assert cached_col == 4, "cached draw at col 4 (gutter_w=4, col_off=0)"

      # Now open file tree. The editor should shift right.
      state = with_file_tree(state, 20)
      layout_after = Layout.compute(state)
      {_r, col_after, _w, _h} = layout_after.editor_area
      assert col_after == 21, "editor starts at col 21 with tree"

      # WITHOUT invalidation, the cached draws still have col=4 (old col_off=0).
      # That's wrong: they should be at col=25 (col_off=21 + gutter_w=4).
      # The test verifies that invalidate_all_windows clears these stale caches.
      state = EditorState.invalidate_all_windows(state)
      window = EditorState.active_window_struct(state)

      assert window.cached_content == %{},
             "stale cached draws should be cleared after invalidation"

      assert window.dirty_lines == :all,
             "all lines should be marked dirty for re-render with new col_off"
    end
  end
end
