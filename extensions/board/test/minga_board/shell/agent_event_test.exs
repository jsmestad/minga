defmodule MingaBoard.Shell.AgentEventTest do
  use ExUnit.Case, async: true

  alias MingaBoard.Shell
  alias MingaBoard.Shell.Card
  alias MingaBoard.Shell.State, as: BoardState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  defp workspace, do: %SessionState{viewport: Viewport.new(24, 80), editing: VimState.new()}

  defp fake_session_pid do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
    pid
  end

  describe "on_agent_event/4" do
    setup do
      session_a = fake_session_pid()
      session_b = fake_session_pid()

      board = BoardState.new()
      {board, _card_a} = BoardState.create_card(board, task: "A", session: session_a)
      {board, _card_b} = BoardState.create_card(board, task: "B", session: session_b)

      %{board: board, session_b: session_b}
    end

    test "background :status_changed maps the agent status onto the card vocabulary", %{
      board: board,
      session_b: session_b
    } do
      {board2, _ws, _effects} =
        Shell.on_agent_event(board, workspace(), session_b, {:status_changed, :thinking})

      [card_b] = Enum.filter(Map.values(board2.cards), &(&1.session == session_b))
      assert card_b.status == :working

      [card_a] = Enum.filter(Map.values(board2.cards), &(&1.task == "A"))
      assert card_a.status == :idle
    end

    test "background :approval_pending transitions the owning card to :needs_you", %{
      board: board,
      session_b: session_b
    } do
      {board2, _ws, _effects} =
        Shell.on_agent_event(board, workspace(), session_b, {:approval_pending, %{name: "shell"}})

      [card_b] = Enum.filter(Map.values(board2.cards), &(&1.session == session_b))
      assert card_b.status == :needs_you
    end

    test "background :error transitions the owning card to :errored", %{
      board: board,
      session_b: session_b
    } do
      {board2, _ws, _effects} =
        Shell.on_agent_event(board, workspace(), session_b, {:error, "boom"})

      [card_b] = Enum.filter(Map.values(board2.cards), &(&1.session == session_b))
      assert card_b.status == :errored
    end

    test "background :file_changed tracks recent files on the owning card", %{
      board: board,
      session_b: session_b
    } do
      {board2, _ws, _effects} =
        Shell.on_agent_event(
          board,
          workspace(),
          session_b,
          {:file_changed, "/tmp/project/lib/example.ex", "before", "after", "tool-1", "edit"}
        )

      [card_b] = Enum.filter(Map.values(board2.cards), &(&1.session == session_b))
      assert card_b.recent_files == ["example.ex"]
    end

    test "events for a session not attached to any card are silently dropped", %{board: board} do
      ghost = spawn(fn -> :ok end)

      {board2, _ws, _effects} =
        Shell.on_agent_event(board, workspace(), ghost, {:approval_pending, %{}})

      assert board2 == board
    end
  end

  describe "Card.from_agent_status/1" do
    test "maps every documented agent status" do
      assert Card.from_agent_status(:thinking) == :working
      assert Card.from_agent_status(:tool_executing) == :iterating
      assert Card.from_agent_status(:error) == :errored
      assert Card.from_agent_status(:idle) == :done
    end

    test "unknown atoms fall back to :idle" do
      assert Card.from_agent_status(nil) == :idle
      assert Card.from_agent_status(:something_else) == :idle
    end
  end
end
