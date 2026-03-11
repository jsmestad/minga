defmodule Minga.Editor.State.SnapshotTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport

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
    test "captures per-tab fields" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      state = make_state(buffer: buf, mode: :insert, keymap_scope: :agent)

      ctx = EditorState.snapshot_tab_context(state)

      assert ctx.mode == :insert
      assert ctx.keymap_scope == :agent
      assert ctx.active_buffer == buf
      assert ctx.active_buffer_index == 0
      assert %Windows{} = ctx.windows
      # agent/agentic are no longer stored directly in the context;
      # they live inside surface_state
      assert ctx.surface_module != nil
      assert ctx.surface_state != nil
      refute Map.has_key?(ctx, :agent)
      refute Map.has_key?(ctx, :agentic)
    end
  end

  describe "restore_tab_context/2" do
    test "restores per-tab fields from a context with surface state" do
      {:ok, buf_a} = BufferServer.start_link(content: "a")
      {:ok, buf_b} = BufferServer.start_link(content: "b")

      state = make_state(buffer: buf_a)

      # Build a proper context via snapshot round-trip
      state_b = make_state(buffer: buf_b, mode: :insert, keymap_scope: :agent)
      ctx = EditorState.snapshot_tab_context(state_b)

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.mode == :insert
      assert restored.keymap_scope == :agent
      assert restored.buffers.active == buf_b
    end

    test "restores legacy context with agent field (no surface_state)" do
      {:ok, buf_a} = BufferServer.start_link(content: "a")
      {:ok, buf_b} = BufferServer.start_link(content: "b")

      state = make_state(buffer: buf_a)

      # Legacy context: has agent but no surface_state
      ctx = %{
        mode: :insert,
        mode_state: :some_state,
        keymap_scope: :agent,
        active_buffer: buf_b,
        active_buffer_index: 1,
        agent: AgentState.set_status(%AgentState{}, :thinking)
      }

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.mode == :insert
      assert restored.mode_state == :some_state
      assert restored.keymap_scope == :agent
      assert restored.buffers.active == buf_b
      assert restored.buffers.active_index == 1
      assert restored.agent.status == :thinking
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

      # Should have restored tab b's context
      assert switched.mode == :insert
      assert switched.buffers.active == buf_b
      assert switched.tab_bar.active_id == tab_b.id

      # Tab a should have been snapshotted
      saved_a = TabBar.get(switched.tab_bar, tab_a.id)
      assert saved_a.context.mode == :normal
      assert saved_a.context.active_buffer == buf_a
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
