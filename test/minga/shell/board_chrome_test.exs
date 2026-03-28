defmodule Minga.Shell.Board.ChromeTest do
  @moduledoc "Tests Board's build_chrome callback."

  use ExUnit.Case, async: true

  alias Minga.Core.Face
  alias Minga.Editor.DisplayList.Frame
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.RenderPipeline.Chrome
  alias Minga.Editor.RenderPipeline.Compose
  alias Minga.Editor.RenderPipeline.Content
  alias Minga.Editor.RenderPipeline.Scroll
  alias Minga.Editor.State, as: EditorState
  alias Minga.Shell.Board
  alias Minga.Shell.Board.State, as: BoardState

  import Minga.Editor.RenderPipeline.TestHelpers

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp grid_board_state do
    state = base_state()
    %{state | shell: Board, shell_state: BoardState.new()}
  end

  defp zoomed_board_state(card_attrs \\ []) do
    board = BoardState.new()
    attrs = Keyword.merge([task: "Test task", status: :working, model: "sonnet-4"], card_attrs)
    {board, card} = BoardState.create_card(board, attrs)
    board = BoardState.zoom_into(board, card.id, %{})

    state = base_state()
    %{state | shell: Board, shell_state: board}
  end

  defp run_through_content(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {frames, cursor_info, state} = Content.build_content(state, scrolls)
    {scrolls, frames, cursor_info, state, layout}
  end

  defp context_bar_text(chrome) do
    Enum.map_join(chrome.tab_bar, fn {_row, _col, text, _face} -> text end)
  end

  # ── Grid view ────────────────────────────────────────────────────────────

  describe "build_chrome/4 grid view" do
    test "returns an empty Chrome struct" do
      state = grid_board_state()
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
      assert chrome.tab_bar == []
      assert chrome.status_bar_draws == []
      assert chrome.minibuffer == []
      assert chrome.file_tree == []
      assert chrome.agent_panel == []
      assert chrome.overlays == []
      assert chrome.separators == []
      assert chrome.regions == []
    end
  end

  # ── Zoomed view ──────────────────────────────────────────────────────────

  describe "build_chrome/4 zoomed view" do
    test "returns context bar draws in tab_bar" do
      state = zoomed_board_state()
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      assert [_ | _] = chrome.tab_bar
      assert Enum.all?(chrome.tab_bar, &match?({_, _, _, %Face{}}, &1))
    end

    test "context bar contains card task text" do
      state = zoomed_board_state(task: "Fix the login bug")
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      assert context_bar_text(chrome) =~ "Fix the login bug"
    end

    test "context bar contains model name when present" do
      state = zoomed_board_state(model: "sonnet-4")
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      assert context_bar_text(chrome) =~ "sonnet-4"
    end

    test "context bar contains ESC hint" do
      state = zoomed_board_state()
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      assert context_bar_text(chrome) =~ "ESC back to Board"
    end

    test "context bar shows Untitled for empty task" do
      state = zoomed_board_state(task: "")
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      assert context_bar_text(chrome) =~ "Untitled"
    end

    test "context bar omits model segment when model is nil" do
      state = zoomed_board_state(model: nil)
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      refute context_bar_text(chrome) =~ " · "
    end

    test "produces regions list" do
      state = zoomed_board_state()
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      assert is_list(chrome.regions)
      assert Enum.all?(chrome.regions, &is_binary/1)
    end

    test "leaves other chrome fields empty" do
      state = zoomed_board_state()
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      assert chrome.status_bar_draws == []
      assert chrome.minibuffer == []
      assert chrome.file_tree == []
      assert chrome.agent_panel == []
      assert chrome.overlays == []
    end

    test "each card status has a distinct icon" do
      statuses = [:idle, :working, :iterating, :needs_you, :done, :errored]

      icons =
        Enum.map(statuses, fn status ->
          state = zoomed_board_state(status: status)
          {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)
          chrome = Board.build_chrome(state, layout, scrolls, cursor_info)
          context_bar_text(chrome)
        end)

      # All texts should be unique (different status icons)
      assert length(Enum.uniq(icons)) == length(statuses)
    end
  end

  # ── Composition ──────────────────────────────────────────────────────────

  describe "build_chrome/4 zoomed composition" do
    test "zoomed chrome composes into a valid Frame without crashing" do
      state = zoomed_board_state()
      {scrolls, frames, cursor_info, state, layout} = run_through_content(state)
      chrome = Board.build_chrome(state, layout, scrolls, cursor_info)

      frame = Compose.compose_windows(frames, chrome, cursor_info, state)

      assert %Frame{} = frame
      assert frame.cursor.shape in [:block, :beam, :underline]
    end
  end
end
