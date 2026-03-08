defmodule Minga.Agent.PanelState do
  @moduledoc """
  State for the agent chat panel UI.

  Tracks visibility, scroll position, multi-line input with cursor,
  prompt history, spinner animation, and other UI-only concerns.
  Stored in `Editor.State` and updated by agent event handlers.
  """

  @typedoc "Thinking level for models that support extended reasoning."
  @type thinking_level :: String.t()

  @typedoc "Cursor position within the input: `{line_index, column_index}` (0-based)."
  @type cursor :: {non_neg_integer(), non_neg_integer()}

  @typedoc "Agent panel UI state."
  @type t :: %__MODULE__{
          visible: boolean(),
          scroll_offset: non_neg_integer(),
          input_lines: [String.t()],
          input_cursor: cursor(),
          prompt_history: [String.t()],
          history_index: integer(),
          spinner_frame: non_neg_integer(),
          provider_name: String.t(),
          model_name: String.t(),
          thinking_level: thinking_level(),
          input_focused: boolean(),
          auto_scroll: boolean(),
          display_start_index: non_neg_integer(),
          mention_completion: Minga.Agent.FileMention.completion() | nil
        }

  @enforce_keys []
  defstruct visible: false,
            scroll_offset: 0,
            input_lines: [""],
            input_cursor: {0, 0},
            prompt_history: [],
            history_index: -1,
            spinner_frame: 0,
            provider_name: "anthropic",
            model_name: "claude-sonnet-4",
            thinking_level: "medium",
            input_focused: false,
            auto_scroll: true,
            display_start_index: 0,
            mention_completion: nil

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

  @doc "Returns the full input text by joining lines with newlines."
  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{input_lines: lines}), do: Enum.join(lines, "\n")

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
    %{state | input_lines: [""], input_cursor: {0, 0}, history_index: -1}
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

  # ── Scrolling ──────────────────────────────────────────────────────────────

  @doc "Scrolls the content up by the given number of lines. Disengages auto-scroll."
  @spec scroll_up(t(), non_neg_integer()) :: t()
  def scroll_up(%__MODULE__{} = state, amount) do
    %{state | scroll_offset: max(state.scroll_offset - amount, 0), auto_scroll: false}
  end

  @doc "Scrolls the content down by the given number of lines. Disengages auto-scroll."
  @spec scroll_down(t(), non_neg_integer()) :: t()
  def scroll_down(%__MODULE__{} = state, amount) do
    %{state | scroll_offset: state.scroll_offset + amount, auto_scroll: false}
  end

  @doc "Scrolls to the bottom and re-engages auto-scroll."
  @spec scroll_to_bottom(t()) :: t()
  def scroll_to_bottom(%__MODULE__{} = state) do
    %{state | scroll_offset: 999_999, auto_scroll: true}
  end

  @doc "Scrolls to the top of the chat. Disengages auto-scroll."
  @spec scroll_to_top(t()) :: t()
  def scroll_to_top(%__MODULE__{} = state) do
    %{state | scroll_offset: 0, auto_scroll: false}
  end

  @doc """
  Scrolls to the bottom only if auto-scroll is engaged.

  Called by event handlers when new streaming content arrives. No-ops if the
  user has manually scrolled away from the bottom.
  """
  @spec maybe_auto_scroll(t()) :: t()
  def maybe_auto_scroll(%__MODULE__{auto_scroll: true} = state), do: scroll_to_bottom(state)
  def maybe_auto_scroll(%__MODULE__{} = state), do: state

  @doc "Re-engages auto-scroll (e.g., on new agent turn start)."
  @spec engage_auto_scroll(t()) :: t()
  def engage_auto_scroll(%__MODULE__{} = state) do
    scroll_to_bottom(%{state | auto_scroll: true})
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
    %{state | display_start_index: message_count, scroll_offset: 0, auto_scroll: true}
  end
end
