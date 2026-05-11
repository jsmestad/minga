defmodule MingaEditor.Shell.Board.InputTest do
  @moduledoc """
  Tests for Board input handlers: grid navigation, zoom in/out, dispatch.

  Follows the Dashboard test pattern: builds a minimal EditorState with
  Board shell state and calls handler functions directly. No GenServer.
  """
  use ExUnit.Case, async: true

  alias MingaAgent.RuntimeState
  alias MingaAgent.SessionManager
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.Viewport
  alias MingaEditor.Window.Content
  alias MingaEditor.Shell.Board
  alias MingaEditor.Shell.Board.Input, as: BoardInput
  alias MingaEditor.Shell.Board.State, as: BoardState
  alias MingaEditor.Shell.Board.ZoomOut

  # ── Key constants ──────────────────────────────────────────────────────

  @arrow_down 57_353
  @arrow_right 57_351
  @enter 13
  @escape 27

  # ── Helpers ────────────────────────────────────────────────────────────

  defp board_state_with_cards(0), do: BoardState.new()

  defp board_state_with_cards(count) when count > 0 do
    Enum.reduce(1..count, BoardState.new(), fn i, acc ->
      {acc, _card} = BoardState.create_card(acc, task: "Task #{i}")
      acc
    end)
  end

  defp editor_with_board(card_count) do
    board = board_state_with_cards(card_count)

    %EditorState{
      port_manager: self(),
      shell: Board,
      shell_state: board,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80)
      },
      focus_stack: [BoardInput, MingaEditor.Input.GlobalBindings]
    }
  end

  defp editor_zoomed_into(card_count, card_id) do
    state = editor_with_board(card_count)
    board = BoardState.zoom_into(state.shell_state, card_id, %{fake: :workspace})
    %{state | shell_state: board}
  end

  defp stop_session(pid) when is_pid(pid) do
    SessionManager.stop_session_by_pid(pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_session(_pid), do: :ok

  # ── Grid navigation ────────────────────────────────────────────────────

  describe "grid navigation" do
    test "j / arrow down moves focus down" do
      state = editor_with_board(4)
      first_id = state.shell_state.focused_card

      {:handled, new_state} = BoardInput.handle_key(state, ?j, 0)
      assert new_state.shell_state.focused_card != first_id

      # Arrow down does the same thing
      state2 = editor_with_board(4)
      {:handled, new_state2} = BoardInput.handle_key(state2, @arrow_down, 0)
      assert new_state2.shell_state.focused_card == new_state.shell_state.focused_card
    end

    test "k / arrow up moves focus up" do
      state = editor_with_board(4)
      # Focus the second card first
      board = BoardState.focus_card(state.shell_state, 2)
      state = %{state | shell_state: board}

      {:handled, new_state} = BoardInput.handle_key(state, ?k, 0)
      assert new_state.shell_state.focused_card == 1
    end

    test "l / arrow right moves focus right" do
      state = editor_with_board(4)

      {:handled, new_state} = BoardInput.handle_key(state, ?l, 0)
      assert new_state.shell_state.focused_card == 2

      # Arrow does the same
      state2 = editor_with_board(4)
      {:handled, new_state2} = BoardInput.handle_key(state2, @arrow_right, 0)
      assert new_state2.shell_state.focused_card == 2
    end

    test "h / arrow left moves focus left" do
      state = editor_with_board(4)
      board = BoardState.focus_card(state.shell_state, 2)
      state = %{state | shell_state: board}

      {:handled, new_state} = BoardInput.handle_key(state, ?h, 0)
      assert new_state.shell_state.focused_card == 1
    end

    test "navigation clamps at boundaries" do
      state = editor_with_board(1)

      {:handled, new_state} = BoardInput.handle_key(state, ?j, 0)
      assert new_state.shell_state.focused_card == 1

      {:handled, new_state} = BoardInput.handle_key(state, ?h, 0)
      assert new_state.shell_state.focused_card == 1
    end
  end

  # ── Zoom in ────────────────────────────────────────────────────────────

  describe "Enter zooms into focused card" do
    test "sets zoomed_into on the board state" do
      state = editor_with_board(3)
      focused_id = state.shell_state.focused_card

      {:handled, new_state} = BoardInput.handle_key(state, @enter, 0)
      assert new_state.shell_state.zoomed_into == focused_id
    end

    test "no-ops when no card is focused" do
      state = editor_with_board(0)
      # Empty board, no focus
      assert state.shell_state.focused_card == nil

      {:handled, new_state} = BoardInput.handle_key(state, @enter, 0)
      assert new_state.shell_state.zoomed_into == nil
    end

    test "first-time zoom into agent card builds fresh workspace and activates agent view" do
      # Set up a board with one agent card that has a session but no workspace.
      # The shell carries the agent buffer pid that the bootstrap helper uses
      # to construct the agent-chat window.
      fake_session = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, agent_buf} = Minga.Buffer.start_link(content: "")

      board =
        BoardState.new()
        |> then(fn b ->
          {b, _card} = BoardState.create_card(b, task: "Agent 1", session: fake_session)
          b
        end)
        |> Map.put(:agent, %AgentState{buffer: agent_buf})

      # Ensure the focused card has workspace: nil (first-time zoom)
      focused_id = board.focused_card
      assert board.cards[focused_id].workspace == nil

      # Start state has the grid's empty windows; the bootstrap helper
      # replaces them with a fresh agent-chat window.
      state = %EditorState{
        port_manager: self(),
        shell: Board,
        shell_state: board,
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        focus_stack: [BoardInput, MingaEditor.Input.GlobalBindings]
      }

      {:handled, new_state} = BoardInput.handle_key(state, @enter, 0)

      # Bootstrap should have set the agent keymap scope...
      assert new_state.workspace.keymap_scope == :agent

      # ...and the active window must now be an agent-chat window backed by
      # the card's session pid (set by AgentActivation, not the bootstrap).
      active_win = new_state.workspace.windows.map[new_state.workspace.windows.active]
      assert Content.agent_chat?(active_win.content)
      assert active_win.content == Content.agent_chat(fake_session)
      assert active_win.pinned == true
    end

    test "first-time zoom matches re-zoom shape (modulo prompt content)" do
      # The acceptance criterion: first-zoom and re-zoom land in the same
      # workspace shape — agent scope, agent-chat window, fresh agent_ui.
      fake_session = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, agent_buf} = Minga.Buffer.start_link(content: "")

      board =
        BoardState.new()
        |> then(fn b ->
          {b, _card} = BoardState.create_card(b, task: "Agent 1", session: fake_session)
          b
        end)
        |> Map.put(:agent, %AgentState{buffer: agent_buf})

      state = %EditorState{
        port_manager: self(),
        shell: Board,
        shell_state: board,
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        focus_stack: [BoardInput, MingaEditor.Input.GlobalBindings]
      }

      # First zoom: bootstrap path
      {:handled, after_first_zoom} = BoardInput.handle_key(state, @enter, 0)

      # Zoom out then back in: snapshot/restore path
      {:handled, after_zoom_out} = ZoomOut.handle_key(after_first_zoom, @escape, 0)
      {:handled, after_second_zoom} = BoardInput.handle_key(after_zoom_out, @enter, 0)

      # Both zoom-ins should produce the same shape.
      assert after_first_zoom.workspace.keymap_scope ==
               after_second_zoom.workspace.keymap_scope

      first_win =
        after_first_zoom.workspace.windows.map[after_first_zoom.workspace.windows.active]

      second_win =
        after_second_zoom.workspace.windows.map[after_second_zoom.workspace.windows.active]

      assert Content.agent_chat?(first_win.content)
      assert Content.agent_chat?(second_win.content)
      assert first_win.content == second_win.content
    end
  end

  # ── Persisted card session start ─────────────────────────────────────────

  describe "zoom into persisted agent card (no live session)" do
    test "starts a new session and activates the agent view" do
      {:ok, agent_buf} = Minga.Buffer.start_link(content: "")

      board =
        BoardState.new()
        |> then(fn b ->
          {b, _card} = BoardState.create_card(b, task: "Fix tests", model: "test-model")
          b
        end)
        |> Map.put(:agent, %AgentState{buffer: agent_buf})

      focused_id = board.focused_card
      assert board.cards[focused_id].session == nil

      state = %EditorState{
        port_manager: self(),
        shell: Board,
        shell_state: board,
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        focus_stack: [BoardInput, MingaEditor.Input.GlobalBindings]
      }

      {:handled, new_state} = BoardInput.handle_key(state, @enter, 0)

      card = new_state.shell_state.cards[focused_id]
      on_exit(fn -> stop_session(card.session) end)

      assert is_pid(card.session)
      assert card.status == :working
      assert new_state.workspace.keymap_scope == :agent
    end

    test "uses the card's persisted model for the new session" do
      {:ok, agent_buf} = Minga.Buffer.start_link(content: "")

      board =
        BoardState.new()
        |> then(fn b ->
          {b, _card} = BoardState.create_card(b, task: "Refactor", model: "persisted-model")
          b
        end)
        |> Map.put(:agent, %AgentState{buffer: agent_buf})

      state = %EditorState{
        port_manager: self(),
        shell: Board,
        shell_state: board,
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        focus_stack: [BoardInput, MingaEditor.Input.GlobalBindings]
      }

      {:handled, new_state} = BoardInput.handle_key(state, @enter, 0)

      focused_id = new_state.shell_state.focused_card
      card = new_state.shell_state.cards[focused_id]
      on_exit(fn -> stop_session(card.session) end)

      assert is_pid(card.session)
    end

    test "does not double-start when card already has a session" do
      {:ok, agent_buf} = Minga.Buffer.start_link(content: "")
      fake_session = spawn(fn -> Process.sleep(:infinity) end)

      board =
        BoardState.new()
        |> then(fn b ->
          {b, _card} =
            BoardState.create_card(b,
              task: "Already running",
              model: "test-model",
              session: fake_session
            )

          b
        end)
        |> Map.put(:agent, %AgentState{buffer: agent_buf})

      focused_id = board.focused_card

      state = %EditorState{
        port_manager: self(),
        shell: Board,
        shell_state: board,
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        focus_stack: [BoardInput, MingaEditor.Input.GlobalBindings]
      }

      {:handled, new_state} = BoardInput.handle_key(state, @enter, 0)

      card = new_state.shell_state.cards[focused_id]
      assert card.session == fake_session
    end
  end

  # ── Zoom out ───────────────────────────────────────────────────────────

  describe "Escape zooms out when zoomed" do
    test "clears zoomed_into and snapshots workspace" do
      state = editor_zoomed_into(3, 1)
      assert state.shell_state.zoomed_into == 1

      {:handled, new_state} = ZoomOut.handle_key(state, @escape, 0)
      assert new_state.shell_state.zoomed_into == nil
      # Workspace was stored on the card
      assert new_state.shell_state.cards[1].workspace != nil
    end

    test "active agent session goes out of scope on zoom-out" do
      # The session pid lives on the zoomed card. While zoomed, AgentAccess.session/1
      # returns it; after zoom-out the card is no longer "the active view"
      # (zoomed_into == nil), so active_session/1 reports nil. The session
      # itself is not killed; the card retains its pid for the next zoom-in.
      state = editor_zoomed_into(3, 1)
      fake_pid = spawn(fn -> Process.sleep(:infinity) end)

      board =
        BoardState.update_card(state.shell_state, 1, fn card ->
          MingaEditor.Shell.Board.Card.attach_session(card, fake_pid)
        end)

      state = %{state | shell_state: board}
      assert AgentAccess.session(state) == fake_pid

      {:handled, new_state} = ZoomOut.handle_key(state, @escape, 0)
      assert new_state.shell_state.zoomed_into == nil
      assert AgentAccess.session(new_state) == nil
      # The card still holds the pid so a subsequent zoom-in restores it.
      assert new_state.shell_state.cards[1].session == fake_pid
    end

    test "zoom-out clears the agent rendering cache so the grid view starts idle" do
      # Card A is zoomed in with a busy/errored agent state cached on the
      # shell. Zooming out must reset the cache so the grid isn't showing
      # card A's status, error, or pending approval.
      board =
        BoardState.new()
        |> then(fn b ->
          {b, _card} = BoardState.create_card(b, task: "Agent A")
          b
        end)
        |> Map.put(:agent, %AgentState{
          runtime: %RuntimeState{status: :thinking},
          error: "boom",
          pending_approval: %{kind: :tool, name: "fake"}
        })

      board = BoardState.zoom_into(board, board.focused_card, %{fake: :grid_workspace})

      state = %EditorState{
        port_manager: self(),
        shell: Board,
        shell_state: board,
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        focus_stack: [ZoomOut, MingaEditor.Input.GlobalBindings]
      }

      {:handled, new_state} = ZoomOut.handle_key(state, @escape, 0)

      agent = AgentAccess.agent(new_state)
      assert agent.runtime.status == :idle
      assert agent.error == nil
      assert agent.pending_approval == nil
    end

    test "zoom A → out → zoom B does not leak A's session into B's rendering cache" do
      # Two cards with distinct sessions. After zooming through A and into
      # B, the active session must report as B's pid (no leak from A).
      session_a = spawn(fn -> Process.sleep(:infinity) end)
      session_b = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, agent_buf} = Minga.Buffer.start_link(content: "")

      board =
        BoardState.new()
        |> then(fn b ->
          {b, _card_a} = BoardState.create_card(b, task: "A", session: session_a)
          b
        end)
        |> then(fn b ->
          {b, _card_b} = BoardState.create_card(b, task: "B", session: session_b)
          b
        end)
        |> Map.put(:agent, %AgentState{buffer: agent_buf})

      state = %EditorState{
        port_manager: self(),
        shell: Board,
        shell_state: board,
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        focus_stack: [BoardInput, ZoomOut, MingaEditor.Input.GlobalBindings]
      }

      # Focus A, zoom in.
      board = BoardState.focus_card(state.shell_state, 1)
      state = %{state | shell_state: board}
      {:handled, state} = BoardInput.handle_key(state, @enter, 0)
      assert AgentAccess.session(state) == session_a

      # Zoom out: cache reset, grid view has no active session.
      {:handled, state} = ZoomOut.handle_key(state, @escape, 0)
      assert AgentAccess.session(state) == nil

      # Focus B, zoom in. The active session must be B, not A.
      board = BoardState.focus_card(state.shell_state, 2)
      state = %{state | shell_state: board}
      {:handled, state} = BoardInput.handle_key(state, @enter, 0)
      assert AgentAccess.session(state) == session_b

      # The cards still hold their original sessions.
      assert state.shell_state.cards[1].session == session_a
      assert state.shell_state.cards[2].session == session_b
    end

    test "passes through when not zoomed" do
      state = editor_with_board(3)
      assert state.shell_state.zoomed_into == nil

      {:passthrough, _state} = ZoomOut.handle_key(state, @escape, 0)
    end

    test "passes through for non-Escape keys when zoomed" do
      state = editor_zoomed_into(3, 1)

      {:passthrough, _state} = ZoomOut.handle_key(state, ?a, 0)
    end
  end

  # ── New card dispatch ──────────────────────────────────────────────────

  describe "n creates and zooms into new card" do
    test "creates a new card, starts a managed agent session, and auto-zooms" do
      state = editor_with_board(2)
      initial_count = BoardState.card_count(state.shell_state)

      {:handled, new_state} = BoardInput.handle_key(state, ?n, 0)
      assert BoardState.card_count(new_state.shell_state) == initial_count + 1
      assert new_state.shell_state.zoomed_into != nil

      new_card_id = new_state.shell_state.zoomed_into
      card = new_state.shell_state.cards[new_card_id]
      on_exit(fn -> stop_session(card.session) end)

      assert card.model != nil
      assert is_pid(card.session)
      assert {:ok, _session_id} = SessionManager.session_id_for_pid(card.session)
      refute Map.has_key?(new_state.buffer_monitors, card.session)
    end
  end

  # ── Delete card ─────────────────────────────────────────────────────────

  describe "d deletes focused card" do
    test "removes the focused agent card" do
      state = editor_with_board(3)
      # Focus the second card (not the "You" card placeholder)
      board = BoardState.focus_card(state.shell_state, 2)
      state = %{state | shell_state: board}

      initial_count = BoardState.card_count(state.shell_state)
      {:handled, new_state} = BoardInput.handle_key(state, ?d, 0)
      assert BoardState.card_count(new_state.shell_state) == initial_count - 1
    end

    test "stops the managed session attached to the deleted card" do
      {:ok, _session_id, session_pid} = SessionManager.start_session([])
      on_exit(fn -> stop_session(session_pid) end)

      state = editor_with_board(1)

      board =
        BoardState.update_card(state.shell_state, 1, fn card ->
          MingaEditor.Shell.Board.Card.attach_session(card, session_pid)
        end)

      state = %{state | shell_state: board}

      {:handled, new_state} = BoardInput.handle_key(state, ?d, 0)

      assert BoardState.card_count(new_state.shell_state) == 0
      assert SessionManager.session_id_for_pid(session_pid) == {:error, :not_found}
    end
  end

  # ── Filter ─────────────────────────────────────────────────────────────

  describe "filter mode" do
    test "routes filter edits through BoardState operations" do
      state = editor_with_board(3)

      {:handled, state} = BoardInput.handle_key(state, ?/, 0)
      assert state.shell_state.filter_mode == true
      assert state.shell_state.filter_text == ""

      {:handled, state} = BoardInput.handle_key(state, ?T, 0)
      {:handled, state} = BoardInput.handle_key(state, ?2, 0)
      assert state.shell_state.filter_text == "T2"

      {:handled, state} = BoardInput.handle_key(state, @arrow_down, 0)
      assert state.shell_state.filter_text == "T2"

      {:handled, state} = BoardInput.handle_key(state, 127, 0)
      assert state.shell_state.filter_text == "T"

      {:handled, state} = BoardInput.handle_key(state, @escape, 0)
      assert state.shell_state.filter_mode == false
      assert state.shell_state.filter_text == ""
    end
  end

  # ── Passthrough ────────────────────────────────────────────────────────

  describe "passthrough" do
    test "unbound keys without modifiers are consumed (no vim fallthrough)" do
      state = editor_with_board(3)

      {:handled, _state} = BoardInput.handle_key(state, ?x, 0)
      {:handled, _state} = BoardInput.handle_key(state, ?z, 0)
    end

    test "Ctrl-modified keys pass through to GlobalBindings" do
      state = editor_with_board(3)

      {:passthrough, _state} = BoardInput.handle_key(state, ?q, 0x02)
      {:passthrough, _state} = BoardInput.handle_key(state, ?s, 0x02)
    end

    test "handler passes through when shell is not Board" do
      state = %EditorState{
        port_manager: self(),
        shell: MingaEditor.Shell.Traditional,
        shell_state: %MingaEditor.Shell.Traditional.State{},
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        focus_stack: []
      }

      {:passthrough, _state} = BoardInput.handle_key(state, ?j, 0)
    end

    test "handler passes through when zoomed (ZoomOut handles Escape)" do
      state = editor_zoomed_into(3, 1)

      # Board.Input should passthrough since we're zoomed
      {:passthrough, _state} = BoardInput.handle_key(state, ?j, 0)
    end
  end
end
