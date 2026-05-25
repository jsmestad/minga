defmodule MingaBoard.Shell.GUIActionTest do
  @moduledoc "Tests for Board GUI action handling without booting the full Editor GenServer."

  # Board GUI actions persist to the user-level board.json path, so this file serializes and redirects HOME per test.
  use ExUnit.Case, async: false

  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle
  alias MingaEditor.Commands.BufferManagement
  alias MingaBoard.Shell
  alias MingaBoard.Shell.State, as: BoardState
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Registry, as: ShellRegistry
  alias MingaEditor.Shell.StateStash
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    old_home = System.get_env("HOME")
    System.put_env("HOME", dir)

    on_exit(fn ->
      restore_env("HOME", old_home)
    end)

    %{workspace: %SessionState{viewport: Viewport.new(24, 80)}}
  end

  describe "handle_event/3" do
    test "background_subagent_started creates an inspectable board card", %{workspace: workspace} do
      handle = background_handle()

      {board, _workspace} =
        Shell.handle_event(BoardState.new(), workspace, {:background_subagent_started, handle})

      [card] = BoardState.sorted_cards(board)
      assert card.session == self()
      assert card.task =~ "session-42"
      assert card.task =~ "audit async renderer"
      assert card.model == "test-model"
      assert card.status == :working
      assert card.kind == :agent
      assert is_map(card.workspace)
    end

    test "background_subagent_started is idempotent per session pid", %{workspace: workspace} do
      handle = background_handle()

      {board, workspace} =
        Shell.handle_event(BoardState.new(), workspace, {:background_subagent_started, handle})

      {board, _workspace} =
        Shell.handle_event(board, workspace, {:background_subagent_started, handle})

      assert [_card] = BoardState.sorted_cards(board)
    end
  end

  describe "GuiActionHandler.dispatch/2" do
    setup do
      ShellRegistry.reset_for_test()
      ShellRegistry.seed_builtin()

      :ok = MingaBoard.Feature.register_contributions()

      on_exit(fn ->
        ShellRegistry.reset_for_test()
        ShellRegistry.seed_builtin()
        MingaBoard.Feature.register_contributions()
      end)

      :ok
    end

    test "observatory sidebar action does not crash while Board is active", %{
      workspace: workspace
    } do
      state = %EditorState{
        port_manager: self(),
        workspace: workspace,
        shell_id: :board,
        shell: Shell,
        shell_identity: MingaEditor.Shell.Identity.new(ShellRegistry.get(:board)),
        shell_state: BoardState.new()
      }

      new_state =
        GuiActionHandler.dispatch(
          state,
          {:sidebar_action, "observatory", "observatory", "activate"}
        )

      assert new_state.shell_id == :board
      assert is_boolean(new_state.shell_state.observatory_visible)
    end

    test "agent_dismiss clears stale shell agent cache after GUI zoom out", %{
      workspace: workspace
    } do
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "Agent", session: self())
      board = BoardState.zoom_into(board, card.id, SessionState.to_tab_context(workspace))

      stale_agent =
        board.agent
        |> AgentState.set_status(:thinking)
        |> AgentState.set_error("stale")

      board = %{board | agent: stale_agent}

      state = %EditorState{
        port_manager: self(),
        workspace: %{workspace | keymap_scope: :agent},
        shell_id: :board,
        shell: Shell,
        shell_identity: MingaEditor.Shell.Identity.new(ShellRegistry.get(:board)),
        shell_state: board
      }

      dismissed = GuiActionHandler.dispatch(state, :agent_dismiss)

      assert dismissed.shell_state.zoomed_into == nil
      assert dismissed.shell_state.agent.runtime.status == :idle
      assert dismissed.shell_state.agent.error == nil
    end

    test "routes board card selection through the active extension shell", %{workspace: workspace} do
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "Agent")
      {:ok, agent_buf} = Minga.Buffer.start_link(content: "")
      board = %{board | agent: %AgentState{buffer: agent_buf}}

      state = %EditorState{
        port_manager: self(),
        workspace: workspace,
        shell_id: :board,
        shell: Shell,
        shell_identity: MingaEditor.Shell.Identity.new(ShellRegistry.get(:board)),
        shell_state: board
      }

      dispatched = GuiActionHandler.dispatch(state, {:board_select_card, card.id})
      selected_card = dispatched.shell_state.cards[card.id]
      selected_session = selected_card.session
      on_exit(fn -> stop_session(selected_session) end)

      assert dispatched.shell_state.focused_card == card.id
      assert dispatched.shell_state.zoomed_into == card.id
      assert dispatched.workspace.keymap_scope == :agent

      assert {:agent_chat, ^selected_session} =
               EditorState.active_window_struct(dispatched).content
    end
  end

  describe "stashed Board session lifecycle" do
    test "agent session down updates stashed Board cards", %{workspace: workspace} do
      session = self()
      {board, card} = BoardState.create_card(BoardState.new(), task: "Agent", session: session)
      state = traditional_state_with_stashed_board(workspace, board)

      new_state = BufferManagement.handle_agent_session_down(state, session, :killed)
      board = new_state.shell_state_stash[:board].state
      card = board.cards[card.id]

      assert card.status == :errored
      assert card.session == nil
      assert EditorState.status_msg(new_state) == "Agent session crashed"
    end

    test "remote disconnect updates stashed Board cards", %{workspace: workspace} do
      session = self()

      {board, card} =
        BoardState.new()
        |> BoardState.create_card(task: "Agent", session: session)

      state = traditional_state_with_stashed_board(workspace, board)

      new_state = BufferManagement.handle_agent_session_down(state, session, :noconnection)
      board = new_state.shell_state_stash[:board].state
      card = board.cards[card.id]

      assert card.connection_status == :disconnected
      assert EditorState.status_msg(new_state) == "Remote agent disconnected, reconnecting..."
    end
  end

  describe "handle_gui_action/3" do
    test "board_dispatch_agent starts a managed subscribed session without sending the task", %{
      workspace: workspace
    } do
      {board, _workspace} =
        Shell.handle_gui_action(
          BoardState.new(),
          workspace,
          {:board_dispatch_agent, "Fix bug", "test-model"}
        )

      [card] = BoardState.sorted_cards(board)
      on_exit(fn -> stop_session(card.session) end)

      assert card.task == "Fix bug"
      assert card.model == "test-model"
      session_pid = card.session
      assert card.status == :working
      assert is_pid(session_pid)
      assert {:ok, _session_id} = SessionManager.session_id_for_pid(session_pid)
      refute Enum.any?(Session.messages(session_pid), &(&1 == {:user, "Fix bug"}))

      Session.add_system_message(session_pid, "subscribed")
      assert_receive {:agent_event, ^session_pid, :messages_changed}
    end

    test "board_dispatch_agent reports session startup failure", %{workspace: workspace} do
      original_pid = unregister_session_manager()

      try do
        {board, _workspace} =
          Shell.handle_gui_action(
            BoardState.new(),
            workspace,
            {:board_dispatch_agent, "Fix bug", "test-model"}
          )

        state = %EditorState{
          port_manager: self(),
          workspace: workspace,
          shell_id: :board,
          shell: Shell,
          shell_identity: MingaEditor.Shell.Identity.new(ShellRegistry.get(:board)),
          shell_state: board
        }

        new_state =
          Shell.after_gui_action(state, {:board_dispatch_agent, "Fix bug", "test-model"})

        [card] = BoardState.sorted_cards(new_state.shell_state)

        assert card.status == :errored
        assert EditorState.status_msg(new_state) == "Could not start Board agent session"
      after
        restore_session_manager(original_pid)
      end
    end

    test "board_close_card keeps the required You card", %{workspace: workspace} do
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "You", kind: :you)

      {new_board, _workspace} =
        Shell.handle_gui_action(board, workspace, {:board_close_card, card.id})

      assert Map.has_key?(new_board.cards, card.id)
      assert new_board.cards[card.id].kind == :you
    end

    test "board_close_card keeps and marks a card errored when session stop fails", %{
      workspace: workspace
    } do
      session_pid = self()
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "Agent", session: session_pid)

      original_pid = unregister_session_manager()

      try do
        {new_board, _workspace} =
          Shell.handle_gui_action(board, workspace, {:board_close_card, card.id})

        assert Map.has_key?(new_board.cards, card.id)
        assert new_board.cards[card.id].status == :errored
      after
        restore_session_manager(original_pid)
      end
    end

    test "board_close_card stops the managed session attached to the card", %{
      workspace: workspace
    } do
      {:ok, _session_id, session_pid} = SessionManager.start_session([])
      on_exit(fn -> stop_session(session_pid) end)
      ref = Process.monitor(session_pid)

      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "Agent", session: session_pid)

      {board, _workspace} =
        Shell.handle_gui_action(board, workspace, {:board_close_card, card.id})

      refute Map.has_key?(board.cards, card.id)
      assert_receive {:DOWN, ^ref, :process, ^session_pid, _reason}
      assert SessionManager.session_id_for_pid(session_pid) == {:error, :not_found}
    end

    test "after_gui_action reports when the selected card disappeared", %{workspace: workspace} do
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "Agent")
      board = BoardState.remove_card(board, card.id)

      state = %EditorState{
        port_manager: self(),
        workspace: workspace,
        shell_id: :board,
        shell: Shell,
        shell_identity: MingaEditor.Shell.Identity.new(ShellRegistry.get(:board)),
        shell_state: board
      }

      new_state = Shell.after_gui_action(state, {:board_select_card, card.id})

      assert EditorState.status_msg(new_state) == "Board card is unavailable"
    end

    test "board_select_card reports session startup failure without staying zoomed", %{
      workspace: workspace
    } do
      saved_card_workspace = %SessionState{viewport: Viewport.new(12, 40)}
      board = BoardState.new()

      {board, card} =
        BoardState.create_card(board,
          task: "Agent",
          workspace: SessionState.to_tab_context(saved_card_workspace)
        )

      original_pid = unregister_session_manager()

      try do
        {board, workspace} =
          Shell.handle_gui_action(board, workspace, {:board_select_card, card.id})

        state = %EditorState{
          port_manager: self(),
          workspace: workspace,
          shell_id: :board,
          shell: Shell,
          shell_identity: MingaEditor.Shell.Identity.new(ShellRegistry.get(:board)),
          shell_state: board
        }

        new_state = Shell.after_gui_action(state, {:board_select_card, card.id})

        assert new_state.shell_state.zoomed_into == nil
        assert new_state.shell_state.cards[card.id].session == nil
        assert new_state.shell_state.cards[card.id].workspace.viewport.rows == 12
        assert new_state.workspace.viewport.rows == 24
        assert AgentAccess.session(new_state) == nil
        assert EditorState.status_msg(new_state) == "Could not start Board agent session"
      after
        restore_session_manager(original_pid)
      end
    end

    test "board_select_card ignores stale card ids without entering zoom", %{workspace: workspace} do
      board = BoardState.new()

      {new_board, new_workspace} =
        Shell.handle_gui_action(board, workspace, {:board_select_card, 999})

      assert new_board == board
      assert new_workspace == workspace
    end

    test "board_select_card snapshots normalized workspace context and restores the card context",
         %{
           workspace: workspace
         } do
      transient_vim = %VimState{mode: :normal, mode_state: %Minga.Mode.CommandState{}}
      workspace = %{workspace | editing: transient_vim}
      previous_workspace = %SessionState{viewport: Viewport.new(10, 20), keymap_scope: :agent}
      board = BoardState.new()

      {board, card} =
        BoardState.create_card(board,
          task: "Agent",
          workspace: SessionState.to_tab_context(previous_workspace)
        )

      {board, restored_workspace} =
        Shell.handle_gui_action(board, workspace, {:board_select_card, card.id})

      zoomed = board.cards[card.id]
      assert board.focused_card == card.id
      assert board.zoomed_into == card.id
      assert %Context{} = zoomed.workspace
      assert zoomed.workspace.editing.mode == :normal
      assert %Minga.Mode.State{} = zoomed.workspace.editing.mode_state
      assert restored_workspace.viewport.rows == 10
      assert restored_workspace.viewport.cols == 20
      assert restored_workspace.keymap_scope == :agent
    end
  end

  defp traditional_state_with_stashed_board(workspace, board) do
    %EditorState{
      port_manager: self(),
      workspace: workspace,
      shell_id: :traditional,
      shell: MingaEditor.Shell.Traditional,
      shell_identity: MingaEditor.Shell.Identity.new(ShellRegistry.get(:traditional)),
      shell_state: %MingaEditor.Shell.Traditional.State{},
      shell_state_stash: %{
        board: StateStash.new(ShellRegistry.get(:board), board)
      }
    }
  end

  defp unregister_session_manager do
    original_pid = Process.whereis(MingaAgent.SessionManager)
    if original_pid, do: Process.unregister(MingaAgent.SessionManager)
    original_pid
  end

  defp restore_session_manager(nil), do: :ok

  defp restore_session_manager(pid) do
    if Process.alive?(pid) && Process.whereis(MingaAgent.SessionManager) == nil do
      try do
        Process.register(pid, MingaAgent.SessionManager)
      rescue
        ArgumentError -> :ok
      end
    else
      :ok
    end
  end

  defp background_handle do
    Handle.new(
      session_id: "session-42",
      pid: self(),
      task: "audit async renderer",
      model: "test-model"
    )
  end

  defp stop_session(pid) when is_pid(pid) do
    SessionManager.stop_session_by_pid(pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_session(_pid), do: :ok

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
