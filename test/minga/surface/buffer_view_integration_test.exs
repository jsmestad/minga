defmodule Minga.Surface.BufferViewIntegrationTest do
  @moduledoc """
  Integration tests verifying the BufferView surface is properly wired
  into the Editor GenServer.

  Tests that the Editor initializes a surface, keeps it in sync with
  EditorState, and stores/restores it across tab switches.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Surface.BufferView
  alias Minga.Surface.BufferView.State, as: BVState
  alias Minga.Surface.BufferView.State.VimState

  describe "surface initialization" do
    test "editor creates a BufferView surface on startup" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)

      assert state.surface_module == BufferView
      assert %BVState{} = state.surface_state
    end

    test "surface state reflects the editor's initial mode" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)

      assert %BVState{editing: %VimState{mode: :normal}} = state.surface_state
    end

    test "surface state reflects the editor's viewport dimensions" do
      ctx = start_editor("hello", width: 120, height: 40)
      state = :sys.get_state(ctx.editor)

      assert state.surface_state.viewport.cols == 120
      assert state.surface_state.viewport.rows == 40
    end

    test "surface state has the same active buffer as editor state" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)

      assert state.surface_state.buffers.active == state.buffers.active
    end
  end

  describe "surface sync after key dispatch" do
    test "surface state updates after entering insert mode" do
      ctx = start_editor("hello")

      # Press 'i' to enter insert mode
      send_keys(ctx, "i")
      state = :sys.get_state(ctx.editor)

      assert state.mode == :insert
      assert state.surface_state.editing.mode == :insert
    end

    test "surface state updates after cursor movement" do
      ctx = start_editor("hello\nworld")

      # Move down with 'j'
      send_keys(ctx, "j")
      state = :sys.get_state(ctx.editor)

      # The surface state's windows should match the editor's windows
      assert state.surface_state.windows == state.windows
    end
  end

  describe "tab context snapshot includes surface" do
    test "snapshot_tab_context includes surface_module and surface_state" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)

      context = Minga.Editor.State.snapshot_tab_context(state)

      assert context.surface_module == BufferView
      assert %BVState{} = context.surface_state
    end
  end
end
