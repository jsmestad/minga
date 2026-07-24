defmodule MingaEditor.State.SnapshotTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.FeatureState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Highlight
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias Minga.Mode

  defp make_state(opts \\ []) do
    buf = Keyword.get(opts, :buffer)
    mode = Keyword.get(opts, :mode, :normal)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %MingaEditor.Session.State{
        editing: %VimState{mode: mode, mode_state: Mode.initial_state()},
        buffers: %Buffers{
          active: buf,
          list:
            if buf do
              [buf]
            else
              []
            end
        },
        keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
        file_tree: Keyword.get(opts, :file_tree, %FileTreeState{})
      },
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %MingaEditor.Shell.Traditional.State{tab_bar: Keyword.get(opts, :tab_bar)}
        )
    }
  end

  describe "snapshot_tab_context/1" do
    test "captures per-tab fields directly (no surface_state bridge)" do
      {:ok, buf} = BufferProcess.start_link(content: "hello")
      state = make_state(buffer: buf, mode: :insert, keymap_scope: :agent)

      ctx = MingaEditor.State.Tab.Context.snapshot(state.workspace)

      # Per-tab fields stored directly
      assert ctx.keymap_scope == :agent
      assert ctx.editing.mode == :insert
      assert ctx.buffers.active == buf
      assert ctx.windows == state.workspace.windows

      # No surface_* fields (old bridge format)
      refute Map.has_key?(ctx, :surface_module)
      refute Map.has_key?(ctx, :surface_state)
    end

    test "captures all per-tab fields" do
      {:ok, buf} = BufferProcess.start_link(content: "hello")
      state = make_state(buffer: buf, mode: :insert, keymap_scope: :editor)

      highlighting = %Highlighting{highlights: %{buf => Highlight.new()}}

      state = %{
        state
        | parser: MingaEditor.State.Parser.accept_highlighting(state.parser, highlighting)
      }

      state = %{
        state
        | parser:
            MingaEditor.State.Parser.accept_injection_ranges(state.parser, %{buf => [:range]})
      }

      ctx = MingaEditor.State.Tab.Context.snapshot(state.workspace)

      assert ctx.buffers.active == buf
      assert ctx.editing == state.workspace.editing
      refute Map.has_key?(ctx, :viewport)
      refute :viewport in ctx.present_fields
      assert ctx.mouse == state.workspace.mouse
      refute :lsp_pending in Context.field_names()
      refute :lsp_pending in ctx.present_fields
      refute Map.has_key?(Context.to_workspace_map(ctx), :lsp_pending)
      assert ctx.search == state.workspace.search

      # PID/process-keyed parser state is not representable in a tab snapshot.
      refute Map.has_key?(ctx, :highlight)
      refute :highlight in ctx.present_fields
      refute Map.has_key?(ctx, :injection_ranges)
      refute :injection_ranges in ctx.present_fields
    end

    test "does not carry agent UI projection" do
      workspace =
        SessionState.set_agent_ui(
          make_state().workspace,
          bump_ui_message_version(UIState.new(), 9)
        )

      ctx = Context.snapshot(workspace)

      refute Map.has_key?(Map.from_struct(ctx), :agent_ui)
      refute :agent_ui in ctx.present_fields
    end

    test "normalises transient editing state before snapshotting" do
      state = make_state(mode: :normal)
      command_state = %Mode.CommandState{input: ""}

      state = %{
        state
        | workspace:
            SessionState.set_editing(state.workspace, %VimState{
              mode: :normal,
              mode_state: command_state
            })
      }

      ctx = MingaEditor.State.Tab.Context.snapshot(state.workspace)

      assert ctx.editing.mode == :normal
      assert match?(%Mode.State{}, ctx.editing.mode_state)
    end
  end

  describe "restore_tab_context/2" do
    test "restores per-tab fields from flat context" do
      {:ok, buf_a} = BufferProcess.start_link(content: "a")
      {:ok, buf_b} = BufferProcess.start_link(content: "b")

      state = make_state(buffer: buf_a)

      state_b = make_state(buffer: buf_b, mode: :insert, keymap_scope: :editor)
      ctx = MingaEditor.State.Tab.Context.snapshot(state_b.workspace)

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.workspace.editing.mode == :insert
      assert restored.workspace.keymap_scope == :editor
      assert restored.workspace.buffers.active == buf_b
    end

    test "restores agent scope context correctly" do
      {:ok, buf_a} = BufferProcess.start_link(content: "a")
      {:ok, buf_b} = BufferProcess.start_link(content: "b")

      state = make_state(buffer: buf_a)

      state_b = make_state(buffer: buf_b, keymap_scope: :agent)
      ctx = MingaEditor.State.Tab.Context.snapshot(state_b.workspace)

      restored = EditorState.restore_tab_context(state, ctx)
      assert restored.workspace.keymap_scope == :agent
      assert restored.workspace.buffers.active == buf_b
    end

    test "does not restore stale agent UI from tab context" do
      stale_ui = bump_ui_message_version(UIState.new(), 9)
      live_ui = bump_ui_message_version(UIState.new(), 3)
      context = Context.snapshot(SessionState.set_agent_ui(make_state().workspace, stale_ui))
      workspace = SessionState.set_agent_ui(make_state().workspace, live_ui)

      restored = SessionState.restore_tab_context(workspace, context)

      assert restored.agent_ui.panel.transcript.version == 3
      refute restored.agent_ui.panel.transcript.version == 9
    end

    test "ignores legacy raw-map agent UI projection" do
      stale_ui = bump_ui_message_version(UIState.new(), 9)
      live_ui = bump_ui_message_version(UIState.new(), 3)

      context = %{
        present_fields: [:agent_ui],
        agent_ui: stale_ui
      }

      restored =
        SessionState.restore_tab_context(
          SessionState.set_agent_ui(make_state().workspace, live_ui),
          context
        )

      assert restored.agent_ui.panel.transcript.version == 3
    end

    test "legacy viewport contexts do not restore stale terminal dimensions" do
      {:ok, buf} = BufferProcess.start_link(content: "legacy")

      frontend_viewport = Viewport.new(40, 120)
      stale_viewport = Viewport.new(24, 80)
      state = make_state(buffer: buf)

      state = %{
        state
        | frontend: MingaEditor.State.Frontend.resize_terminal(state.frontend, frontend_viewport)
      }

      ctx =
        Context.from_workspace_map(%{
          "present_fields" => ["viewport", "buffers"],
          "viewport" => stale_viewport,
          "buffers" => %Buffers{active: buf, list: [buf]}
        })

      restored = EditorState.restore_tab_context(state, ctx)

      assert restored.frontend.terminal_viewport == frontend_viewport
      refute Map.has_key?(Map.from_struct(restored.workspace), :viewport)
      assert restored.workspace.buffers.active == buf
      refute Map.has_key?(Context.to_workspace_map(ctx), :viewport)
    end

    test "older bare-field contexts are not migrated; only canonical keys are read" do
      # Pre-#1440, contexts stored bare fields like :active_buffer / :mode and
      # were silently migrated. Now restore_tab_context only reads canonical
      # keys (those in SessionState.field_names()), so legacy fields are
      # ignored and the workspace falls back to whatever the live state already
      # holds. No crash, no migration, no warning.
      {:ok, buf_a} = BufferProcess.start_link(content: "a")
      {:ok, buf_b} = BufferProcess.start_link(content: "b")

      state = make_state(buffer: buf_a, mode: :normal, keymap_scope: :editor)

      legacy_ctx = %{
        mode: :insert,
        mode_state: Mode.initial_state(),
        active_buffer: buf_b,
        active_buffer_index: 1
      }

      restored = EditorState.restore_tab_context(state, legacy_ctx)

      # The legacy keys are silently ignored — workspace fields stay as they were.
      assert restored.workspace.editing.mode == :normal
      assert restored.workspace.buffers.active == buf_a
    end

    test "migrates legacy vim field into editing" do
      state = make_state(mode: :normal)
      legacy_vim = %VimState{mode: :insert, mode_state: Mode.initial_state()}

      restored = EditorState.restore_tab_context(state, %{vim: legacy_vim})

      assert restored.workspace.editing == legacy_vim
    end

    test "restores string-key encoded contexts using present_fields" do
      {:ok, buf_a} = BufferProcess.start_link(content: "a")
      {:ok, buf_b} = BufferProcess.start_link(content: "b")
      state = make_state(buffer: buf_a, keymap_scope: :editor)
      legacy_vim = %VimState{mode: :insert, mode_state: Mode.initial_state()}
      buffers = %Buffers{active: buf_b, list: [buf_b], active_index: 0}

      restored =
        EditorState.restore_tab_context(state, %{
          "version" => 1,
          "present_fields" => ["buffers", "editing"],
          "vim" => legacy_vim,
          "buffers" => buffers
        })

      assert restored.workspace.editing == legacy_vim
      assert restored.workspace.buffers == buffers
      assert restored.workspace.keymap_scope == :editor
    end

    test "handles empty context gracefully" do
      state = make_state()
      restored = EditorState.restore_tab_context(state, %{})
      assert restored.workspace.editing.mode == :normal
      assert restored.workspace.keymap_scope == :editor
    end

    test "synthesized file and agent tab defaults keep direct file_tree state" do
      file_tree = %FileTreeState{project_root: "/tmp/project"}

      file_state =
        make_state(
          tab_bar: TabBar.new(Tab.new_file(1, "new.ex")),
          file_tree: file_tree
        )

      file_restored = EditorState.restore_tab_context(file_state, %{})
      file_ctx = TabBar.active(file_restored.shell_runtime.state.tab_bar).context

      assert file_ctx.file_tree.project_root == file_tree.project_root
      assert FileTreeState.tree(file_ctx.file_tree) == nil
      refute FileTreeState.focused?(file_ctx.file_tree)
      assert FeatureState.empty?(file_ctx.feature_state)

      agent_state =
        make_state(
          tab_bar: TabBar.new(Tab.new_agent(1, "Agent")),
          file_tree: file_tree
        )

      agent_restored = EditorState.restore_tab_context(agent_state, %{})
      agent_ctx = TabBar.active(agent_restored.shell_runtime.state.tab_bar).context

      assert agent_ctx.file_tree.project_root == file_tree.project_root
      assert FileTreeState.tree(agent_ctx.file_tree) == nil
      refute FileTreeState.focused?(agent_ctx.file_tree)
      assert FeatureState.empty?(agent_ctx.feature_state)
    end

    test "writes synthesized defaults back into the active tab on empty context" do
      {:ok, buf} = BufferProcess.start_link(content: "new file")

      tab = Tab.new_file(1, "new.ex")
      tb = TabBar.new(tab)

      state = make_state(buffer: buf, tab_bar: tb)
      assert Context.empty?(TabBar.active(tb).context)

      restored = EditorState.restore_tab_context(state, %{})

      updated_tb = restored.shell_runtime.state.tab_bar
      stored_ctx = TabBar.get(updated_tb, tab.id).context

      refute Context.empty?(stored_ctx)
      assert stored_ctx.keymap_scope == :editor
      assert stored_ctx.editing.mode == :normal
      assert stored_ctx.buffers.active == buf
    end
  end

  describe "Buffers.scrub_dead_active/1" do
    test "returns unchanged when active is nil" do
      bs = %Buffers{active: nil, list: [], active_index: 0}
      assert Buffers.scrub_dead_active(bs) == bs
    end

    test "returns unchanged when active pid is alive" do
      {:ok, buf} = BufferProcess.start_link(content: "alive")
      bs = %Buffers{active: buf, list: [buf], active_index: 0}
      assert Buffers.scrub_dead_active(bs) == bs
    end

    test "selects neighbor when active pid is dead" do
      {:ok, buf_a} = BufferProcess.start_link(content: "a")
      {:ok, buf_b} = BufferProcess.start_link(content: "b")

      bs = %Buffers{active: buf_a, list: [buf_a, buf_b], active_index: 0}
      GenServer.stop(buf_a)

      scrubbed = Buffers.scrub_dead_active(bs)
      assert scrubbed.active == buf_b
      assert scrubbed.list == [buf_b]
      assert scrubbed.active_index == 0
    end

    test "sets active to nil when all pids are dead" do
      {:ok, buf_a} = BufferProcess.start_link(content: "a")
      {:ok, buf_b} = BufferProcess.start_link(content: "b")

      bs = %Buffers{active: buf_a, list: [buf_a, buf_b], active_index: 0}
      GenServer.stop(buf_a)
      GenServer.stop(buf_b)

      scrubbed = Buffers.scrub_dead_active(bs)
      assert scrubbed.active == nil
      assert scrubbed.list == []
      assert scrubbed.active_index == 0
    end

    test "clamps active_index when dead pid was at the end" do
      {:ok, buf_a} = BufferProcess.start_link(content: "a")
      {:ok, buf_b} = BufferProcess.start_link(content: "b")
      {:ok, buf_c} = BufferProcess.start_link(content: "c")

      bs = %Buffers{active: buf_c, list: [buf_a, buf_b, buf_c], active_index: 2}
      GenServer.stop(buf_c)

      scrubbed = Buffers.scrub_dead_active(bs)
      assert scrubbed.active in [buf_a, buf_b]
      assert scrubbed.list == [buf_a, buf_b]
      assert scrubbed.active_index == 1
    end
  end

  describe "restore_tab_context/2 with dead buffer" do
    test "scrubs dead active buffer pid on restore" do
      {:ok, buf_a} = BufferProcess.start_link(content: "a")
      {:ok, buf_b} = BufferProcess.start_link(content: "b")

      # Build state with two buffers, buf_a active
      state_with_both =
        make_state(buffer: buf_a)
        |> then(fn state ->
          %{
            state
            | workspace:
                SessionState.set_buffers(state.workspace, %Buffers{
                  active: buf_a,
                  list: [buf_a, buf_b],
                  active_index: 0
                })
          }
        end)

      # Snapshot the context
      ctx = MingaEditor.State.Tab.Context.snapshot(state_with_both.workspace)

      # Kill the active buffer
      GenServer.stop(buf_a)

      # Restore the context into a fresh workspace
      fresh_state = make_state(buffer: buf_b)
      restored = EditorState.restore_tab_context(fresh_state, ctx)

      # The dead pid should have been scrubbed; buf_b is active now
      assert restored.workspace.buffers.active == buf_b
      assert buf_a not in restored.workspace.buffers.list
      assert buf_b in restored.workspace.buffers.list
    end
  end

  describe "switch_tab/2" do
    test "snapshots current tab, restores target tab" do
      {:ok, buf_a} = BufferProcess.start_link(content: "file a")
      {:ok, buf_b} = BufferProcess.start_link(content: "file b")

      tab_a = Tab.new_file(1, "a.ex")
      tb = TabBar.new(tab_a)

      {tb, tab_b} = TabBar.add(tb, :file, "b.ex")

      state_b = make_state(buffer: buf_b, mode: :insert, keymap_scope: :editor)
      tab_b_context = MingaEditor.State.Tab.Context.snapshot(state_b.workspace)

      tb = TabBar.update_context(tb, tab_b.id, tab_b_context)

      # Switch back to tab a so we can test switching to b
      tb = TabBar.switch_to(tb, tab_a.id)

      state = make_state(buffer: buf_a, tab_bar: tb, mode: :normal, keymap_scope: :editor)

      # Switch to tab b
      switched = MingaEditor.TabWorkflow.switch(state, tab_b.id)

      # Should have restored tab b's context
      assert switched.workspace.editing.mode == :insert
      assert switched.workspace.buffers.active == buf_b
      assert switched.shell_runtime.state.tab_bar.active_id == tab_b.id

      # Tab a should have been snapshotted with flat context
      saved_a = TabBar.get(switched.shell_runtime.state.tab_bar, tab_a.id)
      assert saved_a.context.keymap_scope == :editor
      assert saved_a.context.editing.mode == :normal
      assert saved_a.context.buffers.active == buf_a
    end

    test "switching to the current tab is a no-op" do
      tb = TabBar.new(Tab.new_file(1, "a"))
      state = make_state(tab_bar: tb)
      assert MingaEditor.TabWorkflow.switch(state, 1) == state
    end

    test "switching to a brand-new tab writes context into tab bar immediately" do
      {:ok, buf} = BufferProcess.start_link(content: "original")

      tab_a = Tab.new_file(1, "a.ex")
      tb = TabBar.new(tab_a)

      {tb, tab_b} = TabBar.add(tb, :file, "b.ex")
      tb = TabBar.switch_to(tb, tab_a.id)
      assert Context.empty?(TabBar.get(tb, tab_b.id).context)

      state = make_state(buffer: buf, tab_bar: tb, mode: :normal, keymap_scope: :editor)
      switched = MingaEditor.TabWorkflow.switch(state, tab_b.id)

      stored_ctx = TabBar.get(switched.shell_runtime.state.tab_bar, tab_b.id).context
      refute Context.empty?(stored_ctx)
      assert stored_ctx.keymap_scope == :editor
      assert stored_ctx.buffers.active == buf
    end

    test "switching with nil tab_bar is a no-op" do
      state = make_state(tab_bar: nil)
      assert MingaEditor.TabWorkflow.switch(state, 1) == state
    end
  end

  describe "from_workspace/1 (direct struct-to-struct)" do
    test "produces identical output to the legacy Map.from_struct path" do
      {:ok, buf} = BufferProcess.start_link(content: "hello")

      ws = %MingaEditor.Session.State{
        editing: %VimState{mode: :insert, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: buf, list: [buf]},
        keymap_scope: :agent
      }

      # New direct path
      new_ctx = Context.from_workspace(ws)

      # Old path: normalize editing, Map.from_struct, from_workspace_map
      old_ctx =
        ws
        |> Map.update!(:editing, &VimState.normalize/1)
        |> Map.from_struct()
        |> Context.from_workspace_map()

      # All workspace data fields must match exactly
      assert new_ctx.version == old_ctx.version
      assert new_ctx.keymap_scope == old_ctx.keymap_scope
      assert new_ctx.buffers == old_ctx.buffers
      assert new_ctx.windows == old_ctx.windows
      assert new_ctx.file_tree == old_ctx.file_tree
      assert new_ctx.feature_state == old_ctx.feature_state
      refute Map.has_key?(new_ctx, :viewport)
      refute Map.has_key?(old_ctx, :viewport)
      assert new_ctx.mouse == old_ctx.mouse
      assert new_ctx.search == old_ctx.search
      assert new_ctx.editing == old_ctx.editing
      assert new_ctx.document_highlights == old_ctx.document_highlights

      # The new path intentionally excludes PID-keyed shared state from the snapshot.
      excluded = [:agent_ui, :highlight, :injection_ranges]

      assert Enum.sort(new_ctx.present_fields) ==
               Enum.sort(old_ctx.present_fields -- excluded)

      # Snapshot-appropriate fields produce the same workspace map on round-trip.
      new_map = Context.to_workspace_map(new_ctx)
      old_map = Context.to_workspace_map(old_ctx) |> Map.drop(excluded)
      assert new_map == old_map
      refute Map.has_key?(new_map, :viewport)
    end

    test "round-trips through to_workspace_map preserving snapshot fields" do
      {:ok, buf} = BufferProcess.start_link(content: "round-trip")

      ws = %MingaEditor.Session.State{
        editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: buf, list: [buf]},
        keymap_scope: :editor
      }

      ctx = Context.from_workspace(ws)
      restored_map = Context.to_workspace_map(ctx)

      assert restored_map.keymap_scope == :editor
      assert restored_map.editing.mode == :normal
      assert restored_map.buffers.active == buf
      refute Map.has_key?(restored_map, :viewport)
      assert restored_map.windows == ws.windows
      assert restored_map.file_tree == ws.file_tree
      assert restored_map.mouse == ws.mouse
      assert restored_map.search == ws.search
      refute Map.has_key?(restored_map, :lsp_pending)

      refute Map.has_key?(restored_map, :highlight)
      refute Map.has_key?(restored_map, :injection_ranges)
    end

    test "migrates legacy file tree from feature state into direct field" do
      file_tree = %FileTreeState{project_root: "/tmp/project"}

      legacy_ctx =
        Context.from_workspace_map(%{
          feature_state: FeatureState.put(FeatureState.new(), :builtin, :file_tree, file_tree)
        })

      assert legacy_ctx.file_tree == file_tree
      assert FeatureState.get(legacy_ctx.feature_state, :builtin, :file_tree) == nil
      assert Context.to_workspace_map(legacy_ctx).file_tree == file_tree
    end

    test "direct file tree wins when legacy feature state also exists" do
      direct_file_tree = %FileTreeState{project_root: "/tmp/direct"}
      legacy_file_tree = %FileTreeState{project_root: "/tmp/legacy"}

      legacy_ctx =
        Context.from_workspace_map(%{
          file_tree: direct_file_tree,
          feature_state:
            FeatureState.put(FeatureState.new(), :builtin, :file_tree, legacy_file_tree)
        })

      assert legacy_ctx.file_tree == direct_file_tree
      assert FeatureState.get(legacy_ctx.feature_state, :builtin, :file_tree) == nil
      assert Context.to_workspace_map(legacy_ctx).file_tree == direct_file_tree
    end

    test "normalises transient vim state" do
      ws = %MingaEditor.Session.State{
        editing: %VimState{mode: :normal, mode_state: %Mode.CommandState{input: ""}},
        buffers: %Buffers{},
        keymap_scope: :editor
      }

      ctx = Context.from_workspace(ws)

      assert ctx.editing.mode == :normal
      assert match?(%Mode.State{}, ctx.editing.mode_state)
    end
  end

  describe "shell runtime active tab queries" do
    test "returns the active tab" do
      tb = TabBar.new(Tab.new_file(1, "a"))
      state = make_state(tab_bar: tb)
      assert MingaEditor.Shell.Runtime.active_tab(state.shell_runtime).label == "a"
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :file
    end

    test "returns nil / :file for nil tab_bar" do
      state = make_state(tab_bar: nil)
      assert MingaEditor.Shell.Runtime.active_tab(state.shell_runtime) == nil
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :file
    end
  end

  defp bump_ui_message_version(%UIState{} = ui, count) do
    panel =
      Enum.reduce(1..count//1, ui.panel, fn _step, panel -> Panel.bump_message_version(panel) end)

    UIState.replace_panel(ui, panel)
  end
end
