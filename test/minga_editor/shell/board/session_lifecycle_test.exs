defmodule MingaEditor.Shell.Board.SessionLifecycleTest do
  # Serial because one test temporarily unregisters the global MingaAgent.SessionManager.
  use ExUnit.Case, async: false

  alias MingaAgent.SessionManager
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.Shell.Board
  alias MingaEditor.Shell.Board.Input, as: BoardInput
  alias MingaEditor.Shell.Board.SessionLifecycle
  alias MingaEditor.Shell.Board.State, as: BoardState

  defp stop_session(pid) when is_pid(pid) do
    SessionManager.stop_session_by_pid(pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_session(_pid), do: :ok

  defp make_state(board) do
    %EditorState{
      port_manager: self(),
      shell: Board,
      shell_state: board,
      workspace: %MingaEditor.Session.State{viewport: Viewport.new(24, 80)},
      focus_stack: [BoardInput, MingaEditor.Input.GlobalBindings]
    }
  end

  describe "ensure_session/3" do
    test "no-ops for nil card" do
      board = BoardState.new()
      state = make_state(board)

      assert {^board, ^state} = SessionLifecycle.ensure_session(board, nil, state)
    end

    test "no-ops for :you card" do
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "You", kind: :you)
      state = make_state(board)

      assert {^board, ^state} = SessionLifecycle.ensure_session(board, card, state)
    end

    test "no-ops when card already has a session" do
      fake_pid = self()
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "Agent", session: fake_pid)
      state = make_state(board)

      assert {^board, ^state} = SessionLifecycle.ensure_session(board, card, state)
    end

    test "starts a new session for a sessionless agent card" do
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "Fix bug", model: "test-model")
      state = make_state(board)

      assert card.session == nil

      {new_board, _state} = SessionLifecycle.ensure_session(board, card, state)

      updated_card = new_board.cards[card.id]
      on_exit(fn -> stop_session(updated_card.session) end)

      assert is_pid(updated_card.session)
      assert updated_card.status == :working
    end

    test "uses card model when present" do
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "Task", model: "custom-model")
      state = make_state(board)

      {new_board, _state} = SessionLifecycle.ensure_session(board, card, state)

      updated_card = new_board.cards[card.id]
      on_exit(fn -> stop_session(updated_card.session) end)

      assert is_pid(updated_card.session)
    end

    @tag :tmp_dir
    test "sets :errored status when session start fails", %{tmp_dir: _dir} do
      board = BoardState.new()
      {board, card} = BoardState.create_card(board, task: "Will fail", model: "test-model")
      state = make_state(board)

      # Temporarily unregister the SessionManager to make GenServer.call exit
      original_pid = Process.whereis(MingaAgent.SessionManager)
      Process.unregister(MingaAgent.SessionManager)

      on_exit(fn ->
        if original_pid && Process.alive?(original_pid) do
          try do
            Process.register(original_pid, MingaAgent.SessionManager)
          rescue
            ArgumentError -> :ok
          end
        end
      end)

      {new_board, _state} = SessionLifecycle.ensure_session(board, card, state)

      # Re-register immediately so other tests aren't affected
      Process.register(original_pid, MingaAgent.SessionManager)

      updated_card = new_board.cards[card.id]
      assert updated_card.session == nil
      assert updated_card.status == :errored
    end
  end
end
