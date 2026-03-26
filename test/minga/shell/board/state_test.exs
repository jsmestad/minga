defmodule Minga.Shell.Board.StateTest do
  @moduledoc """
  Tests for Board.State and Card structs: card CRUD, focus management,
  zoom lifecycle, and workspace snapshot round-trips.

  All tests are pure function calls on structs. No GenServer needed.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Shell.Board.Card
  alias Minga.Shell.Board.State

  # ── Card creation ──────────────────────────────────────────────────────

  describe "create_card/2" do
    test "adds a card with correct initial fields" do
      {state, card} = State.create_card(State.new(), task: "refactor auth", model: "claude-4")

      assert card.task == "refactor auth"
      assert card.model == "claude-4"
      assert card.status == :idle
      assert card.session == nil
      assert card.id == 1
      assert Map.has_key?(state.cards, card.id)
    end

    test "auto-focuses first card when no card was focused" do
      {state, card} = State.create_card(State.new(), task: "first")
      assert state.focused_card == card.id
    end

    test "preserves existing focus when adding more cards" do
      {state, first} = State.create_card(State.new(), task: "first")
      {state, _second} = State.create_card(state, task: "second")
      assert state.focused_card == first.id
    end

    test "assigns monotonically increasing IDs" do
      {state, c1} = State.create_card(State.new(), task: "a")
      {state, c2} = State.create_card(state, task: "b")
      {_state, c3} = State.create_card(state, task: "c")
      assert c1.id < c2.id
      assert c2.id < c3.id
    end
  end

  # ── Card ID uniqueness (property) ──────────────────────────────────────

  property "card IDs are always unique across any number of creates" do
    check all n <- integer(1..50) do
      state =
        Enum.reduce(1..n, State.new(), fn _, acc ->
          {acc, _card} = State.create_card(acc, task: "t")
          acc
        end)

      ids = Map.keys(state.cards)
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  # ── Card removal ───────────────────────────────────────────────────────

  describe "remove_card/2" do
    test "deletes the card from the map" do
      {state, card} = State.create_card(State.new(), task: "doomed")
      state = State.remove_card(state, card.id)
      assert State.card_count(state) == 0
      refute Map.has_key?(state.cards, card.id)
    end

    test "moves focus to next card when focused card is removed" do
      {state, c1} = State.create_card(State.new(), task: "first")
      {state, c2} = State.create_card(state, task: "second")
      assert state.focused_card == c1.id

      state = State.remove_card(state, c1.id)
      assert state.focused_card == c2.id
    end

    test "clears focus when last card is removed" do
      {state, card} = State.create_card(State.new(), task: "only")
      state = State.remove_card(state, card.id)
      assert state.focused_card == nil
    end

    test "clears zoom when zoomed card is removed" do
      {state, card} = State.create_card(State.new(), task: "zoomed")
      state = State.zoom_into(state, card.id, %{fake: :workspace})
      assert state.zoomed_into == card.id

      state = State.remove_card(state, card.id)
      assert state.zoomed_into == nil
    end
  end

  # ── Card updates ───────────────────────────────────────────────────────

  describe "update_card/3" do
    test "applies function to the card" do
      {state, card} = State.create_card(State.new(), task: "task")
      state = State.update_card(state, card.id, &Card.set_status(&1, :working))
      assert state.cards[card.id].status == :working
    end

    test "no-ops for nonexistent card ID" do
      state = State.new()
      assert state == State.update_card(state, 999, &Card.set_status(&1, :working))
    end
  end

  # ── Focus navigation ───────────────────────────────────────────────────

  describe "move_focus/3" do
    test "moves right within a row" do
      {state, c1} = State.create_card(State.new(), task: "a")
      {state, c2} = State.create_card(state, task: "b")
      state = State.focus_card(state, c1.id)

      state = State.move_focus(state, :right, 3)
      assert state.focused_card == c2.id
    end

    test "moves left within a row" do
      {state, c1} = State.create_card(State.new(), task: "a")
      {state, c2} = State.create_card(state, task: "b")
      state = State.focus_card(state, c2.id)

      state = State.move_focus(state, :left, 3)
      assert state.focused_card == c1.id
    end

    test "moves down to next row" do
      state = State.new()
      {state, c1} = State.create_card(state, task: "a")
      {state, _c2} = State.create_card(state, task: "b")
      {state, c3} = State.create_card(state, task: "c")
      state = State.focus_card(state, c1.id)

      # 2 columns: c1 c2 / c3
      state = State.move_focus(state, :down, 2)
      assert state.focused_card == c3.id
    end

    test "clamps at boundaries instead of wrapping" do
      {state, c1} = State.create_card(State.new(), task: "only")
      state = State.focus_card(state, c1.id)

      state = State.move_focus(state, :left, 3)
      assert state.focused_card == c1.id

      state = State.move_focus(state, :up, 3)
      assert state.focused_card == c1.id
    end

    test "no-ops when no card is focused" do
      state = State.new()
      assert state == State.move_focus(state, :right, 3)
    end
  end

  # ── Zoom lifecycle ─────────────────────────────────────────────────────

  describe "zoom_into/3" do
    test "sets zoomed_into and stores workspace snapshot" do
      {state, card} = State.create_card(State.new(), task: "zoom me")
      ws = %{buffers: :fake_buffers, editing: :fake_vim}

      state = State.zoom_into(state, card.id, ws)
      assert state.zoomed_into == card.id
      assert state.cards[card.id].workspace == ws
    end

    test "focuses the zoomed card" do
      {state, c1} = State.create_card(State.new(), task: "a")
      {state, c2} = State.create_card(state, task: "b")
      assert state.focused_card == c1.id

      state = State.zoom_into(state, c2.id, %{})
      assert state.focused_card == c2.id
    end
  end

  describe "zoom_out/1" do
    test "clears zoom and returns the stored workspace" do
      {state, card} = State.create_card(State.new(), task: "zoomed")
      ws = %{buffers: :fake, editing: :fake}

      state = State.zoom_into(state, card.id, ws)
      {state, restored} = State.zoom_out(state)

      assert state.zoomed_into == nil
      assert restored == ws
      # Workspace is cleared from the card after zoom out
      assert state.cards[card.id].workspace == nil
    end

    test "returns nil when not zoomed" do
      {state, _card} = State.create_card(State.new(), task: "not zoomed")
      {_state, snapshot} = State.zoom_out(state)
      assert snapshot == nil
    end
  end

  # ── Zoom round-trip (property) ─────────────────────────────────────────

  property "zoom_into then zoom_out restores the original workspace snapshot" do
    check all task <- string(:printable, min_length: 1, max_length: 100) do
      {state, card} = State.create_card(State.new(), task: task)
      workspace = %{content: task, cursor: {0, 0}}

      state = State.zoom_into(state, card.id, workspace)
      {_state, restored} = State.zoom_out(state)

      assert restored == workspace
    end
  end

  # ── Query helpers ──────────────────────────────────────────────────────

  describe "query helpers" do
    test "sorted_cards returns cards in creation order" do
      state = State.new()
      {state, _} = State.create_card(state, task: "third")
      {state, _} = State.create_card(state, task: "first")
      {state, _} = State.create_card(state, task: "second")

      tasks = state |> State.sorted_cards() |> Enum.map(& &1.task)
      assert tasks == ["third", "first", "second"]
    end

    test "grid_view? returns true when not zoomed" do
      assert State.grid_view?(State.new())
    end

    test "grid_view? returns false when zoomed" do
      {state, card} = State.create_card(State.new(), task: "z")
      state = State.zoom_into(state, card.id, %{})
      refute State.grid_view?(state)
    end

    test "focused/1 returns the focused card" do
      {state, card} = State.create_card(State.new(), task: "focused")
      assert State.focused(state) == card
    end

    test "focused/1 returns nil when no focus" do
      assert State.focused(State.new()) == nil
    end
  end

  # ── Card struct ────────────────────────────────────────────────────────

  describe "Card" do
    test "you_card? is true when kind is :you" do
      card = Card.new(1, task: "You", kind: :you)
      assert Card.you_card?(card)
    end

    test "you_card? is false for agent cards" do
      card = Card.new(1, task: "Agent")
      refute Card.you_card?(card)
    end

    test "you_card? is false when session is attached" do
      card = Card.new(1, task: "Agent") |> Card.attach_session(self())
      refute Card.you_card?(card)
    end

    test "attach_session sets status to working" do
      card = Card.new(1, task: "agent") |> Card.attach_session(self())
      assert card.status == :working
      assert card.session == self()
    end

    test "set_status transitions correctly" do
      card = Card.new(1, task: "t")
      assert card.status == :idle

      card = Card.set_status(card, :working)
      assert card.status == :working

      card = Card.set_status(card, :needs_you)
      assert card.status == :needs_you
    end

    test "set_recent_files updates the list" do
      card = Card.new(1, task: "t") |> Card.set_recent_files(["a.ex", "b.ex"])
      assert card.recent_files == ["a.ex", "b.ex"]
    end
  end
end
