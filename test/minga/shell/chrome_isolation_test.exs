defmodule Minga.Shell.ChromeIsolationTest do
  @moduledoc """
  Cross-shell chrome isolation tests.

  Verifies AC 7 of the deterministic editor testing proposal:
  "Each shell's chrome is independently testable: Traditional tests
  don't break when Board changes and vice versa."

  Both shells' `build_chrome/4` are tested as pure functions with
  constructed state. Neither depends on the other's implementation.
  Uses the DisplayListAssertions helpers to verify rendering at
  the Frame level.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.RenderPipeline.Content
  alias Minga.Editor.RenderPipeline.Scroll
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.VimState
  alias Minga.Shell.Board
  alias Minga.Shell.Board.State, as: BoardState

  import Minga.Editor.RenderPipeline.TestHelpers
  import Minga.Test.DisplayListAssertions

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp traditional_state(opts \\ []) do
    state = base_state(opts)

    # Ensure tab bar is set up for Traditional chrome
    tab = Tab.new_file(1, Keyword.get(opts, :tab_name, "test.ex"))
    tb = TabBar.new(tab)
    put_in(state.shell_state.tab_bar, tb)
  end

  defp board_grid_state(opts \\ []) do
    state = base_state(opts)
    %{state | shell: Board, shell_state: BoardState.new()}
  end

  defp board_zoomed_state(card_opts) do
    board = BoardState.new()
    attrs = Keyword.merge([task: "Agent task", status: :working, model: "sonnet-4"], card_opts)
    {board, card} = BoardState.create_card(board, attrs)
    board = BoardState.zoom_into(board, card.id, %{})

    state = base_state()
    %{state | shell: Board, shell_state: board}
  end

  defp with_mode(state, mode) do
    vim = VimState.transition(state.workspace.editing, mode)
    put_in(state.workspace.editing, vim)
  end

  defp run_chrome(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {_frames, cursor_info, state} = Content.build_content(state, scrolls)

    chrome = state.shell.build_chrome(state, layout, scrolls, cursor_info)
    {chrome, state}
  end

  # ── Cross-shell isolation ───────────────────────────────────────────────

  describe "Traditional and Board chrome are independent" do
    test "Traditional produces status bar draws; Board grid does not" do
      {trad_chrome, _} = traditional_state() |> run_chrome()
      {board_chrome, _} = board_grid_state() |> run_chrome()

      assert [_ | _] = trad_chrome.status_bar_draws
      assert board_chrome.status_bar_draws == []
    end

    test "Traditional produces tab bar; Board grid does not" do
      {trad_chrome, _} = traditional_state() |> run_chrome()
      {board_chrome, _} = board_grid_state() |> run_chrome()

      assert [_ | _] = trad_chrome.tab_bar
      assert board_chrome.tab_bar == []
    end

    test "Traditional produces minibuffer; Board grid does not" do
      {trad_chrome, _} = traditional_state() |> run_chrome()
      {board_chrome, _} = board_grid_state() |> run_chrome()

      assert [_ | _] = trad_chrome.minibuffer
      assert board_chrome.minibuffer == []
    end

    test "Board zoomed produces context bar in tab_bar slot; Traditional has buffer names" do
      {trad_chrome, _} = traditional_state(tab_name: "router.ex") |> run_chrome()
      {board_chrome, _} = board_zoomed_state(task: "Fix login bug") |> run_chrome()

      # Traditional tab_bar has buffer name
      trad_tab_text =
        trad_chrome.tab_bar
        |> Enum.sort_by(fn {r, c, _, _} -> {r, c} end)
        |> Enum.map_join(fn {_, _, text, _} -> text end)

      assert trad_tab_text =~ "router.ex"

      # Board tab_bar has context bar with card task
      board_tab_text =
        board_chrome.tab_bar
        |> Enum.sort_by(fn {r, c, _, _} -> {r, c} end)
        |> Enum.map_join(fn {_, _, text, _} -> text end)

      assert board_tab_text =~ "Fix login bug"
    end

    test "mode changes only affect Traditional status bar, not Board grid chrome" do
      trad_normal = traditional_state() |> with_mode(:normal) |> run_chrome() |> elem(0)
      trad_insert = traditional_state() |> with_mode(:insert) |> run_chrome() |> elem(0)

      board_normal = board_grid_state() |> with_mode(:normal) |> run_chrome() |> elem(0)
      board_insert = board_grid_state() |> with_mode(:insert) |> run_chrome() |> elem(0)

      # Traditional status bar changes with mode
      trad_normal_text =
        Enum.map_join(trad_normal.status_bar_draws, fn {_, _, text, _} -> text end)

      trad_insert_text =
        Enum.map_join(trad_insert.status_bar_draws, fn {_, _, text, _} -> text end)

      assert trad_normal_text =~ "NORMAL"
      assert trad_insert_text =~ "INSERT"
      refute trad_normal_text =~ "INSERT"
      refute trad_insert_text =~ "NORMAL"

      # Board grid chrome is empty regardless of mode
      assert board_normal.status_bar_draws == []
      assert board_insert.status_bar_draws == []
      assert board_normal.tab_bar == []
      assert board_insert.tab_bar == []
    end
  end

  # ── Full-frame rendering via DisplayListAssertions ──────────────────────

  describe "render_frame produces independent frames per shell" do
    test "Traditional frame has status bar and tab bar content" do
      state = traditional_state(tab_name: "app.ex")
      frame = render_frame(state)

      assert [_ | _] = frame.status_bar
      assert [_ | _] = frame.tab_bar
    end

    test "Board grid frame has no status bar or tab bar" do
      state = board_grid_state()
      frame = render_frame(state)

      assert frame.status_bar == []
      assert frame.tab_bar == []
    end

    test "Board zoomed frame has context bar in tab_bar slot" do
      state = board_zoomed_state(task: "Refactor auth")
      frame = render_frame(state)

      tab_text = draws_to_text(frame.tab_bar)
      assert tab_text =~ "Refactor auth"
      assert frame.status_bar == []
    end

    test "Traditional frame status bar reflects mode" do
      state = traditional_state() |> with_mode(:insert)
      frame = render_frame(state)

      assert_status_bar_contains(frame, "INSERT")
    end

    test "Traditional frame tab bar reflects buffer name" do
      state = traditional_state(tab_name: "schema.ex")
      frame = render_frame(state)

      assert_tab_bar_contains(frame, "schema.ex")
    end
  end
end
