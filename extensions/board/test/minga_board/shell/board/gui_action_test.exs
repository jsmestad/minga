defmodule MingaBoard.Shell.GUIActionTest do
  @moduledoc "Tests for Board GUI action handling without booting the full Editor GenServer."

  # Board GUI actions persist to the user-level board.json path, so this file serializes and redirects HOME per test.
  use ExUnit.Case, async: false

  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle
  alias MingaBoard.Shell
  alias MingaBoard.Shell.State, as: BoardState
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Session.State, as: SessionState

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
      handle =
        Handle.new(
          session_id: "session-42",
          pid: self(),
          task: "audit async renderer",
          model: "test-model"
        )

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

  defp stop_session(pid) when is_pid(pid) do
    SessionManager.stop_session_by_pid(pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_session(_pid), do: :ok

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
