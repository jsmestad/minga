defmodule Minga.Surface.BufferViewIntegrationTest do
  @moduledoc """
  Integration tests verifying the BufferView surface is properly wired
  into the Editor GenServer.

  Tests that the Editor initializes a surface, keeps it in sync with
  EditorState, and stores/restores it across tab switches.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Editor
  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Surface.BufferView
  alias Minga.Surface.BufferView.State, as: BufferViewState
  alias Minga.Surface.BufferView.State.VimState
  alias Minga.Test.HeadlessPort

  describe "surface initialization" do
    test "editor creates a BufferView surface on startup" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)

      assert state.surface_module == BufferView
      assert %BufferViewState{} = state.surface_state
    end

    test "surface state reflects the editor's initial mode" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)

      assert %BufferViewState{editing: %VimState{mode: :normal}} = state.surface_state
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
      assert %BufferViewState{} = context.surface_state
    end
  end

  describe "surface sync after resize" do
    test "surface state reflects new viewport after resize" do
      ctx = start_editor("hello", width: 80, height: 24)

      # Send a resize event
      ref = HeadlessPort.prepare_await(ctx.port)
      send(ctx.editor, {:minga_input, {:resize, 120, 40}})
      :ok = HeadlessPort.collect_frame(ref)

      state = :sys.get_state(ctx.editor)

      assert state.viewport.cols == 120
      assert state.viewport.rows == 40
      assert state.surface_state.viewport.cols == 120
      assert state.surface_state.viewport.rows == 40
    end
  end

  describe "surface sync after file events" do
    test "surface state stays in sync after highlight setup" do
      ctx = start_editor("hello")

      # The highlight setup happens during init. After the editor
      # is ready, surface state should reflect highlight state.
      state = :sys.get_state(ctx.editor)

      assert state.surface_state.highlight == state.highlight
    end
  end

  describe "handle_key dispatches through focus stack" do
    test "handle_key with context changes mode" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)

      # The surface state has context populated by the bridge
      bv_state = state.surface_state
      assert bv_state.context != nil

      # Press 'i' to enter insert mode
      {new_bv, effects} = BufferView.handle_key(bv_state, ?i, 0)

      assert new_bv.editing.mode == :insert
      assert is_list(effects)
    end

    test "handle_key without context is a no-op" do
      bv_state = %BufferViewState{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
        context: nil
      }

      {new_bv, effects} = BufferView.handle_key(bv_state, ?i, 0)

      # Without context, can't dispatch. Mode should remain :normal.
      assert new_bv.editing.mode == :normal
      assert effects == []
    end
  end

  describe "render callable through BufferView" do
    test "render with context runs the pipeline and updates state" do
      ctx = start_editor("hello world")
      state = :sys.get_state(ctx.editor)

      bv_state = state.surface_state
      assert bv_state.context != nil

      # Calling render should succeed and return updated state
      {new_bv, draws} = BufferView.render(bv_state, {0, 0, 80, 24})

      assert %BufferViewState{} = new_bv
      assert is_list(draws)
    end
  end

  describe "effect interpretation" do
    test "apply_effects with empty list is a no-op" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)

      new_state = Editor.apply_effects(state, [])
      assert new_state == state
    end

    test "apply_effects :render schedules a render timer" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)
      state = %{state | render_timer: nil}

      new_state = Editor.apply_effects(state, [:render])
      assert is_reference(new_state.render_timer)
    end

    test "apply_effects {:set_status, msg} sets the status message" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)

      new_state = Editor.apply_effects(state, [{:set_status, "hello world"}])
      assert new_state.status_msg == "hello world"
    end

    test "apply_effects handles multiple effects in order" do
      ctx = start_editor("hello")
      state = :sys.get_state(ctx.editor)
      state = %{state | render_timer: nil}

      new_state =
        Editor.apply_effects(state, [
          {:set_status, "doing stuff"},
          :render
        ])

      assert new_state.status_msg == "doing stuff"
      assert is_reference(new_state.render_timer)
    end
  end
end
