defmodule Minga.Editor.State.SnapshotTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Surface.BufferView.State, as: BufferViewState

  defp make_state(opts \\ []) do
    buf = Keyword.get(opts, :buffer)

    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(24, 80),
      mode: Keyword.get(opts, :mode, :normal),
      mode_state: Minga.Mode.initial_state(),
      buffers: %Buffers{
        active: buf,
        list: if(buf, do: [buf], else: []),
        active_index: 0
      },
      windows: %Windows{},
      keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
      tab_bar: Keyword.get(opts, :tab_bar)
    }
  end

  describe "snapshot_tab_context/1" do
    test "captures only canonical fields (surface_module, surface_state, keymap_scope)" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      state = make_state(buffer: buf, mode: :insert, keymap_scope: :agent)

      ctx = EditorState.snapshot_tab_context(state)

      # Canonical fields
      assert ctx.keymap_scope == :agent
      assert ctx.surface_module != nil
      assert ctx.surface_state != nil

      # Per-view fields are NOT stored directly on the context;
      # they live inside surface_state.
      refute Map.has_key?(ctx, :mode)
      refute Map.has_key?(ctx, :windows)
      refute Map.has_key?(ctx, :active_buffer)
      refute Map.has_key?(ctx, :agent)
      refute Map.has_key?(ctx, :agentic)
    end

    test "surface_state contains the per-view data" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      state = make_state(buffer: buf, mode: :insert, keymap_scope: :editor)

      ctx = EditorState.snapshot_tab_context(state)

      assert %BufferViewState{} = ctx.surface_state
      assert ctx.surface_state.buffers.active == buf
      assert ctx.surface_state.editing.mode == :insert
    end
  end

  describe "restore_tab_context/2" do
    test "restores per-tab fields from a canonical context" do
      {:ok, buf_a} = BufferServer.start_link(content: "a")
      {:ok, buf_b} = BufferServer.start_link(content: "b")

      state = make_state(buffer: buf_a)

      # Build a proper context via snapshot round-trip (editor scope)
      state_b = make_state(buffer: buf_b, mode: :insert, keymap_scope: :editor)
      ctx = EditorState.snapshot_tab_context(state_b)

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.mode == :insert
      assert restored.keymap_scope == :editor
      assert restored.buffers.active == buf_b
    end

    test "restores agent scope context correctly" do
      {:ok, buf_a} = BufferServer.start_link(content: "a")
      {:ok, buf_b} = BufferServer.start_link(content: "b")

      state = make_state(buffer: buf_a)

      # Agent scope is now just a keymap_scope value; surface stays BufferView
      state_b = make_state(buffer: buf_b, keymap_scope: :agent)
      ctx = EditorState.snapshot_tab_context(state_b)

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.keymap_scope == :agent
      # Surface is always BufferView now (no AgentView surface)
      assert restored.surface_module == Minga.Surface.BufferView
    end

    test "restores legacy context with agent field preserves scope" do
      {:ok, buf_a} = BufferServer.start_link(content: "a")
      {:ok, buf_b} = BufferServer.start_link(content: "b")

      state = make_state(buffer: buf_a)

      ctx = %{
        mode: :insert,
        mode_state: Minga.Mode.initial_state(),
        keymap_scope: :agent,
        active_buffer: buf_b,
        active_buffer_index: 1
      }

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.keymap_scope == :agent
      assert restored.surface_module == Minga.Surface.BufferView
    end

    test "restores legacy editor context with mode and buffer (no surface_state)" do
      {:ok, buf_a} = BufferServer.start_link(content: "a")
      {:ok, buf_b} = BufferServer.start_link(content: "b")

      state = make_state(buffer: buf_a)

      # Legacy editor context: has per-field snapshots but no surface_state
      ctx = %{
        mode: :insert,
        mode_state: Minga.Mode.initial_state(),
        keymap_scope: :editor,
        active_buffer: buf_b,
        active_buffer_index: 1
      }

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.mode == :insert
      assert restored.keymap_scope == :editor
      assert restored.buffers.active == buf_b
      assert restored.buffers.active_index == 1
    end

    test "handles empty context gracefully" do
      state = make_state()
      restored = EditorState.restore_tab_context(state, %{})
      assert restored.mode == :normal
      assert restored.keymap_scope == :editor
    end
  end

  describe "switch_tab/2" do
    test "snapshots current tab, restores target tab" do
      {:ok, buf_a} = BufferServer.start_link(content: "file a")
      {:ok, buf_b} = BufferServer.start_link(content: "file b")

      tab_a = Tab.new_file(1, "a.ex")
      tb = TabBar.new(tab_a)

      # Add a second tab with a stored context
      {tb, tab_b} = TabBar.add(tb, :file, "b.ex")

      # Build a proper context via snapshot for tab b
      state_b = make_state(buffer: buf_b, mode: :insert, keymap_scope: :editor)
      tab_b_context = EditorState.snapshot_tab_context(state_b)

      tb = TabBar.update_context(tb, tab_b.id, tab_b_context)

      # Switch back to tab a so we can test switching to b
      tb = TabBar.switch_to(tb, tab_a.id)

      state =
        make_state(buffer: buf_a, tab_bar: tb, mode: :normal, keymap_scope: :editor)

      # Switch to tab b
      switched = EditorState.switch_tab(state, tab_b.id)

      # Should have restored tab b's context (mode lives in surface_state.editing)
      assert switched.mode == :insert
      assert switched.buffers.active == buf_b
      assert switched.tab_bar.active_id == tab_b.id

      # Tab a should have been snapshotted as a canonical context
      saved_a = TabBar.get(switched.tab_bar, tab_a.id)
      assert saved_a.context.keymap_scope == :editor
      assert %BufferViewState{} = saved_a.context.surface_state
      assert saved_a.context.surface_state.editing.mode == :normal
      assert saved_a.context.surface_state.buffers.active == buf_a
    end

    test "switching to the current tab is a no-op" do
      tb = TabBar.new(Tab.new_file(1, "a"))
      state = make_state(tab_bar: tb)
      assert EditorState.switch_tab(state, 1) == state
    end

    test "switching with nil tab_bar is a no-op" do
      state = make_state(tab_bar: nil)
      assert EditorState.switch_tab(state, 1) == state
    end
  end

  describe "active_tab/1 and active_tab_kind/1" do
    test "returns the active tab" do
      tb = TabBar.new(Tab.new_file(1, "a"))
      state = make_state(tab_bar: tb)
      assert EditorState.active_tab(state).label == "a"
      assert EditorState.active_tab_kind(state) == :file
    end

    test "returns nil / :file for nil tab_bar" do
      state = make_state(tab_bar: nil)
      assert EditorState.active_tab(state) == nil
      assert EditorState.active_tab_kind(state) == :file
    end
  end
end
