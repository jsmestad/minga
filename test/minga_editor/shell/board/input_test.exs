defmodule MingaEditor.Shell.Board.InputTest do
  @moduledoc """
  Tests for Board input handlers: grid navigation, zoom in/out, dispatch.

  Follows the Dashboard test pattern: builds a minimal EditorState with
  Board shell state and calls handler functions directly. No GenServer.
  """
  use ExUnit.Case, async: true

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
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
      # Set up a board with one agent card that has a session but no workspace
      fake_session = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, buf_pid} = Minga.Buffer.start_link(content: "")

      board =
        BoardState.new()
        |> then(fn b ->
          {b, _card} = BoardState.create_card(b, task: "Agent 1", session: fake_session)
          b
        end)

      # Ensure the focused card has workspace: nil (first-time zoom)
      focused_id = board.focused_card
      assert board.cards[focused_id].workspace == nil

      # Build state with a window in the map so activate_for_card can set content
      win = Window.new(1, buf_pid, 24, 80)
      windows = %Windows{map: %{1 => win}, active: 1, next_id: 2}

      state = %EditorState{
        port_manager: self(),
        shell: Board,
        shell_state: board,
        workspace: %MingaEditor.Workspace.State{
          viewport: Viewport.new(24, 80),
          windows: windows
        },
        focus_stack: [BoardInput, MingaEditor.Input.GlobalBindings]
      }

      {:handled, new_state} = BoardInput.handle_key(state, @enter, 0)

      # Agent activation should have set keymap scope to :agent
      assert new_state.workspace.keymap_scope == :agent

      # Window content should be agent_chat
      active_win = new_state.workspace.windows.map[new_state.workspace.windows.active]
      assert Content.agent_chat?(active_win.content)
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

    test "clears agent session singleton on zoom-out" do
      state = editor_zoomed_into(3, 1)

      # Simulate an active agent session on the board's agent singleton
      fake_pid = spawn(fn -> Process.sleep(:infinity) end)

      board = %{state.shell_state | agent: %AgentState{session: fake_pid, status: :idle}}
      state = %{state | shell_state: board}
      assert AgentAccess.session(state) == fake_pid

      {:handled, new_state} = ZoomOut.handle_key(state, @escape, 0)
      assert new_state.shell_state.zoomed_into == nil
      assert AgentAccess.session(new_state) == nil
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
    test "creates a new card, starts agent session, and auto-zooms" do
      state = editor_with_board(2)
      initial_count = BoardState.card_count(state.shell_state)

      {:handled, new_state} = BoardInput.handle_key(state, ?n, 0)
      assert BoardState.card_count(new_state.shell_state) == initial_count + 1
      assert new_state.shell_state.zoomed_into != nil

      # New card should have a model set
      new_card_id = new_state.shell_state.zoomed_into
      card = new_state.shell_state.cards[new_card_id]
      assert card.model != nil
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
