defmodule Minga.Editor.Commands.Editing do
  @moduledoc """
  Single-key and multi-key editing commands: insert/delete, join, replace,
  case toggle, indent/dedent, undo/redo, and paste.
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Mode.ReplaceState
  alias Minga.Mode.VisualState

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  # ── Deletion ──────────────────────────────────────────────────────────────

  def execute(
        %{buf: %{buffer: buf}, mode: :insert, autopair_enabled: true} = state,
        :delete_before
      ) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)

    case Minga.AutoPair.on_backspace(tmp_buf, cursor) do
      :delete_pair ->
        BufferServer.delete_before(buf)
        BufferServer.delete_at(buf)

      :passthrough ->
        BufferServer.delete_before(buf)
    end

    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :delete_before) do
    BufferServer.delete_before(buf)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :delete_at) do
    BufferServer.delete_at(buf)
    state
  end

  # ── Insertion ─────────────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :insert_newline) do
    BufferServer.insert_char(buf, "\n")
    state
  end

  def execute(
        %{buf: %{buffer: buf}, mode: :insert, autopair_enabled: true} = state,
        {:insert_char, char}
      )
      when is_binary(char) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)

    case Minga.AutoPair.on_insert(tmp_buf, cursor, char) do
      {:pair, open, close} ->
        BufferServer.insert_char(buf, open)
        BufferServer.insert_char(buf, close)
        BufferServer.move(buf, :left)

      {:skip, _char} ->
        BufferServer.move(buf, :right)

      {:passthrough, char} ->
        BufferServer.insert_char(buf, char)
    end

    state
  end

  def execute(%{buf: %{buffer: buf}} = state, {:insert_char, char}) when is_binary(char) do
    BufferServer.insert_char(buf, char)
    state
  end

  # ── Open lines ────────────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :insert_line_below) do
    {line, _col} = BufferServer.cursor(buf)

    end_col =
      case BufferServer.get_lines(buf, line, 1) do
        [text] -> String.length(text)
        [] -> 0
      end

    BufferServer.move_to(buf, {line, end_col})
    BufferServer.insert_char(buf, "\n")
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :insert_line_above) do
    {line, _col} = BufferServer.cursor(buf)
    BufferServer.move_to(buf, {line, 0})
    BufferServer.insert_char(buf, "\n")
    BufferServer.move(buf, :up)
    state
  end

  # ── Single-key editing ────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :join_lines) do
    {line, _col} = BufferServer.cursor(buf)
    total_lines = BufferServer.line_count(buf)

    if line < total_lines - 1 do
      current_line =
        case BufferServer.get_lines(buf, line, 1) do
          [text] -> text
          [] -> ""
        end

      end_col = String.length(current_line)
      BufferServer.move_to(buf, {line, end_col})
      BufferServer.delete_at(buf)

      next_line =
        case BufferServer.get_lines(buf, line, 1) do
          [text] -> text
          [] -> ""
        end

      trimmed = String.trim_leading(String.slice(next_line, end_col, String.length(next_line)))
      spaces_to_delete = String.length(next_line) - end_col - String.length(trimmed)

      for _ <- 1..max(spaces_to_delete, 0)//1 do
        BufferServer.delete_at(buf)
      end

      if end_col > 0 and trimmed != "" do
        BufferServer.insert_char(buf, " ")
      end
    end

    state
  end

  def execute(%{buf: %{buffer: buf}} = state, {:replace_char, char}) do
    BufferServer.delete_at(buf)
    BufferServer.insert_char(buf, char)
    BufferServer.move(buf, :left)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :toggle_case) do
    {line, col} = BufferServer.cursor(buf)

    case BufferServer.get_lines(buf, line, 1) do
      [text] ->
        graphemes = String.graphemes(text)

        if col < length(graphemes) do
          char = Enum.at(graphemes, col)
          toggled = Helpers.toggle_char_case(char)
          BufferServer.delete_at(buf)
          BufferServer.insert_char(buf, toggled)
        end

      _ ->
        :ok
    end

    state
  end

  # ── Replace mode ──────────────────────────────────────────────────────────

  def execute(
        %{buf: %{buffer: buf}, mode_state: %ReplaceState{} = ms} = state,
        {:replace_overwrite, char}
      ) do
    {line, col} = BufferServer.cursor(buf)

    original =
      case BufferServer.get_lines(buf, line, 1) do
        [text] ->
          graphemes = String.graphemes(text)
          if col < length(graphemes), do: Enum.at(graphemes, col), else: " "

        _ ->
          " "
      end

    BufferServer.delete_at(buf)
    BufferServer.insert_char(buf, char)
    new_ms = %{ms | original_chars: [original | ms.original_chars]}
    %{state | mode_state: new_ms}
  end

  def execute(state, {:replace_overwrite, _char}), do: state

  def execute(
        %{
          buffer: buf,
          mode_state: %ReplaceState{original_chars: [orig | rest]} = ms
        } = state,
        :replace_restore
      ) do
    BufferServer.delete_before(buf)
    BufferServer.insert_char(buf, orig)
    BufferServer.move(buf, :left)
    new_ms = %{ms | original_chars: rest}
    %{state | mode_state: new_ms}
  end

  def execute(
        %{mode_state: %ReplaceState{original_chars: []}} = state,
        :replace_restore
      ),
      do: state

  def execute(state, :replace_restore), do: state

  # ── Undo / redo ───────────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :undo) do
    BufferServer.undo(buf)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :redo) do
    BufferServer.redo(buf)
    state
  end

  # ── Paste ─────────────────────────────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :paste_before) do
    {text, state} = Helpers.get_register(state)

    case text do
      nil ->
        state

      t ->
        BufferServer.insert_char(buf, t)
        state
    end
  end

  def execute(%{buf: %{buffer: buf}} = state, :paste_after) do
    {text, state} = Helpers.get_register(state)

    case text do
      nil ->
        state

      t ->
        BufferServer.move(buf, :right)
        BufferServer.insert_char(buf, t)
        state
    end
  end

  # ── Indent / dedent (single line) ────────────────────────────────────────

  def execute(%{buf: %{buffer: buf}} = state, :indent_line) do
    {line, col} = BufferServer.cursor(buf)
    BufferServer.move_to(buf, {line, 0})
    BufferServer.insert_char(buf, "  ")
    BufferServer.move_to(buf, {line, col + 2})
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, :dedent_line) do
    {line, col} = BufferServer.cursor(buf)

    case BufferServer.get_lines(buf, line, 1) do
      [text] -> dedent_single_line(buf, line, col, text)
      _ -> :ok
    end

    state
  end

  # ── Indent / dedent (multiple lines via count or motion) ─────────────────

  def execute(%{buf: %{buffer: buf}} = state, {:indent_lines, n}) do
    {cursor_line, _} = BufferServer.cursor(buf)
    total = BufferServer.line_count(buf)
    end_line = min(cursor_line + n - 1, total - 1)
    do_indent_lines(buf, cursor_line, end_line)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, {:dedent_lines, n}) do
    {cursor_line, _} = BufferServer.cursor(buf)
    total = BufferServer.line_count(buf)
    end_line = min(cursor_line + n - 1, total - 1)
    do_dedent_lines(buf, cursor_line, end_line)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, {:indent_motion, motion}) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    target = Helpers.resolve_motion(tmp_buf, cursor, motion)
    {cursor_line, _} = cursor
    {target_line, _} = target
    start_line = min(cursor_line, target_line)
    end_line = max(cursor_line, target_line)
    do_indent_lines(buf, start_line, end_line)
    state
  end

  def execute(%{buf: %{buffer: buf}} = state, {:dedent_motion, motion}) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    target = Helpers.resolve_motion(tmp_buf, cursor, motion)
    {cursor_line, _} = cursor
    {target_line, _} = target
    start_line = min(cursor_line, target_line)
    end_line = max(cursor_line, target_line)
    do_dedent_lines(buf, start_line, end_line)
    state
  end

  def execute(
        %{buf: %{buffer: buf}, mode_state: %VisualState{} = ms} = state,
        :indent_visual_selection
      ) do
    anchor = ms.visual_anchor
    cursor = BufferServer.cursor(buf)
    {anchor_line, _} = anchor
    {cursor_line, _} = cursor
    start_line = min(anchor_line, cursor_line)
    end_line = max(anchor_line, cursor_line)
    do_indent_lines(buf, start_line, end_line)
    state
  end

  def execute(
        %{buf: %{buffer: buf}, mode_state: %VisualState{} = ms} = state,
        :dedent_visual_selection
      ) do
    anchor = ms.visual_anchor
    cursor = BufferServer.cursor(buf)
    {anchor_line, _} = anchor
    {cursor_line, _} = cursor
    start_line = min(anchor_line, cursor_line)
    end_line = max(anchor_line, cursor_line)
    do_dedent_lines(buf, start_line, end_line)
    state
  end

  # ── Private indent helpers ────────────────────────────────────────────────

  @spec do_indent_lines(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp do_indent_lines(buf, start_line, end_line) do
    {cursor_line, cursor_col} = BufferServer.cursor(buf)

    for line <- start_line..end_line do
      BufferServer.move_to(buf, {line, 0})
      BufferServer.insert_char(buf, "  ")
    end

    new_col =
      if cursor_line >= start_line and cursor_line <= end_line,
        do: cursor_col + 2,
        else: cursor_col

    BufferServer.move_to(buf, {cursor_line, new_col})
    :ok
  end

  @spec do_dedent_lines(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp do_dedent_lines(buf, start_line, end_line) do
    {cursor_line, cursor_col} = BufferServer.cursor(buf)
    cursor_removed = cursor_line_spaces_to_remove(buf, cursor_line, start_line, end_line)

    for line <- start_line..end_line do
      dedent_line_at(buf, line)
    end

    new_col = max(0, cursor_col - cursor_removed)
    BufferServer.move_to(buf, {cursor_line, new_col})
    :ok
  end

  @spec cursor_line_spaces_to_remove(
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp cursor_line_spaces_to_remove(buf, cursor_line, start_line, end_line) do
    if cursor_line >= start_line and cursor_line <= end_line do
      case BufferServer.get_lines(buf, cursor_line, 1) do
        [text] -> min(count_leading_spaces(text), 2)
        _ -> 0
      end
    else
      0
    end
  end

  @spec dedent_line_at(pid(), non_neg_integer()) :: :ok
  defp dedent_line_at(buf, line) do
    case BufferServer.get_lines(buf, line, 1) do
      [text] -> remove_leading_spaces(buf, line, min(count_leading_spaces(text), 2))
      _ -> :ok
    end
  end

  @spec dedent_single_line(pid(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  defp dedent_single_line(buf, line, col, text) do
    to_remove = min(count_leading_spaces(text), 2)
    remove_leading_spaces(buf, line, to_remove)
    if to_remove > 0, do: BufferServer.move_to(buf, {line, max(0, col - to_remove)})
    :ok
  end

  @spec remove_leading_spaces(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp remove_leading_spaces(_buf, _line, 0), do: :ok

  defp remove_leading_spaces(buf, line, n) when n > 0 do
    BufferServer.move_to(buf, {line, 0})
    for _ <- 1..n, do: BufferServer.delete_at(buf)
    :ok
  end

  @spec count_leading_spaces(String.t()) :: non_neg_integer()
  defp count_leading_spaces(text) do
    text
    |> String.graphemes()
    |> Enum.take_while(&(&1 == " "))
    |> length()
  end
end
