defmodule MingaBoard.Shell.ChromeTest do
  @moduledoc "Tests Board's build_chrome callback."

  use ExUnit.Case, async: true

  alias MingaEditor.RenderPipeline.ComposedFrame
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Chrome
  alias MingaEditor.RenderPipeline.Compose
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState
  alias MingaBoard.Shell
  alias MingaBoard.Shell.State, as: BoardState
  alias MingaEditor.Shell.Traditional

  import MingaEditor.RenderPipeline.TestHelpers

  @op_gui_extension_runtime Minga.Protocol.Opcodes.gui_extension_runtime()
  @op_gui_board 0x87

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp grid_board_state do
    state = base_state()

    %{
      state
      | shell: Shell,
        shell_id: :board,
        shell_identity: board_identity(),
        shell_state: BoardState.new()
    }
  end

  defp board_identity do
    case MingaEditor.Shell.Registry.get(:board) do
      nil ->
        MingaBoard.Feature.register_contributions()
        MingaEditor.Shell.Identity.new(MingaEditor.Shell.Registry.get(:board))

      entry ->
        MingaEditor.Shell.Identity.new(entry)
    end
  end

  defp zoomed_board_state(card_attrs \\ []) do
    board = BoardState.new()
    attrs = Keyword.merge([task: "Test task", status: :working, model: "sonnet-4"], card_attrs)
    {board, card} = BoardState.create_card(board, attrs)
    board = BoardState.zoom_into(board, card.id, %{})

    state = base_state()

    %{
      state
      | shell: Shell,
        shell_id: :board,
        shell_identity: board_identity(),
        shell_state: board
    }
  end

  defp gui_board_state(state) do
    %{state | capabilities: %Capabilities{frontend_type: :native_gui}, port_manager: self()}
  end

  defp assert_board_runtime(command, expected_visible) do
    payload = unwrap_board_runtime(command)

    assert <<@op_gui_board, visible::8, _focused_id::32, card_count::16, _rest::binary>> = payload
    assert visible == if(expected_visible, do: 1, else: 0)
    card_count
  end

  defp unwrap_board_runtime(binary) do
    <<@op_gui_extension_runtime, envelope_len::32, envelope::binary-size(envelope_len)>> = binary

    <<extension_len::16, extension_id::binary-size(extension_len), channel_len::16,
      channel::binary-size(channel_len), payload::binary>> = envelope

    assert extension_id == "minga_board"
    assert channel == "board"
    payload
  end

  defp drain_send_commands(acc \\ []) do
    receive do
      {:"$gen_cast", {:send_commands, commands}} -> drain_send_commands(acc ++ commands)
      {:"$gen_cast", {:hop_mark, _name, _time}} -> drain_send_commands(acc)
    after
      0 -> acc
    end
  end

  defp board_runtime_commands(commands) do
    Enum.filter(commands, fn
      <<@op_gui_extension_runtime, _rest::binary>> -> true
      _other -> false
    end)
  end

  defp run_through_content(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    {frames, cursor_info, state} = Content.build_content(state, scrolls)
    {scrolls, frames, cursor_info, state, layout}
  end

  # ── Async render eligibility ─────────────────────────────────────────────

  describe "async_render?/1" do
    test "Board grid view opts out of async rendering" do
      refute Shell.async_render?(grid_board_state())
    end

    test "Board zoomed view allows async rendering" do
      assert Shell.async_render?(zoomed_board_state())
    end

    test "Traditional shell allows async rendering" do
      assert Traditional.async_render?(base_state())
    end
  end

  # ── GUI runtime payloads ────────────────────────────────────────────────

  describe "GUI Board runtime payloads" do
    test "zoomed GUI render sends hidden Board runtime before buffer rendering" do
      state = zoomed_board_state() |> gui_board_state()

      _state = Shell.render(state)

      assert_receive {:"$gen_cast", {:send_commands, [command]}}, 100
      assert 0 = assert_board_runtime(command, false)
    end

    test "grid GUI render sends visible Board runtime" do
      state = grid_board_state() |> gui_board_state()

      _state = Shell.render(state)

      assert_receive {:"$gen_cast", {:send_commands, [command]}}, 100
      assert 0 = assert_board_runtime(command, true)
    end

    test "toggling away from Board on GUI sends hidden Board runtime" do
      state = grid_board_state() |> gui_board_state()

      state = MingaBoard.Commands.toggle(state)

      assert state.shell_id == :traditional
      assert_receive {:"$gen_cast", {:send_commands, [command]}}, 100
      assert 0 = assert_board_runtime(command, false)
    end

    test "zoomed TUI render does not send Board runtime" do
      state = zoomed_board_state()

      _state = Shell.render(state)
      commands = drain_send_commands()

      assert board_runtime_commands(commands) == []
    end
  end

  # ── Grid view ────────────────────────────────────────────────────────────

  describe "build_chrome/4 grid view" do
    test "returns an empty Chrome struct" do
      state = grid_board_state()
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Shell.build_chrome(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
      assert chrome.overlays == []
      assert chrome.status_bar_data == nil
    end
  end

  # ── Zoomed view ──────────────────────────────────────────────────────────

  describe "build_chrome/4 zoomed view" do
    # The cell-grid zoom context-bar painter was removed in #2311 along with the
    # Chrome struct's draw slots. The zoomed view renders the card's workspace
    # through the traditional editor window pipeline, not through any chrome draw
    # slot, so `build_chrome/4` now returns an empty Chrome in both views.
    test "returns an empty Chrome struct (zoom renders through the window pipeline)" do
      state = zoomed_board_state()
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Shell.build_chrome(state, layout, scrolls, cursor_info)

      assert %Chrome{} = chrome
      assert chrome.overlays == []
      assert chrome.status_bar_data == nil
    end
  end

  # ── Zoomed layout (no dead context-bar row) ──────────────────────────────

  describe "compute_layout/1 zoomed view" do
    test "editor area starts at row 0 with no reserved context-bar row" do
      state = zoomed_board_state()
      state = RenderPipeline.compute_layout(state)
      layout = Layout.get(state)

      {editor_top, _left, _cols, editor_rows} = layout.editor_area
      {minibuffer_row, _, _, minibuffer_height} = layout.minibuffer
      {_, _, _, total_rows} = layout.terminal

      # No blank top row: the editor begins at row 0, not row 1.
      assert editor_top == 0

      # The minibuffer takes the last row and the editor fills everything above
      # it, so no row is reserved-but-unpainted.
      assert minibuffer_height == 1
      assert minibuffer_row == editor_rows
      assert editor_top + editor_rows + minibuffer_height == total_rows
    end
  end

  # ── Composition ──────────────────────────────────────────────────────────

  describe "build_chrome/4 zoomed composition" do
    test "zoomed chrome composes into a valid ComposedFrame without crashing" do
      state = zoomed_board_state()
      {scrolls, frames, cursor_info, state, layout} = run_through_content(state)
      chrome = Shell.build_chrome(state, layout, scrolls, cursor_info)

      frame = Compose.compose_windows(frames, chrome, cursor_info, state)

      assert %ComposedFrame{} = frame
      assert frame.cursor.shape in [:block, :beam, :underline]
    end
  end

  # ── Independence from Traditional ───────────────────────────────────────

  describe "build_chrome/4 independence from Traditional layout" do
    test "Board grid chrome carries no Traditional status bar data regardless of viewport" do
      for cols <- [40, 80, 120, 200] do
        board = BoardState.new()
        state = base_state(cols: cols)

        state = %{
          state
          | shell: Shell,
            shell_id: :board,
            shell_identity: board_identity(),
            shell_state: board
        }

        {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)
        chrome = Shell.build_chrome(state, layout, scrolls, cursor_info)

        assert chrome.status_bar_data == nil, "no status bar data at cols=#{cols}"
        assert chrome.overlays == [], "no overlays at cols=#{cols}"
      end
    end

    test "Board zoomed chrome carries no Traditional modeline fields" do
      # Even if the shell_state has Traditional-like fields, Board renders its
      # zoom view through the editor window pipeline, not Traditional chrome.
      state = zoomed_board_state(task: "My task")
      {scrolls, _frames, cursor_info, state, layout} = run_through_content(state)

      chrome = Shell.build_chrome(state, layout, scrolls, cursor_info)

      assert chrome.status_bar_data == nil
      assert chrome.modeline_click_regions == []
    end
  end
end
