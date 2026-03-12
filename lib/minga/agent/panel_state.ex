defmodule Minga.Agent.PanelState do
  @moduledoc """
  State for the agent chat panel UI.

  Tracks visibility, scroll position, prompt editing (via Buffer.Server),
  prompt history, spinner animation, and other UI-only concerns.
  Stored in `Editor.State` and updated by agent event handlers.

  The prompt is backed by a `Buffer.Server` process. All vim editing
  (motions, operators, visual mode, text objects, undo/redo) is handled
  by the standard Mode FSM routed through the prompt buffer, not by a
  reimplemented vim grammar. PanelState adds domain concerns on top:
  paste block collapsing, prompt history, mention completion, and input
  focus tracking.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Scroll

  @typedoc "Thinking level for models that support extended reasoning."
  @type thinking_level :: String.t()

  @typedoc "A collapsed paste block. Stores the original text and whether the block is currently expanded for editing."
  @type paste_block :: %{text: String.t(), expanded: boolean()}

  @typedoc "Vim mode for the input field when focused."
  @type input_mode :: :insert | :normal | :visual | :visual_line | :operator_pending

  @typedoc "Agent panel UI state."
  @type t :: %__MODULE__{
          visible: boolean(),
          scroll: Scroll.t(),
          prompt_buffer: pid() | nil,
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

  # Placeholder prefix used in input lines to represent a collapsed paste block.
  # The format is "\0PASTE:<index>" where index is the 0-based position in pasted_blocks.
  # NUL byte prefix ensures this can never be typed by the user.
  @paste_placeholder_prefix "\0PASTE:"

  # Minimum number of lines for a paste to be collapsed.
  # Pastes with fewer lines are inserted as normal text.
  @paste_collapse_threshold 3

  @enforce_keys []
  defstruct visible: false,
            scroll: %Scroll{},
            prompt_buffer: nil,
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

  # ── Prompt buffer lifecycle ─────────────────────────────────────────────

  @doc """
  Ensures a prompt Buffer.Server is running. Starts one if `prompt_buffer`
  is nil or the process is dead.

  Called lazily when the panel is first focused or made visible. The buffer
  is an unlisted, unnamed process owned by the editor. It does not appear
  in the buffer list or tab bar.
  """
  @spec ensure_prompt_buffer(t()) :: t()
  def ensure_prompt_buffer(%__MODULE__{prompt_buffer: pid} = state)
      when is_pid(pid) do
    if Process.alive?(pid), do: state, else: start_prompt_buffer(state, "")
  end

  def ensure_prompt_buffer(%__MODULE__{} = state), do: start_prompt_buffer(state, "")

  defp start_prompt_buffer(%__MODULE__{} = state, content) do
    {:ok, pid} = BufferServer.start_link(content: content)
    %{state | prompt_buffer: pid}
  end

  # ── Accessors ───────────────────────────────────────────────────────────

  @doc """
  Returns the prompt text with paste placeholders substituted.

  This is the text submitted to the LLM. Placeholder tokens are replaced
  with the full paste content from `pasted_blocks`.
  """
  @spec prompt_text(t()) :: String.t()
  def prompt_text(%__MODULE__{prompt_buffer: pid, pasted_blocks: blocks})
      when is_pid(pid) do
    content = BufferServer.content(pid)
    substitute_placeholders(content, blocks)
  end

  def prompt_text(%__MODULE__{}), do: ""

  @doc "Returns the raw input text (with placeholders, not substituted)."
  @spec input_text(t()) :: String.t()
  def input_text(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.content(pid)
  end

  def input_text(%__MODULE__{}), do: ""

  @doc "Returns the input lines as a list of strings."
  @spec input_lines(t()) :: [String.t()]
  def input_lines(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.content(pid) |> String.split("\n")
  end

  def input_lines(%__MODULE__{}), do: [""]

  @doc "Returns the input cursor position as `{line, col}`."
  @spec input_cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def input_cursor(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.cursor(pid)
  end

  def input_cursor(%__MODULE__{}), do: {0, 0}

  @doc "Returns the number of input lines."
  @spec input_line_count(t()) :: pos_integer()
  def input_line_count(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.line_count(pid)
  end

  def input_line_count(%__MODULE__{}), do: 1

  @doc "Returns true if the input is empty (single empty line)."
  @spec input_empty?(t()) :: boolean()
  def input_empty?(%__MODULE__{prompt_buffer: pid}) when is_pid(pid) do
    BufferServer.content(pid) == ""
  end

  def input_empty?(%__MODULE__{}), do: true

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

  # ── Input editing (delegates to Buffer.Server) ──────────────────────────

  @doc "Inserts a character at the cursor position."
  @spec insert_char(t(), String.t()) :: t()
  def insert_char(%__MODULE__{prompt_buffer: pid} = state, char) when is_pid(pid) do
    BufferServer.insert_text(pid, char)
    %{state | history_index: -1}
  end

  def insert_char(%__MODULE__{} = state, char) do
    state = ensure_prompt_buffer(state)
    insert_char(state, char)
  end

  @doc "Inserts a newline at the cursor, splitting the current line."
  @spec insert_newline(t()) :: t()
  def insert_newline(%__MODULE__{prompt_buffer: pid} = state) when is_pid(pid) do
    BufferServer.insert_text(pid, "\n")
    %{state | history_index: -1}
  end

  def insert_newline(%__MODULE__{} = state) do
    state = ensure_prompt_buffer(state)
    insert_newline(state)
  end

  @doc """
  Deletes the character before the cursor.

  At the start of a line (col 0), joins with the previous line.
  At the start of the first line, no-op.
  """
  @spec delete_char(t()) :: t()
  def delete_char(%__MODULE__{prompt_buffer: pid} = state) when is_pid(pid) do
    {line, col} = BufferServer.cursor(pid)

    if line == 0 and col == 0 do
      state
    else
      BufferServer.delete_before(pid)
    end

    %{state | history_index: -1}
  end

  def delete_char(%__MODULE__{} = state) do
    state = ensure_prompt_buffer(state)
    delete_char(state)
  end

  @doc "Clears the input (after submission). Saves current text to history first."
  @spec clear_input(t()) :: t()
  def clear_input(%__MODULE__{} = state) do
    state = save_to_history(state)

    if is_pid(state.prompt_buffer) do
      BufferServer.replace_content(state.prompt_buffer, "")
    end

    %{state | history_index: -1, pasted_blocks: []}
  end

  # ── Cursor movement ────────────────────────────────────────────────────

  @doc "Moves cursor up within the input. Returns `:at_top` if already on the first line."
  @spec move_cursor_up(t()) :: t() | :at_top
  def move_cursor_up(%__MODULE__{prompt_buffer: pid} = state) when is_pid(pid) do
    {line, _col} = BufferServer.cursor(pid)

    if line == 0 do
      :at_top
    else
      BufferServer.move_cursor(pid, :up)
      state
    end
  end

  def move_cursor_up(%__MODULE__{}), do: :at_top

  @doc "Moves cursor down within the input. Returns `:at_bottom` if already on the last line."
  @spec move_cursor_down(t()) :: t() | :at_bottom
  def move_cursor_down(%__MODULE__{prompt_buffer: pid} = state) when is_pid(pid) do
    {line, _col} = BufferServer.cursor(pid)
    total = BufferServer.line_count(pid)

    if line >= total - 1 do
      :at_bottom
    else
      BufferServer.move_cursor(pid, :down)
      state
    end
  end

  def move_cursor_down(%__MODULE__{}), do: :at_bottom

  # ── Paste handling ────────────────────────────────────────────────────────

  @doc """
  Inserts pasted text into the input.

  For short pastes (fewer than #{@paste_collapse_threshold} lines), the text is
  inserted directly into the buffer. For longer pastes, the text is
  stored in `pasted_blocks` and a placeholder token is inserted at the cursor
  position. The placeholder renders as a compact indicator (e.g. "󰆏 [pasted 23 lines]")
  but `prompt_text/1` substitutes the full content when the prompt is submitted.
  """
  @spec insert_paste(t(), String.t()) :: t()
  def insert_paste(%__MODULE__{} = state, ""), do: state

  def insert_paste(%__MODULE__{prompt_buffer: pid} = state, text) when is_pid(pid) do
    # Strip NUL bytes from paste to prevent fake placeholder injection
    clean_text = String.replace(text, "\0", "")
    lines = String.split(clean_text, "\n")
    line_count = length(lines)

    if line_count < @paste_collapse_threshold do
      BufferServer.insert_text(pid, clean_text)
      %{state | history_index: -1}
    else
      insert_collapsed_paste(state, clean_text)
    end
  end

  def insert_paste(%__MODULE__{} = state, text) do
    state = ensure_prompt_buffer(state)
    insert_paste(state, text)
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
  def toggle_paste_expand(%__MODULE__{prompt_buffer: pid} = state) when is_pid(pid) do
    {cursor_line, _} = BufferServer.cursor(pid)
    lines = input_lines(state)
    current_line = Enum.at(lines, cursor_line)

    case parse_placeholder(current_line) do
      {:ok, block_index} ->
        block = Enum.at(state.pasted_blocks, block_index)
        if block, do: expand_block(state, block_index), else: state

      :not_placeholder ->
        case find_expanded_block_at_cursor(state, cursor_line) do
          {:ok, block_index} -> collapse_block(state, block_index)
          :not_found -> state
        end
    end
  end

  def toggle_paste_expand(%__MODULE__{} = state), do: state

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
      %{text: text} -> text |> String.split("\n") |> length()
      nil -> 0
    end
  end

  # ── Prompt history ──────────────────────────────────────────────────────────

  @doc "Saves the current input to prompt history (if non-empty)."
  @spec save_to_history(t()) :: t()
  def save_to_history(%__MODULE__{} = state) do
    text = prompt_text(state)

    if String.trim(text) == "" do
      state
    else
      %{state | prompt_history: [text | state.prompt_history]}
    end
  end

  @doc "Recalls the previous prompt from history."
  @spec history_prev(t()) :: t()
  def history_prev(%__MODULE__{prompt_history: []} = state), do: state

  def history_prev(
        %__MODULE__{prompt_buffer: pid, history_index: idx, prompt_history: history} = state
      )
      when is_pid(pid) do
    new_idx = min(idx + 1, length(history) - 1)
    text = Enum.at(history, new_idx)
    BufferServer.replace_content(pid, text)
    %{state | history_index: new_idx}
  end

  def history_prev(%__MODULE__{} = state), do: state

  @doc "Recalls the next (more recent) prompt from history."
  @spec history_next(t()) :: t()
  def history_next(%__MODULE__{history_index: -1} = state), do: state

  def history_next(%__MODULE__{prompt_buffer: pid, history_index: 0} = state) when is_pid(pid) do
    BufferServer.replace_content(pid, "")
    %{state | history_index: -1}
  end

  def history_next(
        %__MODULE__{prompt_buffer: pid, history_index: idx, prompt_history: history} = state
      )
      when is_pid(pid) do
    new_idx = idx - 1
    text = Enum.at(history, new_idx)
    BufferServer.replace_content(pid, text)
    %{state | history_index: new_idx}
  end

  def history_next(%__MODULE__{} = state), do: state

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

  @doc "Sets the input focus state. Entering focus ensures the prompt buffer exists."
  @spec set_input_focused(t(), boolean()) :: t()
  def set_input_focused(%__MODULE__{} = state, true) do
    state = ensure_prompt_buffer(state)
    %{state | input_focused: true}
  end

  def set_input_focused(%__MODULE__{} = state, false) do
    %{state | input_focused: false}
  end

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

  # Creates a collapsed paste block and inserts a placeholder token at the
  # cursor position in the buffer.
  @spec insert_collapsed_paste(t(), String.t()) :: t()
  defp insert_collapsed_paste(
         %__MODULE__{prompt_buffer: pid, pasted_blocks: blocks} = state,
         text
       ) do
    {cursor_line, cursor_col} = BufferServer.cursor(pid)
    lines = input_lines(state)

    block_index = length(blocks)
    new_block = %{text: text, expanded: false}
    placeholder = @paste_placeholder_prefix <> Integer.to_string(block_index)

    current = Enum.at(lines, cursor_line)
    {before, after_cursor} = String.split_at(current, cursor_col)

    # Build new content with placeholder inserted
    new_lines = insert_placeholder_lines(lines, cursor_line, before, after_cursor, placeholder)
    new_content = Enum.join(new_lines, "\n")

    # Position cursor on the line after the placeholder
    placeholder_line_idx = Enum.find_index(new_lines, &(&1 == placeholder))
    new_cursor_line = min(placeholder_line_idx + 1, length(new_lines) - 1)

    new_cursor_col =
      if new_cursor_line > placeholder_line_idx, do: 0, else: String.length(placeholder)

    BufferServer.replace_content(pid, new_content)
    BufferServer.set_cursor(pid, {new_cursor_line, new_cursor_col})

    %{state | pasted_blocks: blocks ++ [new_block], history_index: -1}
  end

  # Determines how to insert a placeholder into the line list based on
  # cursor position within the current line.
  @spec insert_placeholder_lines(
          [String.t()],
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          [String.t()]
  defp insert_placeholder_lines(lines, cursor_line, "", "", placeholder) do
    List.replace_at(lines, cursor_line, placeholder)
  end

  defp insert_placeholder_lines(lines, cursor_line, "", after_cursor, placeholder) do
    pre = Enum.take(lines, cursor_line)
    post = Enum.drop(lines, cursor_line + 1)
    pre ++ [placeholder, after_cursor] ++ post
  end

  defp insert_placeholder_lines(lines, cursor_line, _before, "", placeholder) do
    pre = Enum.take(lines, cursor_line + 1)
    post = Enum.drop(lines, cursor_line + 1)
    pre ++ [placeholder] ++ post
  end

  defp insert_placeholder_lines(lines, cursor_line, before, after_cursor, placeholder) do
    pre = Enum.take(lines, cursor_line)
    post = Enum.drop(lines, cursor_line + 1)
    pre ++ [before, placeholder, after_cursor] ++ post
  end

  # Expands a collapsed paste block: replaces the placeholder with actual text lines.
  @spec expand_block(t(), non_neg_integer()) :: t()
  defp expand_block(%__MODULE__{prompt_buffer: pid, pasted_blocks: blocks} = state, block_index) do
    {cursor_line, _} = BufferServer.cursor(pid)
    lines = input_lines(state)
    block = Enum.at(blocks, block_index)
    placeholder = @paste_placeholder_prefix <> Integer.to_string(block_index)
    placeholder_line_idx = Enum.find_index(lines, &(&1 == placeholder))

    if placeholder_line_idx do
      text_lines = String.split(block.text, "\n")

      new_lines =
        Enum.take(lines, placeholder_line_idx) ++
          text_lines ++
          Enum.drop(lines, placeholder_line_idx + 1)

      new_blocks = List.update_at(blocks, block_index, &%{&1 | expanded: true})
      expansion = length(text_lines) - 1

      new_cursor_line =
        if cursor_line > placeholder_line_idx, do: cursor_line + expansion, else: cursor_line

      BufferServer.replace_content(pid, Enum.join(new_lines, "\n"))
      BufferServer.set_cursor(pid, {new_cursor_line, 0})

      %{state | pasted_blocks: new_blocks}
    else
      state
    end
  end

  # Collapses an expanded paste block: replaces text lines with the placeholder.
  @spec collapse_block(t(), non_neg_integer()) :: t()
  defp collapse_block(%__MODULE__{prompt_buffer: pid, pasted_blocks: blocks} = state, block_index) do
    {cursor_line, _} = BufferServer.cursor(pid)
    lines = input_lines(state)
    block = Enum.at(blocks, block_index)
    text_lines = String.split(block.text, "\n")
    text_line_count = length(text_lines)

    start_idx = find_expanded_block_start(lines, text_lines)

    if start_idx do
      placeholder = @paste_placeholder_prefix <> Integer.to_string(block_index)

      new_lines =
        Enum.take(lines, start_idx) ++
          [placeholder] ++
          Enum.drop(lines, start_idx + text_line_count)

      new_blocks = List.update_at(blocks, block_index, &%{&1 | expanded: false})
      contraction = text_line_count - 1
      new_cursor_line = collapse_cursor_line(cursor_line, start_idx, text_line_count, contraction)

      BufferServer.replace_content(pid, Enum.join(new_lines, "\n"))
      BufferServer.set_cursor(pid, {new_cursor_line, 0})

      %{state | pasted_blocks: new_blocks}
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
  @spec find_expanded_block_at_cursor(t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :not_found
  defp find_expanded_block_at_cursor(%__MODULE__{} = state, cursor_line) do
    lines = input_lines(state)

    state.pasted_blocks
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
        ) :: {:ok, non_neg_integer()} | nil
  defp expanded_block_contains_cursor?(lines, block, index, cursor_line) do
    text_lines = String.split(block.text, "\n")
    start_idx = find_expanded_block_start(lines, text_lines)

    if start_idx do
      end_idx = start_idx + length(text_lines) - 1
      if cursor_line >= start_idx and cursor_line <= end_idx, do: {:ok, index}
    end
  end

  # Finds where an expanded block's text lines start in input lines.
  @spec find_expanded_block_start([String.t()], [String.t()]) :: non_neg_integer() | nil
  defp find_expanded_block_start(input_lines_list, text_lines) do
    text_len = length(text_lines)
    max_start = length(input_lines_list) - text_len

    if max_start < 0 do
      nil
    else
      Enum.find(0..max_start, fn start ->
        Enum.slice(input_lines_list, start, text_len) == text_lines
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

  # Substitutes paste placeholders in a multi-line string.
  @spec substitute_placeholders(String.t(), [paste_block()]) :: String.t()
  defp substitute_placeholders(content, blocks) do
    String.split(content, "\n")
    |> Enum.map_join("\n", fn line -> substitute_placeholder(line, blocks) end)
  end

  # Substitutes a paste placeholder in a line with the actual text.
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
