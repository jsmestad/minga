defmodule Minga.Editor.Commands.Search do
  @moduledoc """
  Search commands: incremental search, confirm/cancel, next/prev match, and
  word-under-cursor search.
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Mode.SearchState

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  def execute(
        %{buffer: buf, mode_state: %SearchState{} = ms} = state,
        :incremental_search
      ) do
    if ms.input == "" do
      BufferServer.move_to(buf, ms.original_cursor)
      state
    else
      content = BufferServer.content(buf)

      case Minga.Search.find_next(content, ms.input, ms.original_cursor, ms.direction) do
        nil ->
          state

        {line, col} ->
          BufferServer.move_to(buf, {line, col})
          state
      end
    end
  end

  def execute(
        %{buffer: buf, mode_state: %SearchState{} = ms} = state,
        :confirm_search
      ) do
    content = BufferServer.content(buf)

    case Minga.Search.find_next(content, ms.input, ms.original_cursor, ms.direction) do
      nil ->
        %{
          state
          | last_search_pattern: ms.input,
            last_search_direction: ms.direction,
            status_msg: "Pattern not found: #{ms.input}"
        }

      {line, col} ->
        BufferServer.move_to(buf, {line, col})
        %{state | last_search_pattern: ms.input, last_search_direction: ms.direction}
    end
  end

  def execute(
        %{buffer: buf, mode_state: %SearchState{} = ms} = state,
        :cancel_search
      ) do
    BufferServer.move_to(buf, ms.original_cursor)
    state
  end

  def execute(
        %{buffer: buf, last_search_pattern: pattern, last_search_direction: dir} = state,
        :search_next
      )
      when is_binary(pattern) do
    content = BufferServer.content(buf)
    cursor = BufferServer.cursor(buf)

    case Minga.Search.find_next(content, pattern, cursor, dir) do
      nil ->
        %{state | status_msg: "Pattern not found: #{pattern}"}

      {line, col} ->
        BufferServer.move_to(buf, {line, col})
        state
    end
  end

  def execute(state, :search_next) do
    %{state | status_msg: "No previous search pattern"}
  end

  def execute(
        %{buffer: buf, last_search_pattern: pattern, last_search_direction: dir} = state,
        :search_prev
      )
      when is_binary(pattern) do
    reverse = if dir == :forward, do: :backward, else: :forward
    content = BufferServer.content(buf)
    cursor = BufferServer.cursor(buf)

    case Minga.Search.find_next(content, pattern, cursor, reverse) do
      nil ->
        %{state | status_msg: "Pattern not found: #{pattern}"}

      {line, col} ->
        BufferServer.move_to(buf, {line, col})
        state
    end
  end

  def execute(state, :search_prev) do
    %{state | status_msg: "No previous search pattern"}
  end

  def execute(%{buffer: buf} = state, :search_word_under_cursor_forward) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)

    case Minga.Search.word_at_cursor(tmp_buf, cursor) do
      nil ->
        %{state | status_msg: "No word under cursor"}

      word ->
        case Minga.Search.find_next(content, word, cursor, :forward) do
          nil ->
            %{
              state
              | last_search_pattern: word,
                last_search_direction: :forward,
                status_msg: "Pattern not found: #{word}"
            }

          {line, col} ->
            BufferServer.move_to(buf, {line, col})
            %{state | last_search_pattern: word, last_search_direction: :forward}
        end
    end
  end

  def execute(%{buffer: buf} = state, :search_word_under_cursor_backward) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)

    case Minga.Search.word_at_cursor(tmp_buf, cursor) do
      nil ->
        %{state | status_msg: "No word under cursor"}

      word ->
        case Minga.Search.find_next(content, word, cursor, :backward) do
          nil ->
            %{
              state
              | last_search_pattern: word,
                last_search_direction: :backward,
                status_msg: "Pattern not found: #{word}"
            }

          {line, col} ->
            BufferServer.move_to(buf, {line, col})
            %{state | last_search_pattern: word, last_search_direction: :backward}
        end
    end
  end

  @doc "Executes a `:substitute` ex-command against the buffer."
  @spec execute_substitute(state(), pid(), String.t(), String.t(), boolean()) :: state()
  def execute_substitute(state, buf, pattern, replacement, global?) do
    content = BufferServer.content(buf)
    {new_content, count} = Minga.Search.substitute(content, pattern, replacement, global?)

    if count == 0 do
      %{state | status_msg: "Pattern not found: #{pattern}"}
    else
      cursor = BufferServer.cursor(buf)
      BufferServer.replace_content(buf, new_content)
      {line, col} = cursor
      total = BufferServer.line_count(buf)
      safe_line = min(line, max(0, total - 1))

      safe_col =
        case BufferServer.get_lines(buf, safe_line, 1) do
          [text] -> min(col, max(0, String.length(text) - 1))
          _ -> 0
        end

      BufferServer.move_to(buf, {safe_line, safe_col})

      msg = if count == 1, do: "1 substitution", else: "#{count} substitutions"
      %{state | status_msg: msg, last_search_pattern: pattern}
    end
  end
end
