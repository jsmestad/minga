defmodule MingaEditor.Agent.PromptBuffer do
  @moduledoc """
  Workflow for the agent prompt's process-backed text buffer.

  The existing `Minga.Buffer.Process` remains authoritative for prompt text and
  cursor position. `MingaEditor.Agent.UIState` owns only prompt metadata and the
  attached buffer pid; this workflow coordinates both boundaries.
  """

  alias Minga.Buffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel

  @paste_placeholder_prefix "\0PASTE:"
  @paste_collapse_threshold 3

  @doc "Ensures the prompt buffer is alive and attached to the UI metadata."
  @spec ensure(UIState.t()) :: UIState.t()
  def ensure(%UIState{panel: %Panel{prompt_buffer: pid}} = state) when is_pid(pid) do
    Buffer.buffer_name(pid)
    state
  catch
    :exit, _ -> start(state, "")
  end

  def ensure(%UIState{} = state), do: start(state, "")

  @doc "Returns prompt text with collapsed paste placeholders expanded."
  @spec prompt_text(UIState.t() | Panel.t()) :: String.t()
  def prompt_text(%UIState{panel: panel}), do: prompt_text(panel)

  def prompt_text(%Panel{prompt_buffer: pid, pasted_blocks: blocks}) when is_pid(pid) do
    pid |> Buffer.content() |> substitute_placeholders(blocks)
  end

  def prompt_text(%Panel{}), do: ""

  @doc "Returns raw prompt-buffer text without paste substitution."
  @spec input_text(UIState.t() | Panel.t()) :: String.t()
  def input_text(value), do: value |> panel() |> buffer_content("")

  @doc "Returns raw prompt-buffer lines."
  @spec input_lines(UIState.t() | Panel.t()) :: [String.t()]
  def input_lines(value), do: value |> input_text() |> String.split("\n")

  @doc "Returns the current prompt cursor."
  @spec input_cursor(UIState.t() | Panel.t()) :: {non_neg_integer(), non_neg_integer()}
  def input_cursor(value) do
    case panel(value).prompt_buffer do
      pid when is_pid(pid) -> Buffer.cursor(pid)
      _other -> {0, 0}
    end
  end

  @doc "Returns the prompt line count."
  @spec input_line_count(UIState.t() | Panel.t()) :: pos_integer()
  def input_line_count(value) do
    case panel(value).prompt_buffer do
      pid when is_pid(pid) -> Buffer.line_count(pid)
      _other -> 1
    end
  end

  @doc "Returns whether the prompt buffer is empty."
  @spec input_empty?(UIState.t() | Panel.t()) :: boolean()
  def input_empty?(value), do: input_text(value) == ""

  @doc "Attaches a live prompt buffer before focusing the input."
  @spec set_input_focused(UIState.t(), boolean()) :: UIState.t()
  def set_input_focused(%UIState{} = state, true),
    do: state |> ensure() |> UIState.set_input_focused(true)

  def set_input_focused(%UIState{} = state, false), do: UIState.set_input_focused(state, false)

  @doc "Inserts text at the prompt cursor."
  @spec insert_char(UIState.t(), String.t()) :: UIState.t()
  def insert_char(%UIState{} = state, text) when is_binary(text) do
    state = ensure(state)
    Buffer.insert_text(state.panel.prompt_buffer, text)
    UIState.record_prompt_edit(state)
  end

  @doc "Inserts a newline at the prompt cursor."
  @spec insert_newline(UIState.t()) :: UIState.t()
  def insert_newline(%UIState{} = state), do: insert_char(state, "\n")

  @doc "Deletes the character before the prompt cursor."
  @spec delete_char(UIState.t()) :: UIState.t()
  def delete_char(%UIState{} = state) do
    state = ensure(state)
    pid = state.panel.prompt_buffer

    if Buffer.cursor(pid) != {0, 0}, do: Buffer.delete_before(pid)
    UIState.record_prompt_edit(state)
  end

  @doc "Replaces prompt content without recording history."
  @spec set_prompt_text(UIState.t(), String.t()) :: UIState.t()
  def set_prompt_text(%UIState{panel: %Panel{prompt_buffer: pid}} = state, text)
      when is_pid(pid) and is_binary(text) do
    Buffer.replace_content(pid, text)
    UIState.reset_paste_metadata(state)
  end

  def set_prompt_text(%UIState{} = state, _text), do: state

  @doc "Clears prompt content without recording history."
  @spec clear_input_without_history(UIState.t()) :: UIState.t()
  def clear_input_without_history(%UIState{} = state) do
    if is_pid(state.panel.prompt_buffer),
      do: Buffer.replace_content(state.panel.prompt_buffer, "")

    UIState.reset_prompt_metadata(state)
  end

  @doc "Records the current prompt in history and clears the buffer."
  @spec clear_input(UIState.t()) :: UIState.t()
  def clear_input(%UIState{} = state) do
    state = save_to_history(state)

    if is_pid(state.panel.prompt_buffer),
      do: Buffer.replace_content(state.panel.prompt_buffer, "")

    UIState.reset_prompt_metadata(state)
  end

  @doc "Clears input and pins transcript scroll to the bottom."
  @spec clear_input_and_scroll(UIState.t()) :: UIState.t()
  def clear_input_and_scroll(%UIState{} = state),
    do: state |> clear_input() |> UIState.scroll_to_bottom()

  @doc "Clears sensitive input without history and pins transcript scroll."
  @spec clear_input_without_history_and_scroll(UIState.t()) :: UIState.t()
  def clear_input_without_history_and_scroll(%UIState{} = state),
    do: state |> clear_input_without_history() |> UIState.scroll_to_bottom()

  @doc "Moves the prompt cursor up, or returns `:at_top`."
  @spec move_cursor_up(UIState.t()) :: UIState.t() | :at_top
  def move_cursor_up(%UIState{panel: %Panel{prompt_buffer: pid}} = state) when is_pid(pid) do
    case Buffer.cursor(pid) do
      {0, _col} ->
        :at_top

      {_line, _col} ->
        Buffer.move(pid, :up)
        state
    end
  end

  def move_cursor_up(%UIState{}), do: :at_top

  @doc "Moves the prompt cursor down, or returns `:at_bottom`."
  @spec move_cursor_down(UIState.t()) :: UIState.t() | :at_bottom
  def move_cursor_down(%UIState{panel: %Panel{prompt_buffer: pid}} = state) when is_pid(pid) do
    {line, _col} = Buffer.cursor(pid)

    if line >= Buffer.line_count(pid) - 1 do
      :at_bottom
    else
      Buffer.move(pid, :down)
      state
    end
  end

  def move_cursor_down(%UIState{}), do: :at_bottom

  @doc "Inserts pasted text, collapsing multi-line blocks into metadata-backed placeholders."
  @spec insert_paste(UIState.t(), String.t()) :: UIState.t()
  def insert_paste(%UIState{} = state, ""), do: state

  def insert_paste(%UIState{} = state, text) when is_binary(text) do
    state = ensure(state)
    clean_text = String.replace(text, "\0", "")

    if clean_text |> String.split("\n") |> Enum.count() < @paste_collapse_threshold do
      Buffer.insert_text(state.panel.prompt_buffer, clean_text)
      UIState.record_prompt_edit(state)
    else
      insert_collapsed_paste(state, clean_text)
    end
  end

  @doc "Toggles the collapsed paste block at the current prompt line."
  @spec toggle_paste_expand(UIState.t()) :: UIState.t()
  def toggle_paste_expand(%UIState{panel: %Panel{prompt_buffer: pid}} = state) when is_pid(pid) do
    {cursor_line, _col} = Buffer.cursor(pid)
    current_line = state |> input_lines() |> Enum.at(cursor_line)

    case parse_placeholder(current_line) do
      {:ok, index} ->
        if Enum.at(state.panel.pasted_blocks, index), do: expand_block(state, index), else: state

      :not_placeholder ->
        toggle_expanded_block(state, cursor_line)
    end
  end

  def toggle_paste_expand(%UIState{} = state), do: state

  @doc "Saves non-blank prompt text to history."
  @spec save_to_history(UIState.t()) :: UIState.t()
  def save_to_history(%UIState{} = state) do
    text = prompt_text(state)
    if String.trim(text) == "", do: state, else: UIState.remember_prompt(state, text)
  end

  @doc "Recalls the previous prompt history entry."
  @spec history_prev(UIState.t()) :: UIState.t()
  def history_prev(%UIState{panel: %Panel{prompt_history: []}} = state), do: state

  def history_prev(%UIState{panel: %Panel{prompt_buffer: pid} = panel} = state)
      when is_pid(pid) do
    index = min(panel.history_index + 1, Enum.count(panel.prompt_history) - 1)
    Buffer.replace_content(pid, Enum.at(panel.prompt_history, index))
    UIState.select_prompt_history(state, index)
  end

  def history_prev(%UIState{} = state), do: state

  @doc "Recalls the next prompt history entry."
  @spec history_next(UIState.t()) :: UIState.t()
  def history_next(%UIState{panel: %Panel{history_index: -1}} = state), do: state

  def history_next(%UIState{panel: %Panel{history_index: 0, prompt_buffer: pid}} = state)
      when is_pid(pid) do
    Buffer.replace_content(pid, "")
    UIState.select_prompt_history(state, -1)
  end

  def history_next(%UIState{panel: %Panel{prompt_buffer: pid} = panel} = state)
      when is_pid(pid) do
    index = panel.history_index - 1
    Buffer.replace_content(pid, Enum.at(panel.prompt_history, index))
    UIState.select_prompt_history(state, index)
  end

  def history_next(%UIState{} = state), do: state

  @spec start(UIState.t(), String.t()) :: UIState.t()
  defp start(%UIState{} = state, content) do
    {:ok, pid} = Buffer.start_link(content: content)
    UIState.attach_prompt_buffer(state, pid)
  end

  @spec panel(UIState.t() | Panel.t()) :: Panel.t()
  defp panel(%UIState{panel: panel}), do: panel
  defp panel(%Panel{} = panel), do: panel

  @spec buffer_content(Panel.t(), String.t()) :: String.t()
  defp buffer_content(%Panel{prompt_buffer: pid}, _default) when is_pid(pid),
    do: Buffer.content(pid)

  defp buffer_content(%Panel{}, default), do: default

  @spec insert_collapsed_paste(UIState.t(), String.t()) :: UIState.t()
  defp insert_collapsed_paste(%UIState{panel: panel} = state, text) do
    pid = panel.prompt_buffer
    {cursor_line, cursor_col} = Buffer.cursor(pid)
    lines = input_lines(state)
    index = Enum.count(panel.pasted_blocks)
    placeholder = @paste_placeholder_prefix <> Integer.to_string(index)
    {before, after_cursor} = lines |> Enum.at(cursor_line) |> String.split_at(cursor_col)
    new_lines = insert_placeholder_lines(lines, cursor_line, before, after_cursor, placeholder)
    placeholder_line = Enum.find_index(new_lines, &(&1 == placeholder))
    new_cursor_line = min(placeholder_line + 1, Enum.count(new_lines) - 1)

    new_cursor_col =
      if new_cursor_line > placeholder_line, do: 0, else: String.length(placeholder)

    Buffer.replace_content(pid, Enum.join(new_lines, "\n"))
    Buffer.move_to(pid, {new_cursor_line, new_cursor_col})
    UIState.append_paste_block(state, text)
  end

  @spec insert_placeholder_lines(
          [String.t()],
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t()
        ) :: [String.t()]
  defp insert_placeholder_lines(lines, cursor_line, "", "", placeholder),
    do: List.replace_at(lines, cursor_line, placeholder)

  defp insert_placeholder_lines(lines, cursor_line, "", after_cursor, placeholder),
    do:
      Enum.take(lines, cursor_line) ++
        [placeholder, after_cursor] ++ Enum.drop(lines, cursor_line + 1)

  defp insert_placeholder_lines(lines, cursor_line, _before, "", placeholder),
    do: Enum.take(lines, cursor_line + 1) ++ [placeholder] ++ Enum.drop(lines, cursor_line + 1)

  defp insert_placeholder_lines(lines, cursor_line, before, after_cursor, placeholder),
    do:
      Enum.take(lines, cursor_line) ++
        [before, placeholder, after_cursor] ++ Enum.drop(lines, cursor_line + 1)

  @spec toggle_expanded_block(UIState.t(), non_neg_integer()) :: UIState.t()
  defp toggle_expanded_block(%UIState{} = state, cursor_line) do
    case find_expanded_block_at_cursor(state, cursor_line) do
      {:ok, index} -> collapse_block(state, index)
      :not_found -> state
    end
  end

  @spec expand_block(UIState.t(), non_neg_integer()) :: UIState.t()
  defp expand_block(%UIState{panel: panel} = state, index) do
    pid = panel.prompt_buffer
    {cursor_line, _col} = Buffer.cursor(pid)
    lines = input_lines(state)
    block = Enum.at(panel.pasted_blocks, index)
    placeholder = @paste_placeholder_prefix <> Integer.to_string(index)
    placeholder_line = Enum.find_index(lines, &(&1 == placeholder))

    if placeholder_line do
      text_lines = String.split(block.text, "\n")

      new_lines =
        Enum.take(lines, placeholder_line) ++ text_lines ++ Enum.drop(lines, placeholder_line + 1)

      expansion = Enum.count(text_lines) - 1

      next_cursor =
        if cursor_line > placeholder_line, do: cursor_line + expansion, else: cursor_line

      Buffer.replace_content(pid, Enum.join(new_lines, "\n"))
      Buffer.move_to(pid, {next_cursor, 0})
      UIState.mark_paste_expanded(state, index, true)
    else
      state
    end
  end

  @spec collapse_block(UIState.t(), non_neg_integer()) :: UIState.t()
  defp collapse_block(%UIState{panel: panel} = state, index) do
    pid = panel.prompt_buffer
    {cursor_line, _col} = Buffer.cursor(pid)
    lines = input_lines(state)
    text_lines = panel.pasted_blocks |> Enum.at(index) |> Map.fetch!(:text) |> String.split("\n")
    start_index = find_expanded_block_start(lines, text_lines)

    if start_index do
      placeholder = @paste_placeholder_prefix <> Integer.to_string(index)

      new_lines =
        Enum.take(lines, start_index) ++
          [placeholder] ++ Enum.drop(lines, start_index + Enum.count(text_lines))

      next_cursor = collapse_cursor_line(cursor_line, start_index, Enum.count(text_lines))
      Buffer.replace_content(pid, Enum.join(new_lines, "\n"))
      Buffer.move_to(pid, {next_cursor, 0})
      UIState.mark_paste_expanded(state, index, false)
    else
      state
    end
  end

  @spec collapse_cursor_line(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  defp collapse_cursor_line(cursor, start_index, count)
       when cursor >= start_index and cursor < start_index + count,
       do: start_index

  defp collapse_cursor_line(cursor, start_index, count) when cursor >= start_index + count,
    do: cursor - count + 1

  defp collapse_cursor_line(cursor, _start_index, _count), do: cursor

  @spec find_expanded_block_at_cursor(UIState.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :not_found
  defp find_expanded_block_at_cursor(%UIState{} = state, cursor_line) do
    lines = input_lines(state)

    state.panel.pasted_blocks
    |> Enum.with_index()
    |> Enum.find_value(:not_found, &expanded_block_at_cursor(&1, lines, cursor_line))
  end

  @spec expanded_block_at_cursor(
          {Panel.paste_block(), non_neg_integer()},
          [String.t()],
          non_neg_integer()
        ) :: {:ok, non_neg_integer()} | nil
  defp expanded_block_at_cursor({%{expanded: false}, _index}, _lines, _cursor_line), do: nil

  defp expanded_block_at_cursor({block, index}, lines, cursor_line) do
    text_lines = String.split(block.text, "\n")
    start_index = find_expanded_block_start(lines, text_lines)
    count = Enum.count(text_lines)

    if start_index && cursor_line >= start_index && cursor_line < start_index + count,
      do: {:ok, index}
  end

  @spec find_expanded_block_start([String.t()], [String.t()]) :: non_neg_integer() | nil
  defp find_expanded_block_start(lines, text_lines) do
    max_start = Enum.count(lines) - Enum.count(text_lines)

    if max_start < 0,
      do: nil,
      else:
        Enum.find(0..max_start, &(Enum.slice(lines, &1, Enum.count(text_lines)) == text_lines))
  end

  @spec parse_placeholder(String.t() | nil) :: {:ok, non_neg_integer()} | :not_placeholder
  defp parse_placeholder(<<@paste_placeholder_prefix, rest::binary>>) when byte_size(rest) > 0 do
    case Integer.parse(rest) do
      {index, ""} when index >= 0 -> {:ok, index}
      _other -> :not_placeholder
    end
  end

  defp parse_placeholder(_line), do: :not_placeholder

  @spec substitute_placeholders(String.t(), [Panel.paste_block()]) :: String.t()
  defp substitute_placeholders(content, blocks) do
    content
    |> String.split("\n")
    |> Enum.map_join("\n", &substitute_placeholder(&1, blocks))
  end

  @spec substitute_placeholder(String.t(), [Panel.paste_block()]) :: String.t()
  defp substitute_placeholder(line, blocks) do
    case parse_placeholder(line) do
      {:ok, index} -> substitute_block(Enum.at(blocks, index), line)
      :not_placeholder -> line
    end
  end

  @spec substitute_block(Panel.paste_block() | nil, String.t()) :: String.t()
  defp substitute_block(%{text: text}, _line), do: text
  defp substitute_block(nil, line), do: line
end
