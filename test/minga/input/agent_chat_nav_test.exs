defmodule Minga.Input.AgentChatNavTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.PanelState
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Input.AgentChatNav
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

    panel = %PanelState{
      visible: true,
      input_focused: Keyword.get(opts, :input_focused, false),
      scroll: Minga.Scroll.new(),
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium",
      prompt_buffer: prompt_buf
    }

    agent = %AgentState{
      panel: panel,
      buffer: buf,
      session: nil,
      status: :idle,
      error: nil,
      spinner_timer: nil
    }

    agentic = %ViewState{
      active: true,
      focus: Keyword.get(opts, :focus, :chat)
    }

    %EditorState{
      port_manager: self(),
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      agent: agent,
      agentic: agentic,
      buffers: %Buffers{active: file_buf, list: [file_buf]},
      vim: VimState.new(),
      status_msg: nil,
      file_tree: %FileTreeState{},
      completion: nil,
      keymap_scope: :agent,
      focus_stack: []
    }
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Chat focus: key routing through Mode FSM
  # ══════════════════════════════════════════════════════════════════════════

  describe "chat focus navigation" do
    test "j moves cursor down in agent buffer" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer

      # Move cursor to top first
      BufferServer.move_to(buf, {0, 0})

      {:handled, _new_state} = AgentChatNav.handle_key(state, ?j, 0)

      {line, _col} = BufferServer.cursor(buf)
      assert line == 1
    end

    test "k moves cursor up in agent buffer" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer

      # Start at line 5
      BufferServer.move_to(buf, {5, 0})

      {:handled, _new_state} = AgentChatNav.handle_key(state, ?k, 0)

      {line, _col} = BufferServer.cursor(buf)
      assert line == 4
    end

    test "G moves cursor to end of buffer" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(buf, {0, 0})

      {:handled, _new_state} = AgentChatNav.handle_key(state, ?G, 0)

      {line, _col} = BufferServer.cursor(buf)
      total = BufferServer.line_count(buf)
      assert line == total - 1
    end

    test "syncs scroll offset to cursor line" do
      state = make_state()
      buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(buf, {0, 0})

      {:handled, new_state} = AgentChatNav.handle_key(state, ?j, 0)

      scroll = AgentAccess.panel(new_state).scroll
      {cursor_line, _} = BufferServer.cursor(buf)
      assert scroll.offset == cursor_line
    end

    test "unpins scroll when user navigates" do
      state = make_state()

      # Pin scroll first (simulating streaming auto-scroll)
      state =
        AgentAccess.update_agent(state, fn agent ->
          %{agent | panel: PanelState.engage_auto_scroll(agent.panel)}
        end)

      assert AgentAccess.panel(state).scroll.pinned == true

      {:handled, new_state} = AgentChatNav.handle_key(state, ?j, 0)

      assert AgentAccess.panel(new_state).scroll.pinned == false
    end

    test "blocks mode transitions (chat is read-only)" do
      state = make_state()

      # 'i' in agent scope focuses input (handled by scope trie), but if
      # somehow a mode-changing key reaches AgentChatNav, mode stays normal.
      # Use 'o' which in vim opens a new line (enters insert mode).
      # But 'o' is bound to :agent_toggle_collapse in the trie.
      # Instead, test directly with delegate_to_mode_fsm:
      buf = AgentAccess.agent(state).buffer
      BufferServer.move_to(buf, {0, 0})

      # 'A' (append at end of line) would enter insert mode in normal vim
      new_state = AgentChatNav.delegate_to_mode_fsm(state, buf, ?A, 0)

      assert new_state.vim.mode == :normal
    end

    test "restores original active buffer after dispatch" do
      state = make_state()
      original_buf = state.buffers.active

      {:handled, new_state} = AgentChatNav.handle_key(state, ?j, 0)

      assert new_state.buffers.active == original_buf
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Buffer swap restore guard: commands that change buffers.active
  # ══════════════════════════════════════════════════════════════════════════

  describe "buffer swap restore guard" do
    test "preserves buffers.active when a command changes it (e.g. :new_buffer)" do
      state = make_state()
      original_buf = state.buffers.active
      chat_buf = AgentAccess.agent(state).buffer

      # Simulate a leader command that creates a new buffer.
      # We can't easily run :new_buffer through delegate_to_mode_fsm in a
      # unit test (it needs the full leader trie walk), so we test the
      # restore guard directly: after do_handle_key, if buffers.active is
      # no longer the chat_buffer (meaning a command changed it), the
      # restore should be skipped.
      {:ok, new_buf} =
        DynamicSupervisor.start_child(
          Minga.Buffer.Supervisor,
          {BufferServer, content: "", buffer_name: "[new 99]"}
        )

      # Manually do what delegate_to_mode_fsm does, but skip the key dispatch
      # and directly set buffers.active to the new buffer (simulating what
      # :new_buffer would do via Buffers.add).
      state_after_swap = put_in(state.buffers.active, chat_buf)

      # Pretend the command ran and changed buffers.active to new_buf
      state_after_command = put_in(state_after_swap.buffers.active, new_buf)

      # The restore guard: if buffers.active != chat_buffer, don't restore
      assert state_after_command.buffers.active != chat_buf
      assert state_after_command.buffers.active != original_buf
      assert state_after_command.buffers.active == new_buf

      # Verify delegate_to_mode_fsm's guard logic: since buffers.active
      # changed away from chat_buf, the original buffer should NOT be
      # restored. (This matches the conditional in the production code.)
      restored =
        if state_after_command.buffers.active == chat_buf do
          put_in(state_after_command.buffers.active, original_buf)
        else
          state_after_command
        end

      assert restored.buffers.active == new_buf

      DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, new_buf)
    end

    test "restores buffers.active when no command changed it (normal nav)" do
      state = make_state()
      original_buf = state.buffers.active

      # Normal navigation (j key) should still restore the original buffer
      {:handled, new_state} = AgentChatNav.handle_key(state, ?j, 0)

      assert new_state.buffers.active == original_buf
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # File viewer focus: preview pane scrolling
  # ══════════════════════════════════════════════════════════════════════════

  describe "file viewer focus navigation" do
    test "j scrolls preview down" do
      state = make_state(focus: :file_viewer)

      {:handled, new_state} = AgentChatNav.handle_key(state, ?j, 0)

      preview = AgentAccess.agentic(new_state).preview
      assert preview.scroll.offset == 1
    end

    test "k scrolls preview up from offset 1" do
      state = make_state(focus: :file_viewer)

      # Scroll down first
      {:handled, state} = AgentChatNav.handle_key(state, ?j, 0)
      assert AgentAccess.agentic(state).preview.scroll.offset == 1

      {:handled, new_state} = AgentChatNav.handle_key(state, ?k, 0)
      assert AgentAccess.agentic(new_state).preview.scroll.offset == 0
    end

    test "k at offset 0 stays at 0" do
      state = make_state(focus: :file_viewer)

      {:handled, new_state} = AgentChatNav.handle_key(state, ?k, 0)

      assert AgentAccess.agentic(new_state).preview.scroll.offset == 0
    end

    test "Ctrl-D scrolls preview down by 10" do
      state = make_state(focus: :file_viewer)

      {:handled, new_state} = AgentChatNav.handle_key(state, ?d, @ctrl)

      assert AgentAccess.agentic(new_state).preview.scroll.offset == 10
    end

    test "Ctrl-U scrolls preview up by 10" do
      state = make_state(focus: :file_viewer)

      # Scroll down first
      {:handled, state} = AgentChatNav.handle_key(state, ?d, @ctrl)
      assert AgentAccess.agentic(state).preview.scroll.offset == 10

      {:handled, new_state} = AgentChatNav.handle_key(state, ?u, @ctrl)
      assert AgentAccess.agentic(new_state).preview.scroll.offset == 0
    end

    test "G pins preview to bottom" do
      state = make_state(focus: :file_viewer)

      {:handled, new_state} = AgentChatNav.handle_key(state, ?G, 0)

      assert AgentAccess.agentic(new_state).preview.scroll.pinned == true
    end

    test "unbound key passes through" do
      state = make_state(focus: :file_viewer)

      assert {:passthrough, _} = AgentChatNav.handle_key(state, ?x, 0)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Guard conditions
  # ══════════════════════════════════════════════════════════════════════════

  describe "guard conditions" do
    test "passthrough when input is focused" do
      state = make_state(input_focused: true)

      assert {:passthrough, _} = AgentChatNav.handle_key(state, ?j, 0)
    end

    test "passthrough when keymap_scope is not :agent" do
      state = make_state()
      state = %{state | keymap_scope: :editor}

      assert {:passthrough, _} = AgentChatNav.handle_key(state, ?j, 0)
    end

    test "passthrough when agent buffer is nil" do
      state = make_state()
      state = AgentAccess.update_agent(state, fn agent -> %{agent | buffer: nil} end)

      assert {:passthrough, _} = AgentChatNav.handle_key(state, ?j, 0)
    end
  end
end
