defmodule MingaEditor.State.TabSwitchTest do
  @moduledoc """
  Pure-function tests for tab switching via `switch_tab/2`.

  Tests snapshot/restore of workspace context across tab switches without
  starting any GenServer. Uses `base_state/1` from `RenderPipeline.TestHelpers`
  to construct minimal state structs.

  Part of work item B3 from `docs/PLAN-ui-stability.md`.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Handlers.LspEventHandler
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.LSP.FormatOperation
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Highlight

  import MingaEditor.RenderPipeline.TestHelpers

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Builds a state with two file tabs. Tab 1 is active with buf1, tab 2
  # has buf2 snapshotted in its context.
  @spec state_with_two_file_tabs() :: {EditorState.t(), pid(), pid()}
  defp state_with_two_file_tabs do
    {:ok, buf1} = BufferProcess.start_link(content: "file one")
    {:ok, buf2} = BufferProcess.start_link(content: "file two")

    win_id = 1
    window1 = Window.new(win_id, buf1, 24, 80)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :editor,
        buffers: %Buffers{active: buf1, list: [buf1], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => window1},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    # Set up tab bar with tab 1 active
    tab1 = Tab.new_file(1, "one.ex")
    tb = TabBar.new(tab1)
    context1 = Context.snapshot(state.workspace)
    tb = TabBar.update_context(tb, 1, context1)

    # Create tab 2 with buf2 in its context
    {tb, tab2} = TabBar.add(tb, :file, "two.ex")

    # Build tab 2's context: a workspace with buf2 active
    win2 = Window.new(win_id, buf2, 24, 80)

    tab2_ws = %SessionState{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
      keymap_scope: :editor,
      buffers: %Buffers{active: buf2, list: [buf2], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => win2},
        active: win_id,
        next_id: win_id + 1
      }
    }

    tab2_context = Map.from_struct(tab2_ws)
    tb = TabBar.update_context(tb, tab2.id, tab2_context)

    # Switch back to tab 1 as active
    tb = TabBar.switch_to(tb, 1)

    state =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tb
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    {state, buf1, buf2}
  end

  # Builds a state with a file tab and an agent tab.
  # File tab (tab 1) is active.
  @spec state_with_file_and_agent_tabs() ::
          {EditorState.t(), Tab.id(), Tab.id(), pid()}
  defp state_with_file_and_agent_tabs do
    {:ok, file_buf} = BufferProcess.start_link(content: "file content")

    win_id = 1
    file_window = Window.new(win_id, file_buf, 24, 80)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :editor,
        buffers: %Buffers{active: file_buf, list: [file_buf], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => file_window},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    # Set up tab bar: file tab 1 active, agent tab 2
    file_tab = Tab.new_file(1, "app.ex")
    tb = TabBar.new(file_tab)
    file_context = Context.snapshot(state.workspace)
    tb = TabBar.update_context(tb, 1, file_context)

    {tb, agent_tab} = TabBar.add(tb, :agent, "Agent")

    # Build agent tab context with :agent keymap_scope and agent_chat window
    agent_window = Window.new_agent_chat(win_id, 24, 80)

    agent_ws = %SessionState{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
      keymap_scope: :agent,
      buffers: %Buffers{active: nil, list: [], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => agent_window},
        active: win_id,
        next_id: win_id + 1
      }
    }

    agent_context = Map.from_struct(agent_ws)
    tb = TabBar.update_context(tb, agent_tab.id, agent_context)

    # Switch back to tab 1 (file tab active)
    tb = TabBar.switch_to(tb, 1)

    state =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tb
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    {state, file_tab.id, agent_tab.id, file_buf}
  end

  @spec track_tab_operations(EditorState.t(), Tab.id()) ::
          {EditorState.t(), Operation.t(), Operation.t()}
  defp track_tab_operations(state, tab_id) do
    {references_feedback, references} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :lsp_references,
        "lsp:references:one.ex",
        "Finding references…",
        cancelable?: false,
        replace?: false
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, references_feedback)
    }

    {rename_feedback, rename} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :lsp_rename,
        "lsp:rename:one.ex",
        "Renaming…",
        cancelable?: false,
        replace?: false
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, rename_feedback)
    }

    state =
      %{
        state
        | lsp:
            state.lsp
            |> LSPState.track_operation_request(
              make_ref(),
              {:references, references.id, tab_id}
            )
            |> LSPState.track_operation_request(make_ref(), {:rename, rename.id, tab_id})
      }

    {state, references, rename}
  end

  # ── switch_tab/2 ──────────────────────────────────────────────────────────────

  describe "switch_tab/2" do
    test "no-op when tab bar is nil" do
      state = base_state()
      assert state.shell_runtime.state.tab_bar == nil

      {new_state, result} = EditorState.switch_tab(state, 42)

      assert new_state == state
      assert result == :unchanged
    end

    test "no-op when switching to already active tab" do
      {state, _buf1, _buf2} = state_with_two_file_tabs()
      tb = state.shell_runtime.state.tab_bar
      active_id = tb.active_id

      {new_state, result} = EditorState.switch_tab(state, active_id)

      assert new_state == state
      assert result == :unchanged
    end

    test "missing target leaves current references and rename requests pending" do
      {state, _buf1, _buf2} = state_with_two_file_tabs()
      current_id = state.shell_runtime.state.tab_bar.active_id
      {state, references, rename} = track_tab_operations(state, current_id)
      requests = state.lsp.operation_requests

      {unchanged, result} = EditorState.switch_tab(state, 999_999)

      assert result == :unchanged
      assert unchanged.lsp.operation_requests == requests

      assert {:ok, pending_references} =
               OperationFeedback.fetch(unchanged.feedback.operation_feedback, references.id)

      assert pending_references.status == :pending

      assert {:ok, pending_rename} =
               OperationFeedback.fetch(unchanged.feedback.operation_feedback, rename.id)

      assert pending_rename.status == :pending
    end

    test "file-to-file preserves both tab contexts" do
      {state, buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_runtime.state.tab_bar
      tab2_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      # Confirm starting state
      assert state.workspace.buffers.active == buf1
      assert state.workspace.keymap_scope == :editor

      # Switch to tab 2
      {new_state, result} = EditorState.switch_tab(state, tab2_id)

      # Active buffer should now be buf2 (restored from tab 2's context)
      assert new_state.workspace.buffers.active == buf2
      assert new_state.workspace.keymap_scope == :editor
      assert {:switched, %Tab{id: ^tab2_id}} = result

      # Tab 1's context should be snapshotted (preserved for later restore)
      tb = new_state.shell_runtime.state.tab_bar
      tab1 = TabBar.get(tb, 1)
      assert tab1.context.buffers.active == buf1
    end

    test "file-to-agent sets keymap_scope to :agent" do
      {state, file_tab_id, agent_tab_id, _file_buf} =
        state_with_file_and_agent_tabs()

      # Confirm starting state: file tab active with :editor scope
      assert state.workspace.keymap_scope == :editor

      # Switch to agent tab
      {new_state, _effects} = EditorState.switch_tab(state, agent_tab_id)

      # The restored workspace should have :agent scope (from the agent tab's context)
      assert new_state.workspace.keymap_scope == :agent

      # The tab bar should show the agent tab as active
      tb = new_state.shell_runtime.state.tab_bar
      assert tb.active_id == agent_tab_id
      active_tab = TabBar.active(tb)
      assert active_tab.kind == :agent

      # The file tab's context should be snapshotted
      file_tab = TabBar.get(tb, file_tab_id)
      assert file_tab.context.keymap_scope == :editor
    end

    test "agent-to-file sets keymap_scope to :editor" do
      {state, file_tab_id, agent_tab_id, _file_buf} =
        state_with_file_and_agent_tabs()

      # First switch to agent tab to set up the agent-active state
      {state, _effects} = EditorState.switch_tab(state, agent_tab_id)
      assert state.workspace.keymap_scope == :agent

      # Now switch back to file tab
      {new_state, _effects} = EditorState.switch_tab(state, file_tab_id)

      # Should restore :editor scope
      assert new_state.workspace.keymap_scope == :editor

      # The agent tab's context should be preserved
      tb = new_state.shell_runtime.state.tab_bar
      agent_tab = TabBar.get(tb, agent_tab_id)
      assert agent_tab.context.keymap_scope == :agent
    end

    test "round-trip invariant: switch away and back restores equivalent state" do
      {state, _buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_runtime.state.tab_bar
      tab2_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      # Capture the workspace state before any switch
      original_buffers = state.workspace.buffers
      original_scope = state.workspace.keymap_scope
      original_editing = state.workspace.editing

      # Switch to tab 2
      {state_after_switch, _effects1} = EditorState.switch_tab(state, tab2_id)
      assert state_after_switch.workspace.buffers.active == buf2

      # Switch back to tab 1
      {state_after_roundtrip, _effects2} = EditorState.switch_tab(state_after_switch, 1)

      # The workspace should be equivalent to the original
      assert state_after_roundtrip.workspace.buffers.active == original_buffers.active
      assert state_after_roundtrip.workspace.buffers.list == original_buffers.list

      assert state_after_roundtrip.workspace.buffers.active_index ==
               original_buffers.active_index

      assert state_after_roundtrip.workspace.keymap_scope == original_scope
      assert state_after_roundtrip.workspace.editing.mode == original_editing.mode
    end

    test "returns the selected tab as a focused result" do
      {state, _file_tab_id, agent_tab_id, _file_buf} =
        state_with_file_and_agent_tabs()

      {_new_state, result} = EditorState.switch_tab(state, agent_tab_id)

      assert {:switched, %Tab{id: ^agent_tab_id, kind: :agent}} = result
    end

    test "invalidates layout after switch" do
      {state, _buf1, _buf2} = state_with_two_file_tabs()
      tb = state.shell_runtime.state.tab_bar
      tab2_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      {new_state, _effects} = EditorState.switch_tab(state, tab2_id)

      # Layout should be cleared after a tab switch
      assert new_state.render.layout == nil
    end

    test "tab switch restores the target tab's pending LSP refs" do
      {state, _buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_runtime.state.tab_bar
      current_id = tb.active_id
      target_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      pending_current = %{make_ref() => :completion_resolve}
      pending_target = %{make_ref() => {:semantic_tokens, buf2}}

      state = %{state | workspace: SessionState.set_lsp_pending(state.workspace, pending_current)}
      tab2 = TabBar.get(tb, target_id)
      tab2_context = Context.put_fields(tab2.context, lsp_pending: pending_target)

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              TabBar.update_context(tb, target_id, tab2_context)
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      {switched, _effects} = EditorState.switch_tab(state, target_id)

      assert switched.workspace.lsp_pending == pending_target

      assert TabBar.get(switched.shell_runtime.state.tab_bar, current_id).context.lsp_pending ==
               pending_current

      {switched_back, _effects} = EditorState.switch_tab(switched, current_id)

      assert switched_back.workspace.lsp_pending == pending_current

      assert TabBar.get(switched_back.shell_runtime.state.tab_bar, target_id).context.lsp_pending ==
               pending_target
    end

    test "tab switch retires outgoing references and rename requests" do
      {state, _buf1, _buf2} = state_with_two_file_tabs()
      tab_bar = state.shell_runtime.state.tab_bar
      current_id = tab_bar.active_id
      target_id = Enum.find(tab_bar.tabs, &(&1.id != current_id)).id

      {state, references, rename} = track_tab_operations(state, current_id)

      {switched, _effects} = EditorState.switch_tab(state, target_id)

      assert switched.lsp.operation_requests == %{}

      assert {:ok, references} =
               OperationFeedback.fetch(
                 switched.feedback.operation_feedback,
                 references.id
               )

      assert references.status == :stale
      assert references.message == "References response ignored after tab switch"

      assert {:ok, rename} =
               OperationFeedback.fetch(switched.feedback.operation_feedback, rename.id)

      assert rename.status == :stale
      assert rename.message == "Rename response ignored after tab switch"
    end

    test "closing the active tab retires its references and rename requests" do
      {state, _buf1, _buf2} = state_with_two_file_tabs()
      current_id = state.shell_runtime.state.tab_bar.active_id
      {state, references, rename} = track_tab_operations(state, current_id)

      closed = BufferManagement.execute(state, :force_quit)

      assert TabBar.get(closed.shell_runtime.state.tab_bar, current_id) == nil
      assert closed.lsp.operation_requests == %{}

      assert {:ok, closed_references} =
               OperationFeedback.fetch(closed.feedback.operation_feedback, references.id)

      assert closed_references.status == :stale

      assert {:ok, closed_rename} =
               OperationFeedback.fetch(closed.feedback.operation_feedback, rename.id)

      assert closed_rename.status == :stale
    end

    test "entering empty state retires operations for every removed file tab" do
      {state, _buf1, _buf2} = state_with_two_file_tabs()
      tab_bar = state.shell_runtime.state.tab_bar
      [first_tab, second_tab] = tab_bar.tabs

      {state, first_references, first_rename} = track_tab_operations(state, first_tab.id)
      {state, second_references, second_rename} = track_tab_operations(state, second_tab.id)

      empty = EditorState.enter_empty_state(state)

      assert empty.shell_runtime.state.tab_bar.tabs == []
      assert empty.lsp.operation_requests == %{}

      for operation <- [first_references, first_rename, second_references, second_rename] do
        assert {:ok, retired} =
                 OperationFeedback.fetch(empty.feedback.operation_feedback, operation.id)

        assert retired.status == :stale
      end
    end

    test "tab switch preserves Editor-global formatting ownership" do
      {state, buf1, _buf2} = state_with_two_file_tabs()
      tb = state.shell_runtime.state.tab_bar
      current_id = tb.active_id
      target_id = Enum.find(tb.tabs, &(&1.id != current_id)).id
      ref = make_ref()

      operation = %FormatOperation{
        client: self(),
        ref: ref,
        buffer: buf1,
        version: 0,
        encoding: :utf8,
        spinner_timer: make_ref(),
        cancellable_timer: make_ref(),
        timeout_timer: make_ref()
      }

      state =
        %{state | lsp: (&LSPState.track_format(&1, operation)).(state.lsp)}

      {switched, _effects} = EditorState.switch_tab(state, target_id)

      assert {:ok, ^operation} = LSPState.fetch_format(switched.lsp, ref)

      {switched_back, _effects} = EditorState.switch_tab(switched, current_id)

      assert {:ok, ^operation} = LSPState.fetch_format(switched_back.lsp, ref)
    end

    test "format responses remain isolated across a tab switch" do
      {state, buf_a, buf_b} = state_with_two_file_tabs()
      tab_bar = state.shell_runtime.state.tab_bar
      target_id = Enum.find(tab_bar.tabs, &(&1.id != 1)).id
      ref_a = make_ref()
      ref_b = make_ref()

      operation_a = %FormatOperation{
        client: self(),
        ref: ref_a,
        buffer: buf_a,
        version: Minga.Buffer.version(buf_a),
        encoding: :utf8,
        spinner_timer: make_ref(),
        cancellable_timer: make_ref(),
        timeout_timer: make_ref()
      }

      state =
        %{state | lsp: (&LSPState.track_format(&1, operation_a)).(state.lsp)}

      {state, _effects} = EditorState.switch_tab(state, target_id)

      operation_b = %FormatOperation{
        client: self(),
        ref: ref_b,
        buffer: buf_b,
        version: Minga.Buffer.version(buf_b),
        encoding: :utf8,
        spinner_timer: make_ref(),
        cancellable_timer: make_ref(),
        timeout_timer: make_ref()
      }

      state =
        %{state | lsp: (&LSPState.track_format(&1, operation_b)).(state.lsp)}

      edits_a = [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 8}
          },
          "newText" => "formatted A"
        }
      ]

      {after_a, effects} =
        LspEventHandler.handle(state, {:lsp_response, ref_a, {:ok, edits_a}})

      assert effects == [:render_now]
      assert Minga.Buffer.content(buf_a) == "formatted A"
      assert Minga.Buffer.content(buf_b) == "file two"
      refute LSPState.format_active?(after_a.lsp, ref_a)
      assert LSPState.format_active?(after_a.lsp, ref_b)

      {after_timeout, timeout_effects} =
        LspEventHandler.handle(after_a, {:lsp_format_timeout, ref_b})

      assert timeout_effects == [:render_now]
      refute LSPState.format_active?(after_timeout.lsp, ref_b)
      assert Minga.Buffer.content(buf_b) == "file two"
      assert_receive {:"$gen_cast", {:cancel_request, ^ref_b}}
    end

    test "tab switch preserves live highlighting and ignores stale target parser state" do
      {state, buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_runtime.state.tab_bar
      current_id = tb.active_id
      target_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      hl_data = Highlight.new()

      live_highlight = %Highlighting{
        highlights: %{buf1 => hl_data, buf2 => Highlight.put_spans(hl_data, 5, [])}
      }

      stale_highlight = %Highlighting{highlights: %{buf2 => Highlight.new()}}

      state = %{
        state
        | parser: MingaEditor.State.Parser.accept_highlighting(state.parser, live_highlight)
      }

      target_tab = TabBar.get(tb, target_id)

      target_context =
        target_tab.context
        |> Map.put(:highlight, stale_highlight)
        |> Map.update!(:present_fields, &[:highlight | &1])

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              TabBar.update_context(tb, target_id, target_context)
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      {switched, _effects} = EditorState.switch_tab(state, target_id)

      assert switched.parser.highlighting == live_highlight

      refute :highlight in TabBar.get(switched.shell_runtime.state.tab_bar, current_id).context.present_fields

      {switched_back, _effects} = EditorState.switch_tab(switched, current_id)

      assert switched_back.parser.highlighting == live_highlight
    end

    test "tab switch preserves live injection ranges and ignores stale target ranges" do
      {state, buf1, buf2} = state_with_two_file_tabs()
      tb = state.shell_runtime.state.tab_bar
      current_id = tb.active_id
      target_id = Enum.find(tb.tabs, &(&1.id != tb.active_id)).id

      live_ranges = %{buf1 => [:current_range], buf2 => [:parsed_after_restore]}
      stale_ranges = %{buf2 => [:stale_range]}

      state = %{
        state
        | parser: MingaEditor.State.Parser.accept_injection_ranges(state.parser, live_ranges)
      }

      target_tab = TabBar.get(tb, target_id)

      target_context =
        target_tab.context
        |> Map.put(:injection_ranges, stale_ranges)
        |> Map.update!(:present_fields, &[:injection_ranges | &1])

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              TabBar.update_context(tb, target_id, target_context)
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      {switched, _effects} = EditorState.switch_tab(state, target_id)

      assert switched.parser.injection_ranges == live_ranges

      refute :injection_ranges in TabBar.get(switched.shell_runtime.state.tab_bar, current_id).context.present_fields

      {switched_back, _effects} = EditorState.switch_tab(switched, current_id)

      assert switched_back.parser.injection_ranges == live_ranges
    end
  end
end
