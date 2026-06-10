defmodule MingaEditor.LayoutInvalidationTest do
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

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias Minga.Project.FileTree

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    Process.put(:sidebar_registry, table)
    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp new_state(rows \\ 24, cols \\ 80) do
    %EditorState{
      port_manager: nil,
      sidebar_registry: Process.get(:sidebar_registry),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(rows, cols),
        editing: VimState.new()
      }
    }
  end

  defp with_window(state, win_id \\ 1) do
    window = %Window{
      id: win_id,
      content: {:buffer, self()},
      buffer: self(),
      viewport: Viewport.new(24, 80),
      # Simulate populated caches from a previous render
      render_cache: %MingaEditor.Window.RenderCache{
        cached_gutter: %{0 => [{0, 0, " 1", []}], 1 => [{1, 0, " 2", []}]},
        cached_content: %{0 => [{0, 4, "hello", []}], 1 => [{1, 4, "world", []}]},
        dirty_lines: %{}
      }
    }

    put_in(state.workspace.windows, %Windows{
      tree: {:leaf, win_id},
      map: %{win_id => window},
      active: win_id,
      next_id: win_id + 1
    })
  end

  defp with_file_tree(state, width \\ 30) do
    file_tree =
      MingaEditor.State.FileTree.open(
        %MingaEditor.State.FileTree{},
        %FileTree{root: "/tmp", width: width},
        nil
      )

    EditorState.set_file_tree(state, file_tree)
  end

  # ── Unit tests: invalidate_all_windows ─────────────────────────────────────

  describe "EditorState.invalidate_all_windows/1" do
    test "clears cached draws for all windows" do
      state = new_state() |> with_window(1)
      window = EditorState.active_window_struct(state)
      assert window.render_cache.cached_content != %{}, "precondition: cache should be populated"

      assert window.render_cache.cached_gutter != %{},
             "precondition: gutter cache should be populated"

      state = EditorState.invalidate_all_windows(state)
      window = EditorState.active_window_struct(state)

      assert window.render_cache.cached_content == %{}
      assert window.render_cache.cached_gutter == %{}
      assert window.render_cache.dirty_lines == :all
    end

    test "invalidates all windows in a split" do
      win1 = %Window{
        id: 1,
        content: {:buffer, self()},
        buffer: self(),
        viewport: Viewport.new(12, 40),
        render_cache: %MingaEditor.Window.RenderCache{
          cached_content: %{0 => [{0, 0, "a", []}]},
          dirty_lines: %{}
        }
      }

      win2 = %Window{
        id: 2,
        content: {:buffer, self()},
        buffer: self(),
        viewport: Viewport.new(12, 40),
        render_cache: %MingaEditor.Window.RenderCache{
          cached_content: %{0 => [{0, 41, "b", []}]},
          dirty_lines: %{}
        }
      }

      state =
        put_in(new_state().workspace.windows, %Windows{
          tree: {:split, :vertical, {:leaf, 1}, {:leaf, 2}, 0},
          map: %{1 => win1, 2 => win2},
          active: 1,
          next_id: 3
        })

      state = EditorState.invalidate_all_windows(state)

      for {_id, win} <- state.workspace.windows.map do
        assert win.render_cache.cached_content == %{}
        assert win.render_cache.cached_gutter == %{}
        assert win.render_cache.dirty_lines == :all
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

    test "fresh compute after invalidation reflects the file tree toggle" do
      # The semantic GUI layout reserves no BEAM columns for the file tree (the
      # frontend renders it natively, `Layout.TUI` was deleted in #2235), so the
      # editor stays at col 0. The behavior under test is that invalidation forces
      # a fresh recompute that picks up the toggled file-tree state.
      state =
        new_state()
        |> with_window()
        |> Layout.put()

      assert state.layout.file_tree == nil

      state = with_file_tree(state, 20) |> Layout.invalidate()
      assert is_nil(state.layout)

      layout = Layout.compute(state)
      assert layout.file_tree == nil
      {_r, col, _w, _h} = layout.editor_area
      assert col == 0
    end

    test "closing file tree and recomputing keeps the editor full-width" do
      state =
        new_state()
        |> with_window()
        |> with_file_tree(20)
        |> Layout.put()

      # No reserved columns even with the file tree open.
      assert state.layout.file_tree == nil
      {_r, col, _w, _h} = state.layout.editor_area
      assert col == 0

      state =
        EditorState.set_file_tree(state, %MingaEditor.State.FileTree{}) |> Layout.invalidate()

      layout = Layout.compute(state)
      assert layout.file_tree == nil
      {_r, col, _w, _h} = layout.editor_area
      assert col == 0
    end
  end

  # ── Integration: stale cache detection ─────────────────────────────────────

  describe "stale window cache detection" do
    test "window caches with baked-in coordinates are cleared on invalidation" do
      # The file tree no longer shifts the editor column (semantic GUI layout,
      # #2235), so a window split is the layout change that makes cached absolute
      # coordinates stale. The guard is that `invalidate_all_windows` clears the
      # cached draws so they re-render with the new offsets.
      state = new_state() |> with_window()

      layout_before = Layout.compute(state)
      {_r, col_before, _w, _h} = layout_before.editor_area
      assert col_before == 0, "editor starts at col 0"

      # The window has cached draws with col_off=0 baked in (see with_window helper)
      window = EditorState.active_window_struct(state)
      [{_row, cached_col, _text, _style}] = window.render_cache.cached_content[0]
      assert cached_col == 4, "cached draw at col 4 (gutter_w=4, col_off=0)"

      # Splitting the window vertically moves the right pane's column offset, so
      # the cached col=4 draws on a moved window are stale.
      state = with_vsplit(state)
      layout_after = Layout.compute(state)
      assert map_size(layout_after.window_layouts) == 2

      state = EditorState.invalidate_all_windows(state)

      for {_id, win} <- state.workspace.windows.map do
        assert win.render_cache.cached_content == %{},
               "stale cached draws should be cleared after invalidation"

        assert win.render_cache.dirty_lines == :all,
               "all lines should be marked dirty for re-render with new offsets"
      end
    end
  end

  defp with_vsplit(state) do
    win1 = %Window{
      id: 1,
      content: {:buffer, self()},
      buffer: self(),
      viewport: Viewport.new(24, 40),
      render_cache: %MingaEditor.Window.RenderCache{
        cached_content: %{0 => [{0, 4, "hello", []}]},
        dirty_lines: %{}
      }
    }

    win2 = %Window{
      id: 2,
      content: {:buffer, self()},
      buffer: self(),
      viewport: Viewport.new(24, 40),
      render_cache: %MingaEditor.Window.RenderCache{
        cached_content: %{0 => [{0, 44, "world", []}]},
        dirty_lines: %{}
      }
    }

    put_in(state.workspace.windows, %Windows{
      tree: {:split, :vertical, {:leaf, 1}, {:leaf, 2}, 0},
      map: %{1 => win1, 2 => win2},
      active: 1,
      next_id: 3
    })
  end
end
