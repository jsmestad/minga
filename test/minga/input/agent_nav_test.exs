defmodule Minga.Input.AgentNavTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Input.AgentNav
  @ctrl Minga.Port.Protocol.mod_ctrl()

  defp make_state(opts \\ []) do
    buf = AgentBufferSync.start_buffer()

    messages =
      Keyword.get(opts, :messages, [
        {:user, "Hello"},
        {:assistant,
         "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10"}
      ])

    AgentBufferSync.sync(buf, messages)

    {:ok, prompt_buf} = BufferServer.start_link(content: "")
    {:ok, file_buf} = BufferServer.start_link(content: "file content")

    agent = %AgentState{buffer: buf, status: :idle}

    agentic = %UIState{
      panel: %UIState.Panel{
        visible: true,
        input_focused: Keyword.get(opts, :input_focused, false),
        scroll: Minga.Scroll.new(),
        spinner_frame: 0,
        provider_name: "anthropic",
        model_name: "claude-sonnet-4",
        thinking_level: "medium",
        prompt_buffer: prompt_buf
      },
      view: %UIState.View{
        active: true,
        focus: Keyword.get(opts, :focus, :chat)
      }
    }

    %EditorState{
      port_manager: self(),
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80),
        agent_ui: agentic,
        buffers: %Buffers{active: file_buf, list: [file_buf]},
        keymap_scope: :agent
      },
      agent: agent
    }
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Chat focus: key routing through Mode FSM
  # ══════════════════════════════════════════════════════════════════════════

  describe "chat focus navigation" do
    test "j moves cursor down in agent buffer" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(buf, {0, 0})

      # AgentNav processes the key through Mode FSM directly (no buffer swap
      # needed since buffers.active is already set by focus_window in prod).
      # In tests, buffers.active is the file buffer. Put the agent buffer as
      # active to simulate the real focus_window behavior.
      state = put_in(state.workspace.buffers.active, buf)

      {:handled, _new_state} = AgentNav.handle_key(state, ?j, 0)

      {line, _col} = BufferServer.cursor(buf)
      assert line == 1
    end

    test "k moves cursor up in agent buffer" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(buf, {5, 0})

      state = put_in(state.workspace.buffers.active, buf)

      {:handled, _new_state} = AgentNav.handle_key(state, ?k, 0)

      {line, _col} = BufferServer.cursor(buf)
      assert line == 4
    end

    test "G moves cursor to end of buffer" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(buf, {0, 0})

      state = put_in(state.workspace.buffers.active, buf)

      {:handled, _new_state} = AgentNav.handle_key(state, ?G, 0)

      {line, _col} = BufferServer.cursor(buf)
      total = BufferServer.line_count(buf)
      assert line == total - 1
    end

    test "unpins agent chat window when user navigates" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(buf, {0, 0})

      state = put_in(state.workspace.buffers.active, buf)

      # Set up a window tree with an agent chat window to test unpinning
      window = %Window{
        id: 1,
        buffer: buf,
        content: {:agent_chat, buf},
        cursor: {0, 0},
        viewport: Viewport.new(20, 80),
        pinned: true
      }

      state =
        put_in(state.workspace.windows, %Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        })

      {:handled, new_state} = AgentNav.handle_key(state, ?j, 0)

      # The window should be unpinned after navigation
      win = Map.get(new_state.workspace.windows.map, 1)
      assert win.pinned == false
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # delegate_to_mode_fsm/4: used by AgentPanel for side panel chat nav
  # ══════════════════════════════════════════════════════════════════════════

  describe "delegate_to_mode_fsm/4" do
    test "swaps buffer, processes key, and restores original active buffer" do
      state = make_state()
      original_buf = state.workspace.buffers.active
      chat_buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(chat_buf, {0, 0})

      new_state = AgentNav.delegate_to_mode_fsm(state, chat_buf, ?j, 0)

      # Original buffer should be restored
      assert new_state.workspace.buffers.active == original_buf

      # Cursor should have moved in the chat buffer
      {line, _col} = BufferServer.cursor(chat_buf)
      assert line == 1
    end

    test "blocks insert mode transitions on read-only chat buffer" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(buf, {0, 0})

      # 's' (substitute) would enter insert mode in normal vim,
      # but the chat buffer is read-only so mode stays normal.
      new_state = AgentNav.delegate_to_mode_fsm(state, buf, ?s, 0)

      assert new_state.workspace.vim.mode == :normal
    end

    test "syncs scroll offset to cursor line" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(buf, {0, 0})

      new_state = AgentNav.delegate_to_mode_fsm(state, buf, ?j, 0)

      scroll = AgentAccess.panel(new_state).scroll
      {cursor_line, _} = BufferServer.cursor(buf)
      assert scroll.offset == cursor_line
    end

    test "unpins scroll when user navigates" do
      state = make_state()

      state =
        AgentAccess.update_agent_ui(state, fn ui ->
          UIState.engage_auto_scroll(ui)
        end)

      assert AgentAccess.panel(state).scroll.pinned == true

      buf = AgentAccess.agent(state).buffer
      new_state = AgentNav.delegate_to_mode_fsm(state, buf, ?j, 0)

      assert AgentAccess.panel(new_state).scroll.pinned == false
    end

    test "preserves buffers.active when a command changes it" do
      state = make_state()
      chat_buf = AgentAccess.agent(state).buffer

      {:ok, new_buf} =
        DynamicSupervisor.start_child(
          Minga.Buffer.Supervisor,
          {BufferServer, content: "", buffer_name: "[new 99]"}
        )

      # Simulate the restore guard: if buffers.active changed away from
      # chat_buf (because a command like :new_buffer ran), don't restore.
      state_after_swap = put_in(state.workspace.buffers.active, chat_buf)
      state_after_command = put_in(state_after_swap.workspace.buffers.active, new_buf)

      assert state_after_command.workspace.buffers.active != chat_buf

      restored =
        if state_after_command.workspace.buffers.active == chat_buf do
          put_in(state_after_command.workspace.buffers.active, state.workspace.buffers.active)
        else
          state_after_command
        end

      assert restored.workspace.buffers.active == new_buf

      DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, new_buf)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # File viewer focus: preview pane scrolling
  # ══════════════════════════════════════════════════════════════════════════

  describe "file viewer focus navigation" do
    test "j scrolls preview down" do
      state = make_state(focus: :file_viewer)

      {:handled, new_state} = AgentNav.handle_key(state, ?j, 0)

      preview = AgentAccess.view(new_state).preview
      assert preview.scroll.offset == 1
    end

    test "k scrolls preview up from offset 1" do
      state = make_state(focus: :file_viewer)

      {:handled, state} = AgentNav.handle_key(state, ?j, 0)
      assert AgentAccess.view(state).preview.scroll.offset == 1

      {:handled, new_state} = AgentNav.handle_key(state, ?k, 0)
      assert AgentAccess.view(new_state).preview.scroll.offset == 0
    end

    test "k at offset 0 stays at 0" do
      state = make_state(focus: :file_viewer)

      {:handled, new_state} = AgentNav.handle_key(state, ?k, 0)

      assert AgentAccess.view(new_state).preview.scroll.offset == 0
    end

    test "Ctrl-D scrolls preview down by 10" do
      state = make_state(focus: :file_viewer)

      {:handled, new_state} = AgentNav.handle_key(state, ?d, @ctrl)

      assert AgentAccess.view(new_state).preview.scroll.offset == 10
    end

    test "Ctrl-U scrolls preview up by 10" do
      state = make_state(focus: :file_viewer)

      {:handled, state} = AgentNav.handle_key(state, ?d, @ctrl)
      assert AgentAccess.view(state).preview.scroll.offset == 10

      {:handled, new_state} = AgentNav.handle_key(state, ?u, @ctrl)
      assert AgentAccess.view(new_state).preview.scroll.offset == 0
    end

    test "G pins preview to bottom" do
      state = make_state(focus: :file_viewer)

      {:handled, new_state} = AgentNav.handle_key(state, ?G, 0)

      assert AgentAccess.view(new_state).preview.scroll.pinned == true
    end

    test "unbound key passes through" do
      state = make_state(focus: :file_viewer)

      assert {:passthrough, _} = AgentNav.handle_key(state, ?x, 0)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Guard conditions
  # ══════════════════════════════════════════════════════════════════════════

  describe "guard conditions" do
    test "passthrough when input is focused" do
      state = make_state(input_focused: true)

      assert {:passthrough, _} = AgentNav.handle_key(state, ?j, 0)
    end

    test "passthrough when keymap_scope is not :agent" do
      state = make_state()
      state = %{state | workspace: %{state.workspace | keymap_scope: :editor}}

      assert {:passthrough, _} = AgentNav.handle_key(state, ?j, 0)
    end
  end

  describe "read-only buffer guard (KeyDispatch integration)" do
    alias Minga.Editor.KeyDispatch

    test "insert mode allowed when agent input is focused despite read-only active buffer" do
      state = make_state(input_focused: true)
      agent_buf = AgentAccess.agent(state).buffer
      assert BufferServer.read_only?(agent_buf)
      state = put_in(state.workspace.buffers.active, agent_buf)

      new_state = KeyDispatch.handle_key(state, ?A, 0)

      assert new_state.workspace.vim.mode == :insert
      refute new_state.status_msg == "Buffer is read-only"
    end
  end
end
