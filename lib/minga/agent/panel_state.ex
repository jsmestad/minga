defmodule Minga.Agent.PanelState do
  @moduledoc """
  State for the agent chat panel UI.

  Tracks visibility, scroll position, multi-line input with cursor,
  prompt history, spinner animation, and other UI-only concerns.
  Stored in `Editor.State` and updated by agent event handlers.
  """

  alias Minga.Scroll

  @typedoc "Thinking level for models that support extended reasoning."
  @type thinking_level :: String.t()

  @typedoc "Cursor position within the input: `{line_index, column_index}` (0-based)."
  @type cursor :: {non_neg_integer(), non_neg_integer()}

  @typedoc "A collapsed paste block. Stores the original text and whether the block is currently expanded for editing."
  @type paste_block :: %{text: String.t(), expanded: boolean()}

  @typedoc "Agent panel UI state."
  @type t :: %__MODULE__{
          visible: boolean(),
          scroll: Scroll.t(),
          input_lines: [String.t()],
          input_cursor: cursor(),
          prompt_history: [String.t()],
          history_index: integer(),
          spinner_frame: non_neg_integer(),
          provider_name: String.t(),
          model_name: String.t(),
          thinking_level: thinking_level(),
          input_focused: boolean(),
          display_start_index: non_neg_integer(),
          mention_completion: Minga.Agent.FileMention.completion() | nil,
          pasted_blocks: [paste_block()]
        }

  # Placeholder prefix used in input_lines to represent a collapsed paste block.
  # The format is "\0PASTE:<index>" where index is the 0-based position in pasted_blocks.
  # NUL byte prefix ensures this can never be typed by the user.
  @paste_placeholder_prefix "\0PASTE:"

  # Minimum number of lines for a paste to be collapsed.
  # Pastes with fewer lines are inserted as normal text.
  @paste_collapse_threshold 3

  @enforce_keys []
  defstruct visible: false,
            scroll: %Scroll{},
            input_lines: [""],
            input_cursor: {0, 0},
            prompt_history: [],
            history_index: -1,
            spinner_frame: 0,
            provider_name: "anthropic",
            model_name: "claude-sonnet-4",
            thinking_level: "medium",
            input_focused: false,
            display_start_index: 0,
            mention_completion: nil,
            pasted_blocks: []

  @doc "Creates a new panel state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Toggles panel visibility."
  @spec toggle(t()) :: t()
  def toggle(%__MODULE__{} = state) do
    %{state | visible: !state.visible}
  end

  @doc "Advances the spinner animation frame."
  @spec tick_spinner(t()) :: t()
  def tick_spinner(%__MODULE__{} = state) do
    %{state | spinner_frame: state.spinner_frame + 1}
  end

  # ── Input editing ───────────────────────────────────────────────────────────

  @doc """
  Returns the full input text by joining lines with newlines.

  Paste placeholder tokens are substituted with the full text from
  their corresponding pasted_blocks entry, so the returned string
  contains the complete content the user intends to submit.
  """
  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{input_lines: lines, pasted_blocks: blocks}) do
    Enum.map_join(lines, "\n", fn line -> substitute_placeholder(line, blocks) end)
  end

  @doc "Inserts a character at the cursor position."
  @spec insert_char(t(), String.t()) :: t()
  def insert_char(%__MODULE__{input_cursor: {line, col}, input_lines: lines} = state, char) do
    current = Enum.at(lines, line)
    {before, after_cursor} = String.split_at(current, col)
    updated = before <> char <> after_cursor
    new_lines = List.replace_at(lines, line, updated)

    %{
      state
      | input_lines: new_lines,
        input_cursor: {line, col + String.length(char)},
        history_index: -1
    }
  end

  @doc "Inserts a newline at the cursor, splitting the current line."
  @spec insert_newline(t()) :: t()
  def insert_newline(%__MODULE__{input_cursor: {line, col}, input_lines: lines} = state) do
    current = Enum.at(lines, line)
    {before, after_cursor} = String.split_at(current, col)

    new_lines =
      List.replace_at(lines, line, before)
      |> List.insert_at(line + 1, after_cursor)

    %{state | input_lines: new_lines, input_cursor: {line + 1, 0}, history_index: -1}
  end

  # ── Paste handling ────────────────────────────────────────────────────────

  @doc """
  Inserts pasted text into the input.

  For short pastes (fewer than #{@paste_collapse_threshold} lines), the text is
  inserted directly into the input as if typed. For longer pastes, the text is
  stored in `pasted_blocks` and a placeholder token is inserted at the cursor
  position. The placeholder renders as a compact indicator (e.g. "󰆏 [pasted 23 lines]")
  but `input_text/1` substitutes the full content when the prompt is submitted.
  """
  @spec insert_paste(t(), String.t()) :: t()
  def insert_paste(%__MODULE__{} = state, ""), do: state

  def insert_paste(%__MODULE__{} = state, text) do
    # Strip NUL bytes from paste to prevent fake placeholder injection
    clean_text = String.replace(text, "\0", "")

    lines = String.split(clean_text, "\n")
    line_count = length(lines)

    if line_count < @paste_collapse_threshold do
      insert_text_lines(state, lines)
    else
      insert_collapsed_paste(state, clean_text, line_count)
    end
  end

  @doc """
  Toggles expand/collapse on the paste block at the current cursor line.

  When the cursor is on a line containing a paste placeholder, the block
  is expanded (placeholder replaced with the actual text lines). When the
  cursor is within an expanded block's lines, the block is collapsed back
  to a placeholder. Returns the state unchanged if the cursor is not on
  a paste placeholder or within an expanded block.
  """
  @spec toggle_paste_expand(t()) :: t()
  def toggle_paste_expand(%__MODULE__{input_cursor: {cursor_line, _}, input_lines: lines} = state) do
    current_line = Enum.at(lines, cursor_line)

    case parse_placeholder(current_line) do
      {:ok, block_index} ->
        # Cursor is on a collapsed placeholder, expand it
        block = Enum.at(state.pasted_blocks, block_index)
        if block, do: expand_block(state, block_index), else: state

      :not_placeholder ->
        # Check if cursor is within an expanded block's text
        case find_expanded_block_at_cursor(state, cursor_line) do
          {:ok, block_index} -> collapse_block(state, block_index)
          :not_found -> state
        end
    end
  end

  @doc """
  Returns true if the given line is a paste placeholder token.
  """
  @spec paste_placeholder?(String.t()) :: boolean()
  def paste_placeholder?(line) do
    String.starts_with?(line, @paste_placeholder_prefix)
  end

  @doc """
  Returns the paste block index for a placeholder line, or nil if not a placeholder.
  """
  @spec paste_block_index(String.t()) :: non_neg_integer() | nil
  def paste_block_index(line) do
    case parse_placeholder(line) do
      {:ok, index} -> index
      :not_placeholder -> nil
    end
  end

  @doc """
  Returns the line count for a paste block at the given index.
  """
  @spec paste_block_line_count(t(), non_neg_integer()) :: non_neg_integer()
  def paste_block_line_count(%__MODULE__{pasted_blocks: blocks}, index) do
    case Enum.at(blocks, index) do
      %{text: text} ->
        text |> String.split("\n") |> length()

      nil ->
        0
    end
  end

  @doc """
  Deletes the character before the cursor.

  At the start of a line (col 0), joins with the previous line.
  At the start of the first line, no-op.
  """
  @spec delete_char(t()) :: t()
  def delete_char(%__MODULE__{input_cursor: {0, 0}} = state), do: state

  def delete_char(%__MODULE__{input_cursor: {line, 0}, input_lines: lines} = state) do
    # Join current line with previous line
    prev = Enum.at(lines, line - 1)
    current = Enum.at(lines, line)
    merged = prev <> current
    new_col = String.length(prev)

    new_lines =
      lines
      |> List.replace_at(line - 1, merged)
      |> List.delete_at(line)

    %{state | input_lines: new_lines, input_cursor: {line - 1, new_col}, history_index: -1}
  end

  def delete_char(%__MODULE__{input_cursor: {line, col}, input_lines: lines} = state) do
    current = Enum.at(lines, line)
    {before, after_cursor} = String.split_at(current, col)
    updated = String.slice(before, 0..-2//1) <> after_cursor
    new_lines = List.replace_at(lines, line, updated)
    %{state | input_lines: new_lines, input_cursor: {line, col - 1}, history_index: -1}
  end

  @doc "Clears the input (after submission). Saves current text to history first."
  @spec clear_input(t()) :: t()
  def clear_input(%__MODULE__{} = state) do
    state = save_to_history(state)
    %{state | input_lines: [""], input_cursor: {0, 0}, history_index: -1, pasted_blocks: []}
  end

  # ── Cursor movement ────────────────────────────────────────────────────────

  @doc "Moves cursor up within the input. Returns `:at_top` if already on the first line."
  @spec move_cursor_up(t()) :: t() | :at_top
  def move_cursor_up(%__MODULE__{input_cursor: {0, _}} = _state), do: :at_top

  def move_cursor_up(%__MODULE__{input_cursor: {line, col}, input_lines: lines} = state) do
    prev_line = Enum.at(lines, line - 1)
    new_col = min(col, String.length(prev_line))
    %{state | input_cursor: {line - 1, new_col}}
  end

  @doc "Moves cursor down within the input. Returns `:at_bottom` if already on the last line."
  @spec move_cursor_down(t()) :: t() | :at_bottom
  def move_cursor_down(%__MODULE__{input_cursor: {line, _}, input_lines: lines} = _state)
      when line >= length(lines) - 1,
      do: :at_bottom

  def move_cursor_down(%__MODULE__{input_cursor: {line, col}, input_lines: lines} = state) do
    next_line = Enum.at(lines, line + 1)
    new_col = min(col, String.length(next_line))
    %{state | input_cursor: {line + 1, new_col}}
  end

  # ── Prompt history ──────────────────────────────────────────────────────────

  @doc "Saves the current input to prompt history (if non-empty)."
  @spec save_to_history(t()) :: t()
  def save_to_history(%__MODULE__{input_lines: [""]} = state), do: state

  def save_to_history(%__MODULE__{} = state) do
    text = input_text(state)

    if String.trim(text) == "" do
      state
    else
      %{state | prompt_history: [text | state.prompt_history]}
    end
  end

  @doc "Recalls the previous prompt from history."
  @spec history_prev(t()) :: t()
  def history_prev(%__MODULE__{prompt_history: []} = state), do: state

  def history_prev(%__MODULE__{history_index: idx, prompt_history: history} = state) do
    new_idx = min(idx + 1, length(history) - 1)
    text = Enum.at(history, new_idx)
    lines = String.split(text, "\n")
    last_line = List.last(lines)
    cursor = {length(lines) - 1, String.length(last_line)}
    %{state | input_lines: lines, input_cursor: cursor, history_index: new_idx}
  end

  @doc "Recalls the next (more recent) prompt from history."
  @spec history_next(t()) :: t()
  def history_next(%__MODULE__{history_index: -1} = state), do: state

  def history_next(%__MODULE__{history_index: 0} = state) do
    %{state | input_lines: [""], input_cursor: {0, 0}, history_index: -1}
  end

  def history_next(%__MODULE__{history_index: idx, prompt_history: history} = state) do
    new_idx = idx - 1
    text = Enum.at(history, new_idx)
    lines = String.split(text, "\n")
    last_line = List.last(lines)
    cursor = {length(lines) - 1, String.length(last_line)}
    %{state | input_lines: lines, input_cursor: cursor, history_index: new_idx}
  end

  # ── Scrolling (delegates to Minga.Scroll) ────────────────────────────────

  @doc "Scrolls the content up. Delegates to `Minga.Scroll.scroll_up/2`."
  @spec scroll_up(t(), non_neg_integer()) :: t()
  def scroll_up(%__MODULE__{} = state, amount) do
    %{state | scroll: Scroll.scroll_up(state.scroll, amount)}
  end

  @doc "Scrolls the content down. Delegates to `Minga.Scroll.scroll_down/2`."
  @spec scroll_down(t(), non_neg_integer()) :: t()
  def scroll_down(%__MODULE__{} = state, amount) do
    %{state | scroll: Scroll.scroll_down(state.scroll, amount)}
  end

  @doc "Pins chat to bottom. Delegates to `Minga.Scroll.pin_to_bottom/1`."
  @spec scroll_to_bottom(t()) :: t()
  def scroll_to_bottom(%__MODULE__{} = state) do
    %{state | scroll: Scroll.pin_to_bottom(state.scroll)}
  end

  @doc "Scrolls to top. Delegates to `Minga.Scroll.scroll_to_top/1`."
  @spec scroll_to_top(t()) :: t()
  def scroll_to_top(%__MODULE__{} = state) do
    %{state | scroll: Scroll.scroll_to_top(state.scroll)}
  end

  @doc "No-op. Streaming events call this; renderer handles pinning."
  @spec maybe_auto_scroll(t()) :: t()
  def maybe_auto_scroll(%__MODULE__{} = state), do: state

  @doc "Re-engages auto-scroll. Delegates to `Minga.Scroll.pin_to_bottom/1`."
  @spec engage_auto_scroll(t()) :: t()
  def engage_auto_scroll(%__MODULE__{} = state) do
    %{state | scroll: Scroll.pin_to_bottom(state.scroll)}
  end

  @doc "Sets the input focus state."
  @spec set_input_focused(t(), boolean()) :: t()
  def set_input_focused(%__MODULE__{} = state, focused) do
    %{state | input_focused: focused}
  end

  @doc "Returns the number of input lines."
  @spec input_line_count(t()) :: pos_integer()
  def input_line_count(%__MODULE__{input_lines: lines}), do: length(lines)

  @doc """
  Clears the chat display without affecting conversation history.

  Sets `display_start_index` to the given message count so the renderer
  skips all messages before this point. Scrolls to bottom.
  """
  @spec clear_display(t(), non_neg_integer()) :: t()
  def clear_display(%__MODULE__{} = state, message_count) do
    %{state | display_start_index: message_count, scroll: Scroll.new()}
  end

  # ── Private: paste helpers ───────────────────────────────────────────────

  # Inserts text lines directly at the cursor, handling the split of the
  # current line and merging with surrounding content. Used for short pastes
  # that don't get collapsed.
  @spec insert_text_lines(t(), [String.t()]) :: t()
  defp insert_text_lines(
         %__MODULE__{input_cursor: {cursor_line, cursor_col}, input_lines: lines} = state,
         paste_lines
       ) do
    current = Enum.at(lines, cursor_line)
    {before, after_cursor} = String.split_at(current, cursor_col)

    new_lines =
      case paste_lines do
        [single] ->
          # Single line: merge into current line
          merged = before <> single <> after_cursor
          List.replace_at(lines, cursor_line, merged)

        [first | rest] ->
          # Multi-line: first line merges with before, last merges with after
          {middle, [last]} = Enum.split(rest, -1)
          first_merged = before <> first
          last_merged = last <> after_cursor

          pre = Enum.take(lines, cursor_line)
          post = Enum.drop(lines, cursor_line + 1)
          pre ++ [first_merged] ++ middle ++ [last_merged] ++ post
      end

    # Position cursor at end of last inserted paste line
    last_paste = List.last(paste_lines)
    new_cursor_line = cursor_line + length(paste_lines) - 1

    new_cursor_col =
      case paste_lines do
        [single] -> cursor_col + String.length(single)
        _ -> String.length(last_paste)
      end

    %{
      state
      | input_lines: new_lines,
        input_cursor: {new_cursor_line, new_cursor_col},
        history_index: -1
    }
  end

  # Creates a collapsed paste block and inserts a placeholder token at the
  # cursor position.
  @spec insert_collapsed_paste(t(), String.t(), pos_integer()) :: t()
  defp insert_collapsed_paste(
         %__MODULE__{
           input_cursor: {cursor_line, cursor_col},
           input_lines: lines,
           pasted_blocks: blocks
         } = state,
         text,
         _line_count
       ) do
    block_index = length(blocks)
    new_block = %{text: text, expanded: false}
    placeholder = @paste_placeholder_prefix <> Integer.to_string(block_index)

    current = Enum.at(lines, cursor_line)
    {before, after_cursor} = String.split_at(current, cursor_col)

    # Split into: before text, placeholder on its own line, after text
    new_lines =
      case {before, after_cursor} do
        {"", ""} ->
          # Cursor on empty line: just replace with placeholder
          List.replace_at(lines, cursor_line, placeholder)

        {"", _after} ->
          # Cursor at start of line: placeholder before remaining text
          pre = Enum.take(lines, cursor_line)
          post = Enum.drop(lines, cursor_line + 1)
          pre ++ [placeholder, after_cursor] ++ post

        {_before, ""} ->
          # Cursor at end of line: placeholder after existing text
          pre = Enum.take(lines, cursor_line + 1)
          post = Enum.drop(lines, cursor_line + 1)
          pre ++ [placeholder] ++ post

        {_before, _after} ->
          # Cursor in middle: split line around placeholder
          pre = Enum.take(lines, cursor_line)
          post = Enum.drop(lines, cursor_line + 1)
          pre ++ [before, placeholder, after_cursor] ++ post
      end

    # Position cursor on the line after the placeholder
    placeholder_line_idx = Enum.find_index(new_lines, &(&1 == placeholder))
    new_cursor_line = placeholder_line_idx + 1
    # If placeholder is the last line, stay on it
    new_cursor_line = min(new_cursor_line, length(new_lines) - 1)

    new_cursor_col =
      if new_cursor_line > placeholder_line_idx do
        # Cursor is on the line after placeholder
        0
      else
        # Placeholder was the last line, cursor stays on it
        String.length(placeholder)
      end

    %{
      state
      | input_lines: new_lines,
        input_cursor: {new_cursor_line, new_cursor_col},
        pasted_blocks: blocks ++ [new_block],
        history_index: -1
    }
  end

  # Expands a collapsed paste block: replaces the placeholder with actual text lines.
  @spec expand_block(t(), non_neg_integer()) :: t()
  defp expand_block(
         %__MODULE__{input_cursor: {cursor_line, _}, input_lines: lines, pasted_blocks: blocks} =
           state,
         block_index
       ) do
    block = Enum.at(blocks, block_index)
    placeholder = @paste_placeholder_prefix <> Integer.to_string(block_index)
    placeholder_line_idx = Enum.find_index(lines, &(&1 == placeholder))

    if placeholder_line_idx do
      text_lines = String.split(block.text, "\n")

      new_lines =
        Enum.take(lines, placeholder_line_idx) ++
          text_lines ++
          Enum.drop(lines, placeholder_line_idx + 1)

      # Update the block to expanded
      new_blocks = List.update_at(blocks, block_index, &%{&1 | expanded: true})

      # Adjust cursor: if it was on or after the placeholder, shift by the expansion
      expansion = length(text_lines) - 1

      new_cursor_line =
        if cursor_line > placeholder_line_idx do
          cursor_line + expansion
        else
          cursor_line
        end

      %{
        state
        | input_lines: new_lines,
          input_cursor: {new_cursor_line, 0},
          pasted_blocks: new_blocks
      }
    else
      state
    end
  end

  # Collapses an expanded paste block: replaces text lines with the placeholder.
  @spec collapse_block(t(), non_neg_integer()) :: t()
  defp collapse_block(
         %__MODULE__{input_cursor: {cursor_line, _}, input_lines: lines, pasted_blocks: blocks} =
           state,
         block_index
       ) do
    block = Enum.at(blocks, block_index)
    text_lines = String.split(block.text, "\n")
    text_line_count = length(text_lines)

    # Find where the expanded text starts. We need to find the first line
    # that matches the first line of the block's text. We search for the
    # exact sequence of lines matching the block's text.
    start_idx = find_expanded_block_start(lines, text_lines)

    if start_idx do
      placeholder = @paste_placeholder_prefix <> Integer.to_string(block_index)

      new_lines =
        Enum.take(lines, start_idx) ++
          [placeholder] ++
          Enum.drop(lines, start_idx + text_line_count)

      new_blocks = List.update_at(blocks, block_index, &%{&1 | expanded: false})

      # Adjust cursor position
      contraction = text_line_count - 1
      new_cursor_line = collapse_cursor_line(cursor_line, start_idx, text_line_count, contraction)

      %{
        state
        | input_lines: new_lines,
          input_cursor: {new_cursor_line, 0},
          pasted_blocks: new_blocks
      }
    else
      state
    end
  end

  # Computes the new cursor line after collapsing a block.
  @spec collapse_cursor_line(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp collapse_cursor_line(cursor_line, start_idx, text_line_count, _contraction)
       when cursor_line >= start_idx and cursor_line < start_idx + text_line_count,
       do: start_idx

  defp collapse_cursor_line(cursor_line, start_idx, text_line_count, contraction)
       when cursor_line >= start_idx + text_line_count,
       do: cursor_line - contraction

  defp collapse_cursor_line(cursor_line, _start_idx, _text_line_count, _contraction),
    do: cursor_line

  # Finds which expanded paste block (if any) contains the given cursor line.
  # Returns {:ok, block_index} or :not_found.
  @spec find_expanded_block_at_cursor(t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :not_found
  defp find_expanded_block_at_cursor(
         %__MODULE__{input_lines: lines, pasted_blocks: blocks},
         cursor_line
       ) do
    blocks
    |> Enum.with_index()
    |> Enum.find_value(:not_found, fn {block, index} ->
      if block.expanded do
        expanded_block_contains_cursor?(lines, block, index, cursor_line)
      end
    end)
  end

  # Checks if an expanded block's text lines contain the cursor line.
  @spec expanded_block_contains_cursor?(
          [String.t()],
          paste_block(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:ok, non_neg_integer()} | nil
  defp expanded_block_contains_cursor?(lines, block, index, cursor_line) do
    text_lines = String.split(block.text, "\n")
    start_idx = find_expanded_block_start(lines, text_lines)

    if start_idx do
      end_idx = start_idx + length(text_lines) - 1
      if cursor_line >= start_idx and cursor_line <= end_idx, do: {:ok, index}
    end
  end

  # Finds where an expanded block's text lines start in input_lines.
  @spec find_expanded_block_start([String.t()], [String.t()]) :: non_neg_integer() | nil
  defp find_expanded_block_start(input_lines, text_lines) do
    text_len = length(text_lines)
    max_start = length(input_lines) - text_len

    if max_start < 0 do
      nil
    else
      Enum.find(0..max_start, fn start ->
        Enum.slice(input_lines, start, text_len) == text_lines
      end)
    end
  end

  # Parses a placeholder line to extract the block index.
  @spec parse_placeholder(String.t()) :: {:ok, non_neg_integer()} | :not_placeholder
  defp parse_placeholder(line) do
    case line do
      <<@paste_placeholder_prefix, rest::binary>> when byte_size(rest) > 0 ->
        case Integer.parse(rest) do
          {index, ""} when index >= 0 -> {:ok, index}
          _ -> :not_placeholder
        end

      _ ->
        :not_placeholder
    end
  end

  # Substitutes a paste placeholder in a line with the actual text.
  # Non-placeholder lines are returned unchanged.
  @spec substitute_placeholder(String.t(), [paste_block()]) :: String.t()
  defp substitute_placeholder(line, blocks) do
    case parse_placeholder(line) do
      {:ok, index} ->
        case Enum.at(blocks, index) do
          %{text: text} -> text
          nil -> line
        end

      :not_placeholder ->
        line
    end
  end
end
