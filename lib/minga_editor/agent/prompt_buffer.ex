defmodule MingaEditor.Agent.PromptBuffer do
  @moduledoc """
  Workflow for the agent prompt's process-backed text buffer.

  The existing `Minga.Buffer.Process` remains authoritative for prompt text and
  cursor position. `MingaEditor.Agent.UIState` owns only prompt metadata and the
  attached buffer pid; this workflow coordinates both boundaries.
  """

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Editing.LineEdit
  alias MingaAgent.DraftSnapshot
  alias MingaEditor.Agent.SlashCommand
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel

  @paste_placeholder_prefix "\0PASTE:"
  @paste_collapse_threshold 3

  @typep expanded_match ::
           {index :: non_neg_integer(), start_line :: non_neg_integer(), count :: pos_integer()}

  @doc "Ensures the prompt buffer is alive and attached to the UI metadata."
  @spec ensure(UIState.t()) :: UIState.t()
  def ensure(%UIState{panel: %Panel{prompt_buffer: pid}} = state) when is_pid(pid) do
    Buffer.buffer_name(pid)
    state
  catch
    :exit, _ ->
      Minga.Log.warning(:agent, "Agent composer unavailable; attaching a new buffer.")
      start(state, "")
  end

  def ensure(%UIState{} = state), do: start(state, "")

  @doc "Returns prompt text with collapsed paste placeholders expanded."
  @spec prompt_text(UIState.t() | Panel.t()) :: String.t()
  def prompt_text(%UIState{panel: panel}), do: prompt_text(panel)

  def prompt_text(%Panel{prompt_buffer: pid, pasted_blocks: blocks}) when is_pid(pid) do
    pid |> Buffer.content() |> substitute_placeholders(blocks)
  end

  def prompt_text(%Panel{}), do: ""

  @doc "Expands collapsed paste placeholders in part of the raw composer text, as `prompt_text/1` does for all of it."
  @spec expand_text(UIState.t() | Panel.t(), String.t()) :: String.t()
  def expand_text(%UIState{panel: panel}, raw), do: expand_text(panel, raw)

  def expand_text(%Panel{pasted_blocks: blocks}, raw) when is_binary(raw),
    do: substitute_placeholders(raw, blocks)

  @doc """
  Removes `prefix` from the start of the composer when the composer still starts with it, keeping the rest and the cursor's place in it. Answers `:mismatch` when the user has since edited the prefix itself.

  A queued press uses it once the queue is confirmed: the text the press took leaves the composer, and what was typed after the press stays.
  """
  @spec drop_prefix(UIState.t(), String.t()) :: {:ok, UIState.t()} | :mismatch
  def drop_prefix(%UIState{panel: %Panel{prompt_buffer: pid}} = state, prefix)
      when is_pid(pid) and is_binary(prefix) do
    content = Buffer.content(pid)

    if String.starts_with?(content, prefix) do
      cursor = Buffer.cursor(pid)
      size = byte_size(prefix)
      Buffer.replace_content(pid, binary_part(content, size, byte_size(content) - size))
      Buffer.move_to(pid, cursor_after_prefix(cursor, prefix))
      {:ok, UIState.record_prompt_edit(state)}
    else
      :mismatch
    end
  end

  def drop_prefix(%UIState{}, _prefix), do: :mismatch

  # The cursor keeps its place in the text that stays: on the prefix's last line
  # it moves left by the prefix's width there, and later lines move up.
  @spec cursor_after_prefix({non_neg_integer(), non_neg_integer()}, String.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp cursor_after_prefix({line, col}, prefix) do
    lines = String.split(prefix, "\n")
    last_line = length(lines) - 1

    cond do
      line > last_line -> {line - last_line, col}
      line == last_line -> {0, max(col - byte_size(List.last(lines)), 0)}
      true -> {0, 0}
    end
  end

  @doc "Captures the current composer for storage without retaining credential input or deleted pastes."
  @spec draft_snapshot(UIState.t(), [DraftSnapshot.attachment()]) ::
          {:ok, DraftSnapshot.t() | nil} | {:error, :composer_unavailable | :private_input}
  def draft_snapshot(
        %UIState{panel: %Panel{prompt_buffer: pid, pasted_blocks: blocks}},
        attachments
      )
      when is_pid(pid) do
    document = Buffer.snapshot(pid)
    snapshot_draft(Document.content(document), Document.cursor(document), blocks, attachments)
  catch
    :exit, _reason -> {:error, :composer_unavailable}
  end

  def draft_snapshot(%UIState{}, _attachments), do: {:error, :composer_unavailable}

  @doc "Starts an unattached composer from saved text, caret and paste blocks without adding undo history."
  @spec restore_draft(UIState.t(), DraftSnapshot.t()) ::
          {:ok, UIState.t()} | {:error, :composer_attached}
  def restore_draft(%UIState{panel: %Panel{prompt_buffer: nil}} = state, %DraftSnapshot{} = draft) do
    state = start(state, draft.text)
    Buffer.move_to(state.panel.prompt_buffer, draft.cursor)
    {:ok, UIState.restore_prompt_pastes(state, draft.paste_blocks)}
  end

  def restore_draft(%UIState{}, %DraftSnapshot{}), do: {:error, :composer_attached}

  @spec snapshot_draft(String.t(), DraftSnapshot.position(), [Panel.paste_block()], [
          DraftSnapshot.attachment()
        ]) :: {:ok, DraftSnapshot.t() | nil} | {:error, :private_input}
  defp snapshot_draft("", _cursor, _blocks, []), do: {:ok, nil}

  defp snapshot_draft(text, cursor, blocks, attachments) do
    visible = if blocks == [], do: text, else: substitute_placeholders(text, blocks)

    if SlashCommand.sensitive_command?(visible) or
         SlashCommand.indented_credential_command?(visible) do
      {:error, :private_input}
    else
      {:ok,
       %DraftSnapshot{
         text: text,
         cursor: cursor,
         paste_blocks: retained_draft_pastes(text, blocks),
         attachments: attachments
       }}
    end
  end

  @spec retained_draft_pastes(String.t(), [Panel.paste_block()]) :: [DraftSnapshot.paste_block()]
  defp retained_draft_pastes(_text, []), do: []

  defp retained_draft_pastes(text, blocks) do
    lines = String.split(text, "\n")

    placeholders =
      Enum.reduce(lines, MapSet.new(), fn line, indices ->
        case parse_placeholder(line) do
          {:ok, index} -> MapSet.put(indices, index)
          :not_placeholder -> indices
        end
      end)

    blocks
    |> Enum.with_index()
    |> Enum.map(fn {%{text: paste, expanded: expanded?}, index} ->
      condense_draft_paste(paste, expanded?, MapSet.member?(placeholders, index), lines)
    end)
  end

  @spec condense_draft_paste(String.t(), boolean(), boolean(), [String.t()]) ::
          DraftSnapshot.paste_block()
  defp condense_draft_paste(paste, expanded?, true, _lines), do: {paste, expanded?}

  defp condense_draft_paste(paste, true, false, lines) do
    case find_expanded_block_start(lines, String.split(paste, "\n")) do
      nil -> {"", false}
      _first_line -> {paste, true}
    end
  end

  defp condense_draft_paste(_paste, false, false, _lines), do: {"", false}

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

  @doc """
  Applies a readline edit (`Minga.Editing.LineEdit`) to the composer line under the cursor.

  The composer types text, so `⌃U` deletes to the start of the line and `⌃W` the word before the cursor, as in any field you type in. A line that holds a collapsed paste is left alone, so an edit never cuts through its placeholder.
  """
  @spec line_edit(UIState.t(), LineEdit.edit()) :: UIState.t()
  def line_edit(%UIState{} = state, edit) do
    state = ensure(state)
    pid = state.panel.prompt_buffer
    {line, col} = Buffer.cursor(pid)
    [text] = Buffer.lines(pid, line, 1)

    if String.contains?(text, @paste_placeholder_prefix) do
      state
    else
      cursor = text |> binary_part(0, min(col, byte_size(text))) |> String.length()
      {new_text, new_cursor} = LineEdit.apply(edit, text, cursor)
      if new_text != text, do: Buffer.replace_lines(pid, line, line, new_text)
      Buffer.move_to(pid, {line, new_text |> String.slice(0, new_cursor) |> byte_size()})
      UIState.record_prompt_edit(state)
    end
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
        UIState.replace_panel(state, Panel.follow_prompt_cursor(state.panel))
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
      UIState.replace_panel(state, Panel.follow_prompt_cursor(state.panel))
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

  @doc "Toggles the paste block at the cursor, leaving the UI unchanged on a miss."
  @spec toggle_paste_expand(UIState.t()) :: UIState.t()
  def toggle_paste_expand(%UIState{} = state) do
    case toggle_paste_at_cursor(state) do
      {:handled, updated} -> updated
      :not_applicable -> state
    end
  end

  @doc "Toggles a paste block and reports whether it claims the key, even if no edit occurs."
  @spec toggle_paste_at_cursor(UIState.t()) :: :not_applicable | {:handled, UIState.t()}
  def toggle_paste_at_cursor(%UIState{panel: %Panel{prompt_buffer: pid}} = state)
      when is_pid(pid) do
    {content, {cursor_line, _col}} = Buffer.content_and_cursor(pid)
    lines = String.split(content, "\n")
    current_line = Enum.at(lines, cursor_line)

    case parse_placeholder(current_line) do
      {:ok, index} ->
        {:handled, expand_block(state, lines, cursor_line, index)}

      :not_placeholder ->
        fallback =
          if match?(<<@paste_placeholder_prefix, _::binary>>, current_line),
            do: :handled,
            else: :not_applicable

        case find_expanded_block_at_cursor(
               state.panel.pasted_blocks,
               lines,
               cursor_line,
               0,
               fallback
             ) do
          {_index, _start_line, _count} = match -> {:handled, collapse_block(state, lines, match)}
          :handled -> {:handled, state}
          :not_applicable -> :not_applicable
        end
    end
  end

  def toggle_paste_at_cursor(%UIState{}), do: :not_applicable

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
    line = Enum.at(lines, cursor_line)
    <<before::binary-size(^cursor_col), after_cursor::binary>> = line
    new_lines = insert_placeholder_lines(lines, cursor_line, before, after_cursor, placeholder)
    placeholder_line = Enum.find_index(new_lines, &(&1 == placeholder))
    new_cursor_line = min(placeholder_line + 1, Enum.count(new_lines) - 1)

    new_cursor_col =
      if new_cursor_line > placeholder_line, do: 0, else: byte_size(placeholder)

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

  @spec expand_block(UIState.t(), [String.t()], non_neg_integer(), non_neg_integer()) ::
          UIState.t()
  defp expand_block(%UIState{panel: panel} = state, lines, cursor_line, index) do
    with %{text: text} <- Enum.at(panel.pasted_blocks, index),
         placeholder = @paste_placeholder_prefix <> Integer.to_string(index),
         start_line when is_integer(start_line) <- Enum.find_index(lines, &(&1 == placeholder)) do
      {before, [_token | after_token]} = Enum.split(lines, start_line)

      next_cursor =
        if cursor_line > start_line,
          do: cursor_line + length(:binary.matches(text, "\n")),
          else: cursor_line

      Buffer.replace_content(panel.prompt_buffer, Enum.join(before ++ [text | after_token], "\n"))
      Buffer.move_to(panel.prompt_buffer, {next_cursor, 0})
      UIState.mark_paste_expanded(state, index, true)
    else
      nil -> state
    end
  end

  @spec collapse_block(UIState.t(), [String.t()], expanded_match()) :: UIState.t()
  defp collapse_block(%UIState{panel: panel} = state, lines, {index, start_line, count}) do
    placeholder = @paste_placeholder_prefix <> Integer.to_string(index)
    {before, rest} = Enum.split(lines, start_line)
    new_lines = before ++ [placeholder | Enum.drop(rest, count)]

    Buffer.replace_content(panel.prompt_buffer, Enum.join(new_lines, "\n"))
    Buffer.move_to(panel.prompt_buffer, {start_line, 0})
    UIState.mark_paste_expanded(state, index, false)
  end

  @spec find_expanded_block_at_cursor(
          [Panel.paste_block()],
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          :handled | :not_applicable
        ) :: expanded_match() | :handled | :not_applicable
  defp find_expanded_block_at_cursor([], _lines, _cursor_line, _index, fallback), do: fallback

  defp find_expanded_block_at_cursor(
         [%{expanded: false} | blocks],
         lines,
         cursor_line,
         index,
         fallback
       ) do
    find_expanded_block_at_cursor(blocks, lines, cursor_line, index + 1, fallback)
  end

  defp find_expanded_block_at_cursor(
         [%{expanded: true, text: text} | blocks],
         lines,
         cursor_line,
         index,
         fallback
       ) do
    text_lines = String.split(text, "\n")
    count = length(text_lines)

    case find_expanded_block_start(lines, text_lines, 0, cursor_line) do
      start_line when is_integer(start_line) and cursor_line < start_line + count ->
        {index, start_line, count}

      start_line when is_integer(start_line) and fallback == :not_applicable ->
        # Only the first occurrence can collapse. A later occurrence can claim Tab,
        # but another block's first occurrence can still win.
        first_candidate = cursor_line - count + 1
        candidates = Enum.drop(lines, first_candidate)

        fallback =
          if find_expanded_block_start(candidates, text_lines, first_candidate, cursor_line),
            do: :handled,
            else: :not_applicable

        find_expanded_block_at_cursor(blocks, lines, cursor_line, index + 1, fallback)

      _other ->
        find_expanded_block_at_cursor(blocks, lines, cursor_line, index + 1, fallback)
    end
  end

  @spec find_expanded_block_start([String.t()], [String.t()]) :: non_neg_integer() | nil
  defp find_expanded_block_start(lines, text_lines),
    do: find_expanded_block_start(lines, text_lines, 0, length(lines) - 1)

  @spec find_expanded_block_start([String.t()], [String.t()], non_neg_integer(), integer()) ::
          non_neg_integer() | nil
  defp find_expanded_block_start([_ | rest] = lines, text_lines, start_line, last_start)
       when start_line <= last_start do
    if List.starts_with?(lines, text_lines),
      do: start_line,
      else: find_expanded_block_start(rest, text_lines, start_line + 1, last_start)
  end

  defp find_expanded_block_start(_lines, _text_lines, _start_line, _last_start), do: nil

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
