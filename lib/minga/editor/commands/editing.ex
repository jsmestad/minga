defmodule Minga.Editor.Commands.Editing do
  @moduledoc """
  Single-key and multi-key editing commands: insert/delete, join, replace,
  case toggle, indent/dedent, undo/redo, and paste.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Buffer.Document

  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.Indent
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Registers
  alias Minga.Mode
  alias Minga.Mode.ReplaceState
  alias Minga.Mode.VisualState

  @type state :: EditorState.t()

  @command_specs [
    {:delete_before, "Delete character before cursor (backspace)", true},
    {:delete_at, "Delete character at cursor (delete)", true},
    {:insert_newline, "Insert a newline at cursor", true},
    {:insert_line_below, "Insert line below", true},
    {:insert_line_above, "Insert line above", true},
    {:join_lines, "Join lines", true},
    {:toggle_case, "Toggle character case", true},
    {:replace_restore, "Restore replaced character", true},
    {:undo, "Undo the last change", true},
    {:redo, "Redo the last undone change", true},
    {:paste_before, "Paste before cursor", true},
    {:paste_after, "Paste after cursor", true},
    {:indent_line, "Indent line", true},
    {:dedent_line, "Dedent line", true},
    {:comment_line, "Toggle comment on line", true},
    {:comment_visual_selection, "Toggle comment on selection", true},
    {:indent_visual_selection, "Indent visual selection", true},
    {:dedent_visual_selection, "Dedent visual selection", true},
    {:reindent_visual_selection, "Re-indent visual selection", true}
  ]

  @spec execute(state(), Mode.command()) :: state()

  # ── Deletion ──────────────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :delete_before) do
    if Buffer.get_option(buf, :autopair) do
      execute_autopair_delete(state, buf)
    else
      Buffer.delete_before(buf)
      state
    end
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :delete_at) do
    Buffer.delete_at(buf)
    state
  end

  # Normal-mode x: deletes count character(s) at cursor and yanks them into the register.
  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:delete_chars_at, count})
      when is_integer(count) and count > 0 do
    deleted = collect_chars_at(buf, count)

    if deleted != "" do
      Helpers.put_register(state, deleted, :delete)
    else
      state
    end
  end

  # Normal-mode X: deletes count character(s) before cursor and yanks them into the register.
  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:delete_chars_before, count})
      when is_integer(count) and count > 0 do
    deleted = collect_chars_before(buf, count)

    if deleted != "" do
      Helpers.put_register(state, deleted, :delete)
    else
      state
    end
  end

  # ── Insertion ─────────────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :insert_newline) do
    {line, _col} = Buffer.cursor(buf)
    indent = Indent.compute_for_newline(buf, line)
    Buffer.insert_char(buf, "\n" <> indent)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:insert_char, char})
      when is_binary(char) do
    if Buffer.get_option(buf, :autopair) do
      execute_autopair_insert(buf, char)
    else
      Buffer.insert_char(buf, char)
    end

    state
  end

  # ── Open lines ────────────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :insert_line_below) do
    {line, _col} = Buffer.cursor(buf)

    end_col =
      case Buffer.lines(buf, line, 1) do
        [text] -> byte_size(text)
        [] -> 0
      end

    indent = Indent.compute_for_newline(buf, line)
    Buffer.move_to(buf, {line, end_col})
    Buffer.insert_char(buf, "\n" <> indent)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :insert_line_above) do
    {line, _col} = Buffer.cursor(buf)
    indent = Indent.compute_for_newline(buf, max(line - 1, 0))
    Buffer.move_to(buf, {line, 0})
    Buffer.insert_char(buf, indent <> "\n")
    Buffer.move_to(buf, {line, byte_size(indent)})
    state
  end

  # ── Single-key editing ────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :join_lines) do
    {line, _col} = Buffer.cursor(buf)
    total_lines = Buffer.line_count(buf)

    if line < total_lines - 1 do
      current_line =
        case Buffer.lines(buf, line, 1) do
          [text] -> text
          [] -> ""
        end

      end_col = byte_size(current_line)
      Buffer.move_to(buf, {line, end_col})
      Buffer.delete_at(buf)

      # After deleting the newline, the joined line contains current + next content.
      joined_line =
        case Buffer.lines(buf, line, 1) do
          [text] -> text
          [] -> ""
        end

      # The part after the original end is the next line's content.
      suffix = binary_part(joined_line, end_col, byte_size(joined_line) - end_col)
      trimmed = String.trim_leading(suffix)
      spaces_to_delete = byte_size(suffix) - byte_size(trimmed)

      for _ <- 1..max(spaces_to_delete, 0)//1 do
        Buffer.delete_at(buf)
      end

      if end_col > 0 and trimmed != "" do
        Buffer.insert_char(buf, " ")
      end
    end

    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:replace_char, char}) do
    Buffer.delete_at(buf)
    Buffer.insert_char(buf, char)
    Buffer.move(buf, :left)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :toggle_case) do
    {line, col} = Buffer.cursor(buf)

    case Buffer.lines(buf, line, 1) do
      [text] when col < byte_size(text) ->
        # Extract grapheme at byte_col
        rest = binary_part(text, col, byte_size(text) - col)

        case String.next_grapheme(rest) do
          {char, _} ->
            toggled = Helpers.toggle_char_case(char)
            Buffer.delete_at(buf)
            Buffer.insert_char(buf, toggled)

          nil ->
            :ok
        end

      _ ->
        :ok
    end

    state
  end

  # ── Replace mode ──────────────────────────────────────────────────────────

  def execute(
        %{workspace: %{editing: %{mode_state: %ReplaceState{} = ms}, buffers: %{active: buf}}} =
          state,
        {:replace_overwrite, char}
      ) do
    {line, col} = Buffer.cursor(buf)

    original =
      case Buffer.lines(buf, line, 1) do
        [text] when col < byte_size(text) ->
          rest = binary_part(text, col, byte_size(text) - col)

          case String.next_grapheme(rest) do
            {g, _} -> g
            nil -> " "
          end

        _ ->
          " "
      end

    Buffer.delete_at(buf)
    Buffer.insert_char(buf, char)
    new_ms = %{ms | original_chars: [original | ms.original_chars]}

    %{
      state
      | workspace: %{state.workspace | editing: %{state.workspace.editing | mode_state: new_ms}}
    }
  end

  def execute(state, {:replace_overwrite, _char}), do: state

  def execute(
        %{
          workspace: %{
            buffers: %{active: buf},
            editing: %{mode_state: %ReplaceState{original_chars: [orig | rest]} = ms}
          }
        } = state,
        :replace_restore
      ) do
    Buffer.delete_before(buf)
    Buffer.insert_char(buf, orig)
    Buffer.move(buf, :left)
    new_ms = %{ms | original_chars: rest}

    %{
      state
      | workspace: %{state.workspace | editing: %{state.workspace.editing | mode_state: new_ms}}
    }
  end

  def execute(
        %{workspace: %{editing: %{mode_state: %ReplaceState{original_chars: []}}}} = state,
        :replace_restore
      ),
      do: state

  def execute(state, :replace_restore), do: state

  # ── Undo / redo ───────────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :undo) do
    Buffer.undo(buf)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :redo) do
    Buffer.redo(buf)
    state
  end

  # ── Paste ─────────────────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :paste_before) do
    {text, reg_type, state} = Helpers.get_register(state)

    case text do
      nil ->
        state

      t ->
        paste_content(buf, t, reg_type, :before)
        state
    end
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :paste_after) do
    {text, reg_type, state} = Helpers.get_register(state)

    case text do
      nil ->
        state

      t ->
        paste_content(buf, t, reg_type, :after)
        state
    end
  end

  # ── Indent / dedent (single line) ────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :indent_line) do
    tw = tab_width(buf)
    indent = String.duplicate(" ", tw)
    {line, col} = Buffer.cursor(buf)
    Buffer.move_to(buf, {line, 0})
    Buffer.insert_char(buf, indent)
    Buffer.move_to(buf, {line, col + tw})
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :dedent_line) do
    {line, col} = Buffer.cursor(buf)

    case Buffer.lines(buf, line, 1) do
      [text] -> dedent_single_line(buf, line, col, text)
      _ -> :ok
    end

    state
  end

  # ── Indent / dedent (multiple lines via count or motion) ─────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:indent_lines, n}) do
    {cursor_line, _} = Buffer.cursor(buf)
    total = Buffer.line_count(buf)
    end_line = min(cursor_line + n - 1, total - 1)
    do_indent_lines(buf, cursor_line, end_line)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:dedent_lines, n}) do
    {cursor_line, _} = Buffer.cursor(buf)
    total = Buffer.line_count(buf)
    end_line = min(cursor_line + n - 1, total - 1)
    do_dedent_lines(buf, cursor_line, end_line)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:indent_motion, motion}) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)
    target = Helpers.resolve_motion(gb, cursor, motion)
    {cursor_line, _} = cursor
    {target_line, _} = target
    start_line = min(cursor_line, target_line)
    end_line = max(cursor_line, target_line)
    do_indent_lines(buf, start_line, end_line)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:dedent_motion, motion}) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)
    target = Helpers.resolve_motion(gb, cursor, motion)
    {cursor_line, _} = cursor
    {target_line, _} = target
    start_line = min(cursor_line, target_line)
    end_line = max(cursor_line, target_line)
    do_dedent_lines(buf, start_line, end_line)
    state
  end

  def execute(
        %{workspace: %{editing: %{mode_state: %VisualState{} = ms}, buffers: %{active: buf}}} =
          state,
        :indent_visual_selection
      ) do
    anchor = ms.visual_anchor
    cursor = Buffer.cursor(buf)
    {anchor_line, _} = anchor
    {cursor_line, _} = cursor
    start_line = min(anchor_line, cursor_line)
    end_line = max(anchor_line, cursor_line)
    do_indent_lines(buf, start_line, end_line)
    state
  end

  def execute(
        %{workspace: %{editing: %{mode_state: %VisualState{} = ms}, buffers: %{active: buf}}} =
          state,
        :dedent_visual_selection
      ) do
    anchor = ms.visual_anchor
    cursor = Buffer.cursor(buf)
    {anchor_line, _} = anchor
    {cursor_line, _} = cursor
    start_line = min(anchor_line, cursor_line)
    end_line = max(anchor_line, cursor_line)
    do_dedent_lines(buf, start_line, end_line)
    state
  end

  # ── Reindent (= operator) ──────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:reindent_lines, n}) do
    {cursor_line, _} = Buffer.cursor(buf)
    total = Buffer.line_count(buf)
    end_line = min(cursor_line + n - 1, total - 1)
    do_reindent_lines(buf, cursor_line, end_line)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:reindent_motion, motion}) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)
    target = Helpers.resolve_motion(gb, cursor, motion)
    {cursor_line, _} = cursor
    {target_line, _} = target
    start_line = min(cursor_line, target_line)
    end_line = max(cursor_line, target_line)
    do_reindent_lines(buf, start_line, end_line)
    state
  end

  def execute(
        %{workspace: %{editing: %{mode_state: %VisualState{} = ms}, buffers: %{active: buf}}} =
          state,
        :reindent_visual_selection
      ) do
    anchor = ms.visual_anchor
    cursor = Buffer.cursor(buf)
    {anchor_line, _} = anchor
    {cursor_line, _} = cursor
    start_line = min(anchor_line, cursor_line)
    end_line = max(anchor_line, cursor_line)
    do_reindent_lines(buf, start_line, end_line)
    state
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:reindent_text_object, modifier, spec}
      )
      when is_pid(buf) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)
    buffer_id = HighlightSync.buffer_id_for(state, buf)
    range = Helpers.compute_text_object_range(gb, cursor, modifier, spec, buffer_id)

    case range do
      nil ->
        state

      {{start_line, _}, {end_line, _}} ->
        do_reindent_lines(buf, start_line, end_line)
        state
    end
  end

  # ── Comment toggling ────────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, :comment_line) when is_pid(buf) do
    {line, _col} = Buffer.cursor(buf)
    toggle_comment(buf, line, line, state)
    state
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:comment_motion, motion})
      when is_pid(buf) do
    {cursor_line, _col} = Buffer.cursor(buf)
    target_line = resolve_motion_line(buf, motion, cursor_line)
    start_line = min(cursor_line, target_line)
    end_line = max(cursor_line, target_line)
    toggle_comment(buf, start_line, end_line, state)
    state
  end

  def execute(
        %{workspace: %{editing: %{mode_state: %VisualState{} = ms}, buffers: %{active: buf}}} =
          state,
        :comment_visual_selection
      ) do
    anchor = ms.visual_anchor
    cursor = Buffer.cursor(buf)
    {anchor_line, _} = anchor
    {cursor_line, _} = cursor
    start_line = min(anchor_line, cursor_line)
    end_line = max(anchor_line, cursor_line)
    toggle_comment(buf, start_line, end_line, state)
    state
  end

  # ── Private comment helpers ──────────────────────────────────────────────

  @spec toggle_comment(pid(), non_neg_integer(), non_neg_integer(), state()) :: :ok
  defp toggle_comment(buf, start_line, end_line, state) do
    filetype = Buffer.filetype(buf)
    injection_ranges = Map.get(state.workspace.injection_ranges, buf, [])

    prefix = resolve_comment_prefix(buf, start_line, filetype, injection_ranges)
    raw = Buffer.lines_content(buf, start_line, end_line)
    lines = String.split(raw, "\n")

    edits = Minga.Editing.Comment.compute_toggle_edits(lines, prefix, start_line)

    Enum.each(edits, fn edit -> apply_comment_edit(buf, edit) end)

    :ok
  end

  @spec resolve_comment_prefix(pid(), non_neg_integer(), atom(), [map()]) :: String.t()
  defp resolve_comment_prefix(_buf, _start_line, filetype, []) do
    language_comment_token(filetype)
    |> Minga.Editing.Comment.comment_prefix()
  end

  defp resolve_comment_prefix(buf, start_line, filetype, injection_ranges) do
    byte_offset = Buffer.byte_offset_for_line(buf, start_line)
    default_token = language_comment_token(filetype)

    Minga.Editing.Comment.comment_prefix_at(
      default_token,
      byte_offset,
      injection_ranges,
      &language_comment_token/1
    )
  end

  @spec language_comment_token(atom()) :: String.t() | nil
  defp language_comment_token(filetype) do
    case Minga.Language.get(filetype) do
      %{comment_token: token} when is_binary(token) -> token
      _ -> nil
    end
  end

  @spec apply_comment_edit(pid(), Minga.Editing.Comment.edit()) :: :ok
  defp apply_comment_edit(buf, {:insert, line, col, text}) do
    Buffer.move_to(buf, {line, col})
    Buffer.insert_text(buf, text)
  end

  defp apply_comment_edit(buf, {:delete, line, col, len}) do
    Buffer.apply_edit(buf, line, col, line, col + len - 1, "")
  end

  # ── Private autopair helpers ──────────────────────────────────────────────

  @spec execute_autopair_delete(state(), pid()) :: state()
  defp execute_autopair_delete(state, buf) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)

    case Minga.Editing.backspace_with_pairs(gb, cursor) do
      :delete_pair ->
        Buffer.delete_before(buf)
        Buffer.delete_at(buf)

      :passthrough ->
        Buffer.delete_before(buf)
    end

    state
  end

  @spec execute_autopair_insert(pid(), String.t()) :: :ok
  defp execute_autopair_insert(buf, char) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)

    case Minga.Editing.insert_with_pairs(gb, cursor, char) do
      {:pair, open, close} ->
        Buffer.insert_char(buf, open)
        Buffer.insert_char(buf, close)
        Buffer.move(buf, :left)

      {:skip, _char} ->
        Buffer.move(buf, :right)

      {:passthrough, char} ->
        Buffer.insert_char(buf, char)
    end

    :ok
  end

  # ── Private reindent helpers ──────────────────────────────────────────────

  @spec do_reindent_lines(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp do_reindent_lines(buf, start_line, end_line) do
    {cursor_line, _} = Buffer.cursor(buf)

    for line <- start_line..end_line do
      reindent_single_line(buf, line)
    end

    # Move cursor to first non-blank on cursor line
    case Buffer.lines(buf, cursor_line, 1) do
      [text] ->
        first_non_blank = Indent.first_non_blank_col(text)
        Buffer.move_to(buf, {cursor_line, first_non_blank})

      [] ->
        Buffer.move_to(buf, {cursor_line, 0})
    end

    :ok
  end

  @spec reindent_single_line(pid(), non_neg_integer()) :: :ok
  defp reindent_single_line(buf, line) do
    # Compute the desired indent for this line based on the previous line
    desired_indent =
      if line == 0 do
        ""
      else
        Indent.compute_for_newline(buf, line - 1)
      end

    # Check if current line starts with a dedent trigger
    desired_indent =
      if Indent.should_dedent_line?(buf, line) do
        Indent.remove_one_indent_level(desired_indent, buf)
      else
        desired_indent
      end

    # Get current line text and its existing indent
    case Buffer.lines(buf, line, 1) do
      [text] ->
        current_indent = Indent.extract_leading_ws(text)

        if current_indent != desired_indent do
          # Replace leading whitespace using apply_text_edit
          indent_end_col = byte_size(current_indent)
          Buffer.apply_edit(buf, line, 0, line, indent_end_col, desired_indent)
        end

        :ok

      [] ->
        :ok
    end
  end

  # ── Private indent helpers ────────────────────────────────────────────────

  @spec do_indent_lines(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp do_indent_lines(buf, start_line, end_line) do
    {indent, indent_bytes} = indent_string(buf)
    {cursor_line, cursor_col} = Buffer.cursor(buf)

    for line <- start_line..end_line do
      Buffer.move_to(buf, {line, 0})
      Buffer.insert_char(buf, indent)
    end

    new_col =
      if cursor_line >= start_line and cursor_line <= end_line,
        do: cursor_col + indent_bytes,
        else: cursor_col

    Buffer.move_to(buf, {cursor_line, new_col})
    :ok
  end

  @spec do_dedent_lines(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp do_dedent_lines(buf, start_line, end_line) do
    {cursor_line, cursor_col} = Buffer.cursor(buf)
    cursor_removed = cursor_line_chars_to_remove(buf, cursor_line, start_line, end_line)

    for line <- start_line..end_line do
      dedent_line_at(buf, line)
    end

    new_col = max(0, cursor_col - cursor_removed)
    Buffer.move_to(buf, {cursor_line, new_col})
    :ok
  end

  @spec cursor_line_chars_to_remove(
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp cursor_line_chars_to_remove(buf, cursor_line, start_line, end_line) do
    if cursor_line >= start_line and cursor_line <= end_line do
      case Buffer.lines(buf, cursor_line, 1) do
        [text] -> dedent_amount(buf, text)
        _ -> 0
      end
    else
      0
    end
  end

  @spec dedent_line_at(pid(), non_neg_integer()) :: :ok
  defp dedent_line_at(buf, line) do
    case Buffer.lines(buf, line, 1) do
      [text] -> remove_leading_indent(buf, line, dedent_amount(buf, text))
      _ -> :ok
    end
  end

  @spec dedent_single_line(pid(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  defp dedent_single_line(buf, line, col, text) do
    to_remove = dedent_amount(buf, text)
    remove_leading_indent(buf, line, to_remove)
    if to_remove > 0, do: Buffer.move_to(buf, {line, max(0, col - to_remove)})
    :ok
  end

  # Returns the number of characters to remove for one dedent level.
  # If the line starts with a tab, remove 1 character.
  # Otherwise, remove up to tab_width spaces.
  @spec dedent_amount(pid(), String.t()) :: non_neg_integer()
  defp dedent_amount(buf, <<"\t", _::binary>>), do: if(uses_tabs?(buf), do: 1, else: 1)

  defp dedent_amount(buf, text) do
    min(count_leading_spaces(text), tab_width(buf))
  end

  @spec remove_leading_indent(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp remove_leading_indent(_buf, _line, 0), do: :ok

  defp remove_leading_indent(buf, line, n) when n > 0 do
    Buffer.move_to(buf, {line, 0})
    for _ <- 1..n, do: Buffer.delete_at(buf)
    :ok
  end

  @spec count_leading_spaces(String.t()) :: non_neg_integer()
  defp count_leading_spaces(text), do: do_count_leading_spaces(text, 0)

  @spec do_count_leading_spaces(String.t(), non_neg_integer()) :: non_neg_integer()
  defp do_count_leading_spaces(<<" ", rest::binary>>, n), do: do_count_leading_spaces(rest, n + 1)
  defp do_count_leading_spaces(_, n), do: n

  # Returns {indent_string, byte_size} for one indent level.
  @spec indent_string(pid()) :: {String.t(), pos_integer()}
  defp indent_string(buf) do
    if uses_tabs?(buf) do
      {"\t", 1}
    else
      tw = tab_width(buf)
      {String.duplicate(" ", tw), tw}
    end
  end

  @spec uses_tabs?(pid()) :: boolean()
  defp uses_tabs?(buf) do
    Buffer.get_option(buf, :indent_with) == :tabs
  catch
    :exit, _ -> false
  end

  @spec tab_width(pid()) :: pos_integer()
  defp tab_width(buf) when is_pid(buf) do
    Buffer.get_option(buf, :tab_width)
  catch
    :exit, _ -> 2
  end

  @spec resolve_motion_line(pid(), atom(), non_neg_integer()) :: non_neg_integer()
  defp resolve_motion_line(_buf, :line_down, cursor_line), do: cursor_line + 1

  defp resolve_motion_line(_buf, :line_up, cursor_line),
    do: max(0, cursor_line - 1)

  defp resolve_motion_line(_buf, :document_start, _cursor_line), do: 0

  defp resolve_motion_line(buf, :document_end, _cursor_line) do
    max(0, Buffer.line_count(buf) - 1)
  end

  defp resolve_motion_line(buf, :paragraph_forward, cursor_line) do
    content = Buffer.content(buf)
    lines = String.split(content, "\n")
    find_paragraph_boundary(lines, cursor_line, :forward)
  end

  defp resolve_motion_line(buf, :paragraph_backward, cursor_line) do
    content = Buffer.content(buf)
    lines = String.split(content, "\n")
    find_paragraph_boundary(lines, cursor_line, :backward)
  end

  defp resolve_motion_line(_buf, _motion, cursor_line), do: cursor_line

  @spec find_paragraph_boundary([String.t()], non_neg_integer(), :forward | :backward) ::
          non_neg_integer()
  defp find_paragraph_boundary(lines, cursor_line, :forward) do
    total = length(lines)

    lines
    |> Enum.drop(cursor_line + 1)
    |> Enum.with_index(cursor_line + 1)
    |> Enum.drop_while(fn {line, _idx} -> String.trim(line) != "" end)
    |> Enum.find(fn {line, _idx} -> String.trim(line) == "" end)
    |> case do
      {_, idx} -> idx
      nil -> max(0, total - 1)
    end
  end

  defp find_paragraph_boundary(lines, cursor_line, :backward) do
    lines
    |> Enum.take(cursor_line)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.drop_while(fn {line, _idx} -> String.trim(line) != "" end)
    |> Enum.find(fn {line, _idx} -> String.trim(line) == "" end)
    |> case do
      {_, idx} -> idx
      nil -> 0
    end
  end

  # ── Paste helpers ──────────────────────────────────────────────────────────

  # Pastes text into the buffer, handling linewise vs charwise differently.
  # Linewise: opens a new line above/below and inserts the content there.
  # Charwise: inserts inline at (or one past) the cursor position.
  @spec paste_content(pid(), String.t(), Registers.reg_type(), :before | :after) :: :ok
  defp paste_content(buf, text, :linewise, direction) do
    {line, _col} = Buffer.cursor(buf)
    # Strip the trailing newline that linewise yanks append
    content = String.trim_trailing(text, "\n")

    case direction do
      :after ->
        line_text = Buffer.lines(buf, line, 1) |> List.first() |> then(&(&1 || ""))
        Buffer.move_to(buf, {line, byte_size(line_text)})
        Buffer.insert_char(buf, "\n" <> content)
        Buffer.move_to(buf, {line + 1, 0})
        move_to_first_nonblank(buf)

      :before ->
        Buffer.move_to(buf, {line, 0})
        Buffer.insert_char(buf, content <> "\n")
        Buffer.move_to(buf, {line, 0})
        move_to_first_nonblank(buf)
    end

    :ok
  end

  defp paste_content(buf, text, :charwise, :before) do
    Buffer.insert_char(buf, text)
    :ok
  end

  defp paste_content(buf, text, :charwise, :after) do
    Buffer.move(buf, :right)
    Buffer.insert_char(buf, text)
    :ok
  end

  # Moves cursor to the first non-whitespace character on the current line.
  @spec move_to_first_nonblank(pid()) :: :ok
  defp move_to_first_nonblank(buf) do
    {line, _col} = Buffer.cursor(buf)
    line_text = Buffer.lines(buf, line, 1) |> List.first() |> then(&(&1 || ""))
    indent = byte_size(line_text) - byte_size(String.trim_leading(line_text))
    Buffer.move_to(buf, {line, indent})
    :ok
  end

  # Deletes `count` characters at the cursor, returning the concatenated deleted text.
  @spec collect_chars_at(pid(), pos_integer()) :: String.t()
  defp collect_chars_at(buf, count) do
    Enum.reduce(1..count, "", fn _, acc ->
      case grapheme_at_cursor(buf) do
        "" ->
          acc

        grapheme ->
          Buffer.delete_at(buf)
          acc <> grapheme
      end
    end)
  end

  # Deletes `count` characters before the cursor, returning the concatenated
  # deleted text in forward (reading) order.
  @spec collect_chars_before(pid(), pos_integer()) :: String.t()
  defp collect_chars_before(buf, count) do
    Enum.reduce(1..count, "", fn _, acc ->
      case grapheme_before_cursor(buf) do
        "" ->
          acc

        grapheme ->
          Buffer.delete_before(buf)
          # Prepend because we're deleting right-to-left
          grapheme <> acc
      end
    end)
  end

  # Returns the single grapheme at the cursor position, or "" if at end of line.
  @spec grapheme_at_cursor(pid()) :: String.t()
  defp grapheme_at_cursor(buf) do
    {line, col} = Buffer.cursor(buf)
    line_text = Buffer.lines(buf, line, 1) |> List.first() |> then(&(&1 || ""))

    if col >= byte_size(line_text) do
      ""
    else
      line_text
      |> binary_part(col, byte_size(line_text) - col)
      |> String.graphemes()
      |> List.first()
      |> then(&(&1 || ""))
    end
  end

  # Returns the single grapheme before the cursor position, or "" if at col 0.
  @spec grapheme_before_cursor(pid()) :: String.t()
  defp grapheme_before_cursor(buf) do
    {line, col} = Buffer.cursor(buf)

    if col == 0 do
      ""
    else
      line_text = Buffer.lines(buf, line, 1) |> List.first() |> then(&(&1 || ""))
      before = binary_part(line_text, 0, col)
      before |> String.graphemes() |> List.last() |> then(&(&1 || ""))
    end
  end

  @impl Minga.Command.Provider
  def __commands__ do
    standard =
      Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
        %Minga.Command{
          name: name,
          description: desc,
          requires_buffer: requires_buffer,
          execute: fn state -> execute(state, name) end
        }
      end)

    aliases = [
      %Minga.Command{
        name: :toggle_comment_line,
        description: "Toggle comment on line",
        requires_buffer: true,
        execute: fn state -> execute(state, :comment_line) end
      },
      %Minga.Command{
        name: :toggle_comment_selection,
        description: "Toggle comment on selection",
        requires_buffer: true,
        execute: fn state -> execute(state, :comment_visual_selection) end
      },
      %Minga.Command{
        name: :delete_chars_at,
        description: "Delete character(s) at cursor and yank (x)",
        requires_buffer: true,
        execute: fn state -> execute(state, {:delete_chars_at, 1}) end
      },
      %Minga.Command{
        name: :delete_chars_before,
        description: "Delete character(s) before cursor and yank (X)",
        requires_buffer: true,
        execute: fn state -> execute(state, {:delete_chars_before, 1}) end
      }
    ]

    standard ++ aliases
  end
end
