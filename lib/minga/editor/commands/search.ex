defmodule Minga.Editor.Commands.Search do
  @moduledoc """
  Search commands: incremental search, confirm/cancel, next/prev match, and
  word-under-cursor search.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Mode.SearchState
  alias Minga.ProjectSearch

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  def execute(
        %{buf: %{buffer: buf}, mode_state: %SearchState{} = ms} = state,
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
        %{buf: %{buffer: buf}, mode_state: %SearchState{} = ms} = state,
        :confirm_search
      ) do
    content = BufferServer.content(buf)

    case Minga.Search.find_next(content, ms.input, ms.original_cursor, ms.direction) do
      nil ->
        state
        |> put_in_search(:last_pattern, ms.input)
        |> put_in_search(:last_direction, ms.direction)
        |> Map.put(:status_msg, "Pattern not found: #{ms.input}")

      {line, col} ->
        BufferServer.move_to(buf, {line, col})

        state
        |> put_in_search(:last_pattern, ms.input)
        |> put_in_search(:last_direction, ms.direction)
    end
  end

  def execute(
        %{buf: %{buffer: buf}, mode_state: %SearchState{} = ms} = state,
        :cancel_search
      ) do
    BufferServer.move_to(buf, ms.original_cursor)
    state
  end

  def execute(
        %{buf: %{buffer: buf}, search: %{last_pattern: pattern, last_direction: dir}} = state,
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
        %{buf: %{buffer: buf}, search: %{last_pattern: pattern, last_direction: dir}} = state,
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

  def execute(%{buf: %{buffer: buf}} = state, :search_word_under_cursor_forward) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = Document.new(content)

    case Minga.Search.word_at_cursor(tmp_buf, cursor) do
      nil ->
        %{state | status_msg: "No word under cursor"}

      word ->
        case Minga.Search.find_next(content, word, cursor, :forward) do
          nil ->
            state
            |> put_in_search(:last_pattern, word)
            |> put_in_search(:last_direction, :forward)
            |> Map.put(:status_msg, "Pattern not found: #{word}")

          {line, col} ->
            BufferServer.move_to(buf, {line, col})

            state
            |> put_in_search(:last_pattern, word)
            |> put_in_search(:last_direction, :forward)
        end
    end
  end

  def execute(%{buf: %{buffer: buf}} = state, :search_word_under_cursor_backward) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = Document.new(content)

    case Minga.Search.word_at_cursor(tmp_buf, cursor) do
      nil ->
        %{state | status_msg: "No word under cursor"}

      word ->
        case Minga.Search.find_next(content, word, cursor, :backward) do
          nil ->
            state
            |> put_in_search(:last_pattern, word)
            |> put_in_search(:last_direction, :backward)
            |> Map.put(:status_msg, "Pattern not found: #{word}")

          {line, col} ->
            BufferServer.move_to(buf, {line, col})

            state
            |> put_in_search(:last_pattern, word)
            |> put_in_search(:last_direction, :backward)
        end
    end
  end

  def execute(%{mode_state: %{input: query}} = state, :confirm_project_search)
      when is_binary(query) and query != "" do
    case ProjectSearch.search(query) do
      {:ok, [], _truncated?} ->
        %{state | status_msg: "No results for: #{query}"}

      {:ok, matches, truncated?} ->
        msg = if truncated?, do: "Results truncated to 10,000", else: nil

        state = put_in(state.search.project_results, matches)
        state = PickerUI.open(state, Minga.Picker.ProjectSearchSource)
        if msg, do: %{state | status_msg: msg}, else: state

      {:error, msg} ->
        %{state | status_msg: msg}
    end
  end

  def execute(state, :confirm_project_search) do
    %{state | status_msg: "Empty search query"}
  end

  # Advance cursor to current match during substitute confirm
  def execute(
        %{buf: %{buffer: buf}, mode_state: %Minga.Mode.SubstituteConfirmState{} = ms} = state,
        :substitute_confirm_advance
      ) do
    case Enum.at(ms.matches, ms.current) do
      {line, col, _len} -> BufferServer.move_to(buf, {line, col})
      _ -> :ok
    end

    state
  end

  def execute(state, :substitute_confirm_advance), do: state

  # Apply accepted substitutions from confirm mode
  def execute(
        %{buf: %{buffer: buf}, mode_state: %Minga.Mode.SubstituteConfirmState{} = ms} = state,
        :apply_substitute_confirm
      ) do
    accepted_set = MapSet.new(ms.accepted)
    accepted_count = MapSet.size(accepted_set)
    total = length(ms.matches)

    if accepted_count == 0 do
      %{state | status_msg: "No substitutions made"}
    else
      # Apply replacements in reverse order to preserve positions
      sorted_indices =
        ms.accepted
        |> Enum.sort(:desc)

      new_content =
        Enum.reduce(sorted_indices, ms.original_content, fn idx, content ->
          {line, col, len} = Enum.at(ms.matches, idx)
          replace_match(content, line, col, len, ms.replacement)
        end)

      BufferServer.replace_content(buf, new_content)

      # Restore cursor to a safe position
      cursor_line = elem(hd(ms.matches), 0)
      total_lines = BufferServer.line_count(buf)
      safe_line = min(cursor_line, max(0, total_lines - 1))
      BufferServer.move_to(buf, {safe_line, 0})

      msg =
        if accepted_count == 1,
          do: "1 substitution",
          else: "#{accepted_count} of #{total} substitutions"

      state
      |> put_in_search(:last_pattern, ms.pattern)
      |> Map.put(:status_msg, msg)
    end
  end

  def execute(state, :apply_substitute_confirm), do: state

  @doc "Starts substitute confirm mode by finding all matches and transitioning."
  @spec start_substitute_confirm(state(), pid(), String.t(), String.t(), boolean()) :: state()
  def start_substitute_confirm(state, buf, pattern, replacement, global?) do
    content = BufferServer.content(buf)
    lines = String.split(content, "\n")
    all_matches = Minga.Search.find_all_in_range(lines, pattern, 0)

    # When not global, keep only the first match per line
    matches =
      if global? do
        all_matches
      else
        all_matches
        |> Enum.group_by(fn {line, _col, _len} -> line end)
        |> Enum.flat_map(fn {_line, line_matches} -> [hd(line_matches)] end)
        |> Enum.sort()
      end

    case matches do
      [] ->
        %{state | status_msg: "Pattern not found: #{pattern}"}

      _ ->
        {first_line, first_col, _len} = hd(matches)
        BufferServer.move_to(buf, {first_line, first_col})

        ms = %Minga.Mode.SubstituteConfirmState{
          matches: matches,
          pattern: pattern,
          replacement: replacement,
          original_content: content
        }

        state
        |> put_in_search(:last_pattern, pattern)
        |> Map.merge(%{mode: :substitute_confirm, mode_state: ms})
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
          [text] when byte_size(text) > 0 ->
            min(col, Unicode.last_grapheme_byte_offset(text))

          _ ->
            0
        end

      BufferServer.move_to(buf, {safe_line, safe_col})

      msg = if count == 1, do: "1 substitution", else: "#{count} substitutions"

      state
      |> put_in_search(:last_pattern, pattern)
      |> Map.put(:status_msg, msg)
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec put_in_search(state(), atom(), term()) :: state()
  defp put_in_search(state, :last_pattern, value) do
    %{state | search: Minga.Editor.State.Search.record_pattern(state.search, value)}
  end

  defp put_in_search(state, :last_direction, value) do
    %{state | search: %{state.search | last_direction: value}}
  end

  # Replace a match at a specific line/col/length in content string.
  @spec replace_match(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) ::
          String.t()
  defp replace_match(content, match_line, match_col, match_len, replacement) do
    lines = String.split(content, "\n")

    new_lines =
      List.update_at(lines, match_line, fn line ->
        before = binary_part(line, 0, match_col)

        after_match =
          binary_part(line, match_col + match_len, byte_size(line) - match_col - match_len)

        before <> replacement <> after_match
      end)

    Enum.join(new_lines, "\n")
  end
end
