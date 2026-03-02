defmodule Minga.Editor.Commands.Movement do
  @moduledoc """
  Cursor movement commands: h/j/k/l, word motions, find-char, bracket
  matching, paragraph jumps, page scroll, and screen-relative positioning.
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Mode

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  # ── h / l (mode-aware) ────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}, mode: mode} = state, :move_left) do
    if mode in [:insert, :replace] do
      BufferServer.move(buf, :left)
    else
      {_line, col} = BufferServer.cursor(buf)
      if col > 0, do: BufferServer.move(buf, :left)
    end

    state
  end

  def execute(%{buf: %{buffer: buf}, mode: mode} = state, :move_right) do
    if mode in [:insert, :replace] do
      BufferServer.move(buf, :right)
    else
      {line, col} = BufferServer.cursor(buf)

      max_col =
        case BufferServer.get_lines(buf, line, 1) do
          [text] when byte_size(text) > 0 -> GapBuffer.last_grapheme_byte_offset(text)
          _ -> 0
        end

      if col < max_col, do: BufferServer.move(buf, :right)
    end

    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :move_up) do
    BufferServer.move(buf, :up)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :move_down) do
    BufferServer.move(buf, :down)
    state
  end

  # ── Line start / end ──────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :move_to_line_start) do
    {line, _col} = BufferServer.cursor(buf)
    BufferServer.move_to(buf, {line, 0})
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :move_to_line_end) do
    {line, _col} = BufferServer.cursor(buf)

    end_col =
      case BufferServer.get_lines(buf, line, 1) do
        [text] when byte_size(text) > 0 -> GapBuffer.last_grapheme_byte_offset(text)
        _ -> 0
      end

    BufferServer.move_to(buf, {line, end_col})
    state
  end

  # ── Word motions (small) ───────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :word_forward) do
    Helpers.apply_motion(buf, &Minga.Motion.word_forward/2)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :word_backward) do
    Helpers.apply_motion(buf, &Minga.Motion.word_backward/2)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :word_end) do
    Helpers.apply_motion(buf, &Minga.Motion.word_end/2)
    state
  end

  # ── Word motions (WORD / big) ─────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :word_forward_big) do
    Helpers.apply_motion(buf, &Minga.Motion.word_forward_big/2)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :word_backward_big) do
    Helpers.apply_motion(buf, &Minga.Motion.word_backward_big/2)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :word_end_big) do
    Helpers.apply_motion(buf, &Minga.Motion.word_end_big/2)
    state
  end

  # ── Line / document navigation ─────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :move_to_first_non_blank) do
    Helpers.apply_motion(buf, &Minga.Motion.first_non_blank/2)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :move_to_document_start) do
    content = BufferServer.content(buf)
    new_pos = Minga.Motion.document_start(GapBuffer.new(content))
    BufferServer.move_to(buf, new_pos)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :move_to_document_end) do
    content = BufferServer.content(buf)
    new_pos = Minga.Motion.document_end(GapBuffer.new(content))
    BufferServer.move_to(buf, new_pos)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, {:goto_line, line_num}) do
    target_line = max(0, line_num - 1)
    BufferServer.move_to(buf, {target_line, 0})
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :next_line_first_non_blank) do
    {content, {line, _col}} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    total = GapBuffer.line_count(tmp_buf)
    next_line = min(line + 1, total - 1)
    new_pos = Minga.Motion.first_non_blank(tmp_buf, {next_line, 0})
    BufferServer.move_to(buf, new_pos)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :prev_line_first_non_blank) do
    {content, {line, _col}} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    prev_line = max(line - 1, 0)
    new_pos = Minga.Motion.first_non_blank(tmp_buf, {prev_line, 0})
    BufferServer.move_to(buf, new_pos)
    state
  end

  # ── Find-char motions ─────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, {:find_char, dir, char}) do
    Helpers.apply_find_char(buf, dir, char)
    %{state | last_find_char: {dir, char}}
  end

  def execute(%{last_find_char: {dir, char}, buf: %{buffer: buf}} = state, :repeat_find_char) do
    Helpers.apply_find_char(buf, dir, char)
    state
  end

  def execute(state, :repeat_find_char), do: state

  def execute(
        %{last_find_char: {dir, char}, buf: %{buffer: buf}} = state,
        :repeat_find_char_reverse
      ) do
    reverse_dir = Helpers.reverse_find_direction(dir)
    Helpers.apply_find_char(buf, reverse_dir, char)
    state
  end

  def execute(state, :repeat_find_char_reverse), do: state

  # ── Bracket matching ──────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :match_bracket) do
    Helpers.apply_motion(buf, &Minga.Motion.match_bracket/2)
    state
  end

  # ── Paragraph motions ─────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :paragraph_forward) do
    Helpers.apply_motion(buf, &Minga.Motion.paragraph_forward/2)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :paragraph_backward) do
    Helpers.apply_motion(buf, &Minga.Motion.paragraph_backward/2)
    state
  end

  # ── Screen-relative motions ───────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}, viewport: vp} = state, {:move_to_screen, position}) do
    {first_line, _last_line} = Viewport.visible_range(vp)
    visible_rows = Viewport.content_rows(vp)
    total_lines = BufferServer.line_count(buf)

    target_line =
      case position do
        :top -> first_line
        :middle -> min(first_line + div(visible_rows, 2), total_lines - 1)
        :bottom -> min(first_line + visible_rows - 1, total_lines - 1)
      end

    BufferServer.move_to(buf, {target_line, 0})
    state
  end

  # ── Page scrolling ────────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}, viewport: vp} = state, :half_page_down) do
    Helpers.page_move(buf, vp, div(Viewport.content_rows(vp), 2))
    state
  end

  def execute(%{buf: %{buffer: buf}, viewport: vp} = state, :half_page_up) do
    Helpers.page_move(buf, vp, -div(Viewport.content_rows(vp), 2))
    state
  end

  def execute(%{buf: %{buffer: buf}, viewport: vp} = state, :page_down) do
    Helpers.page_move(buf, vp, Viewport.content_rows(vp))
    state
  end

  def execute(%{buf: %{buffer: buf}, viewport: vp} = state, :page_up) do
    Helpers.page_move(buf, vp, -Viewport.content_rows(vp))
    state
  end

  # ── Unimplemented window stubs ────────────────────────────────────────────

  def execute(state, :window_left), do: state
  def execute(state, :window_right), do: state
  def execute(state, :window_up), do: state
  def execute(state, :window_down), do: state
  def execute(state, :split_vertical), do: state
  def execute(state, :split_horizontal), do: state
  def execute(state, :describe_key), do: state
end
