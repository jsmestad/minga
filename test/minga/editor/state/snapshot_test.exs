defmodule Minga.Editor.State.SnapshotTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Mode

  defp make_state(opts \\ []) do
    buf = Keyword.get(opts, :buffer)
    mode = Keyword.get(opts, :mode, :normal)

    %EditorState{
      port_manager: nil,
      tab_bar: Keyword.get(opts, :tab_bar),
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80),
        vim: %VimState{mode: mode, mode_state: Mode.initial_state()},
        buffers: %Buffers{
          active: buf,
          list: if(buf, do: [buf], else: []),
          active_index: 0
        },
        windows: %Windows{},
        keymap_scope: Keyword.get(opts, :keymap_scope, :editor)
      }
    }
  end

  describe "snapshot_tab_context/1" do
    test "captures per-tab fields directly (no surface_state bridge)" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      state = make_state(buffer: buf, mode: :insert, keymap_scope: :agent)

      ctx = EditorState.snapshot_tab_context(state)

      # Per-tab fields stored directly
      assert ctx.workspace.keymap_scope == :agent
      assert ctx.workspace.vim.mode == :insert
      assert ctx.workspace.buffers.active == buf
      assert ctx.workspace.windows == state.workspace.windows

      # No surface_* fields (old bridge format)
      refute Map.has_key?(ctx, :surface_module)
      refute Map.has_key?(ctx, :surface_state)
    end

    test "captures all per-tab fields" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      state = make_state(buffer: buf, mode: :insert, keymap_scope: :editor)

      ctx = EditorState.snapshot_tab_context(state)

      assert ctx.workspace.buffers.active == buf
      assert ctx.workspace.vim == state.workspace.vim
      assert ctx.workspace.viewport == state.workspace.viewport
      assert ctx.workspace.mouse == state.workspace.mouse
      assert ctx.workspace.highlight == state.workspace.highlight
      assert ctx.workspace.lsp_pending == state.workspace.lsp_pending
      assert ctx.workspace.completion == state.workspace.completion
      assert ctx.workspace.completion_trigger == state.workspace.completion_trigger
      assert ctx.workspace.injection_ranges == state.workspace.injection_ranges
      assert ctx.workspace.search == state.workspace.search
      assert ctx.workspace.pending_conflict == state.workspace.pending_conflict
    end
  end

  describe "restore_tab_context/2" do
    test "restores per-tab fields from flat context" do
      {:ok, buf_a} = BufferServer.start_link(content: "a")
      {:ok, buf_b} = BufferServer.start_link(content: "b")

      state = make_state(buffer: buf_a)

      # Build a context via snapshot round-trip
      state_b = make_state(buffer: buf_b, mode: :insert, keymap_scope: :editor)
      ctx = EditorState.snapshot_tab_context(state_b)

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.workspace.vim.mode == :insert
      assert restored.workspace.keymap_scope == :editor
      assert restored.workspace.buffers.active == buf_b
    end

    test "restores agent scope context correctly" do
      {:ok, buf_a} = BufferServer.start_link(content: "a")
      {:ok, buf_b} = BufferServer.start_link(content: "b")

      state = make_state(buffer: buf_a)

      state_b = make_state(buffer: buf_b, keymap_scope: :agent)
      ctx = EditorState.snapshot_tab_context(state_b)

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.workspace.keymap_scope == :agent
      assert restored.workspace.buffers.active == buf_b
    end

    test "migrates legacy context with active_buffer field" do
      {:ok, buf_a} = BufferServer.start_link(content: "a")
      {:ok, buf_b} = BufferServer.start_link(content: "b")

      state = make_state(buffer: buf_a)

      # Oldest format: bare fields like :active_buffer
      ctx = %{
        mode: :insert,
        mode_state: Mode.initial_state(),
        keymap_scope: :editor,
        active_buffer: buf_b,
        active_buffer_index: 1
      }

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.workspace.keymap_scope == :editor
      assert restored.workspace.vim.mode == :insert
      assert restored.workspace.buffers.active == buf_b
      assert restored.workspace.buffers.active_index == 1
    end

    test "handles empty context gracefully" do
      state = make_state()
      restored = EditorState.restore_tab_context(state, %{})
      assert restored.workspace.vim.mode == :normal
      assert restored.workspace.keymap_scope == :editor
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

      # Build a context via snapshot for tab b
      state_b = make_state(buffer: buf_b, mode: :insert, keymap_scope: :editor)
      tab_b_context = EditorState.snapshot_tab_context(state_b)

      tb = TabBar.update_context(tb, tab_b.id, tab_b_context)

      # Switch back to tab a so we can test switching to b
      tb = TabBar.switch_to(tb, tab_a.id)

      state = make_state(buffer: buf_a, tab_bar: tb, mode: :normal, keymap_scope: :editor)

      # Switch to tab b
      switched = EditorState.switch_tab(state, tab_b.id)

      # Should have restored tab b's context
      assert switched.workspace.vim.mode == :insert
      assert switched.workspace.buffers.active == buf_b
      assert switched.tab_bar.active_id == tab_b.id

      # Tab a should have been snapshotted with flat context
      saved_a = TabBar.get(switched.tab_bar, tab_a.id)
      assert saved_a.context.workspace.keymap_scope == :editor
      assert saved_a.context.workspace.vim.mode == :normal
      assert saved_a.context.workspace.buffers.active == buf_a
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

  describe "workspace field completeness" do
    test "WorkspaceState.fields/0 stays in sync with struct definition" do
      struct_keys =
        %Minga.Workspace.State{viewport: Minga.Editor.Viewport.new(24, 80)}
        |> Map.keys()
        |> Kernel.--([:__struct__])
        |> Enum.sort()

      assert Enum.sort(Minga.Workspace.State.fields()) == struct_keys
    end

    test "snapshot + restore round-trip preserves all 16 workspace fields" do
      {:ok, buf} = BufferServer.start_link(content: "hello")
      {:ok, msg_buf} = BufferServer.start_link(content: "")

      # Build a state with non-default values for every workspace field
      original =
        Minga.Test.StateFactory.build(
          vim: %VimState{mode: :insert, mode_state: Mode.initial_state()},
          buffers: %Buffers{active: buf, list: [buf], active_index: 0, messages: msg_buf},
          windows: %Windows{},
          file_tree: %Minga.Editor.State.FileTree{focused: true},
          viewport: Minga.Editor.Viewport.new(40, 120),
          mouse: %Minga.Editor.State.Mouse{click_count: 3},
          highlight: %Minga.Editor.State.Highlighting{version: 42},
          lsp_pending: %{make_ref() => :hover},
          completion: nil,
          completion_trigger: Minga.Editor.CompletionTrigger.new(),
          injection_ranges: %{buf => [%{start_byte: 0, end_byte: 10, language: "elixir"}]},
          search: %Minga.Editor.State.Search{last_pattern: "foo", last_direction: :backward},
          pending_conflict: {buf, "/tmp/test.txt"},
          keymap_scope: :agent,
          document_highlights: [%{range: %{start: %{line: 0, character: 0}, end: %{line: 0, character: 5}}, kind: 1}],
          agent_ui: Minga.Agent.UIState.new()
        )

      # Snapshot and restore into a different base state
      ctx = EditorState.snapshot_tab_context(original)
      fresh = Minga.Test.StateFactory.build()
      restored = EditorState.restore_tab_context(fresh, ctx)

      # Every workspace field must survive the round-trip
      for field <- Minga.Workspace.State.fields() do
        assert Map.get(restored.workspace, field) == Map.get(original.workspace, field),
               "field :#{field} was not preserved through snapshot/restore round-trip"
      end
    end
  end
end
