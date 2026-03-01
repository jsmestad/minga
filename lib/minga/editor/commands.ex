defmodule Minga.Editor.Commands do
  @moduledoc """
  Command execution for the editor.

  Translates `Mode.command()` atoms/tuples into buffer mutations and state
  updates. All public functions return `state()` or `{state(), action()}`.

  ## Action tuples

  When a command requires the GenServer to do something outside the pure
  `state → state` pipeline (dot-repeat replay), `execute/2` returns
  `{state, {:dot_repeat, count}}`. The caller (`Editor`) dispatches it.

  ## Process dictionary side-channel

  Leader/which-key commands write to `Process.put(:__leader_update__, ...)`.
  This works because `execute/2` is always called from within the GenServer
  process; the GenServer merges the update map after all commands run.
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Mode.VisualState
  alias Minga.TextObject
  alias Minga.WhichKey

  require Logger

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Action the GenServer must dispatch after execute/2."
  @type action :: {:dot_repeat, non_neg_integer() | nil}

  @doc """
  Executes a single command against the editor state.

  Returns `state()` for the common case, or `{state(), action()}` when the
  GenServer must dispatch a follow-up action (dot-repeat).
  """
  @spec execute(state(), Mode.command()) :: state() | {state(), action()}

  # ── Picker commands (no buffer required) ─────────────────────────────────

  def execute(state, :command_palette) do
    PickerUI.open(state, Minga.Picker.CommandSource)
  end

  def execute(state, :find_file) do
    PickerUI.open(state, Minga.Picker.FileSource)
  end

  # Dot-repeat: return a tagged tuple so the GenServer can call replay_last_change/2
  # (which calls handle_key/3, a GenServer-level function).
  def execute(state, {:dot_repeat, count}) do
    {state, {:dot_repeat, count}}
  end

  # ── Guard: no buffer → no-op ──────────────────────────────────────────────

  def execute(%{buffer: nil} = state, _cmd), do: state

  # ── Cursor movement ───────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :move_left) do
    BufferServer.move(buf, :left)
    state
  end

  def execute(%{buffer: buf} = state, :move_right) do
    BufferServer.move(buf, :right)
    state
  end

  def execute(%{buffer: buf} = state, :move_up) do
    BufferServer.move(buf, :up)
    state
  end

  def execute(%{buffer: buf} = state, :move_down) do
    BufferServer.move(buf, :down)
    state
  end

  # ── Deletion ──────────────────────────────────────────────────────────────

  def execute(
        %{buffer: buf, mode: :insert, autopair_enabled: true} = state,
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

  def execute(%{buffer: buf} = state, :delete_before) do
    BufferServer.delete_before(buf)
    state
  end

  def execute(%{buffer: buf} = state, :delete_at) do
    BufferServer.delete_at(buf)
    state
  end

  # ── Insertion ─────────────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :insert_newline) do
    BufferServer.insert_char(buf, "\n")
    state
  end

  def execute(
        %{buffer: buf, mode: :insert, autopair_enabled: true} = state,
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

  def execute(%{buffer: buf} = state, {:insert_char, char}) when is_binary(char) do
    BufferServer.insert_char(buf, char)
    state
  end

  # ── Line start / end ──────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :move_to_line_start) do
    {line, _col} = BufferServer.cursor(buf)
    BufferServer.move_to(buf, {line, 0})
    state
  end

  def execute(%{buffer: buf} = state, :move_to_line_end) do
    {line, _col} = BufferServer.cursor(buf)

    end_col =
      case BufferServer.get_lines(buf, line, 1) do
        [text] -> max(0, String.length(text) - 1)
        [] -> 0
      end

    BufferServer.move_to(buf, {line, end_col})
    state
  end

  # ── Word / line / document motions ────────────────────────────────────────

  def execute(%{buffer: buf} = state, :word_forward) do
    apply_motion(buf, &Minga.Motion.word_forward/2)
    state
  end

  def execute(%{buffer: buf} = state, :word_backward) do
    apply_motion(buf, &Minga.Motion.word_backward/2)
    state
  end

  def execute(%{buffer: buf} = state, :word_end) do
    apply_motion(buf, &Minga.Motion.word_end/2)
    state
  end

  def execute(%{buffer: buf} = state, :move_to_first_non_blank) do
    apply_motion(buf, &Minga.Motion.first_non_blank/2)
    state
  end

  def execute(%{buffer: buf} = state, :move_to_document_start) do
    content = BufferServer.content(buf)
    new_pos = Minga.Motion.document_start(GapBuffer.new(content))
    BufferServer.move_to(buf, new_pos)
    state
  end

  def execute(%{buffer: buf} = state, :move_to_document_end) do
    content = BufferServer.content(buf)
    new_pos = Minga.Motion.document_end(GapBuffer.new(content))
    BufferServer.move_to(buf, new_pos)
    state
  end

  def execute(%{buffer: buf} = state, {:goto_line, line_num}) do
    target_line = max(0, line_num - 1)
    BufferServer.move_to(buf, {target_line, 0})
    state
  end

  # ── WORD motions ──────────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :word_forward_big) do
    apply_motion(buf, &Minga.Motion.word_forward_big/2)
    state
  end

  def execute(%{buffer: buf} = state, :word_backward_big) do
    apply_motion(buf, &Minga.Motion.word_backward_big/2)
    state
  end

  def execute(%{buffer: buf} = state, :word_end_big) do
    apply_motion(buf, &Minga.Motion.word_end_big/2)
    state
  end

  # ── Find-char motions ─────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, {:find_char, dir, char}) do
    apply_find_char(buf, dir, char)
    %{state | last_find_char: {dir, char}}
  end

  def execute(%{last_find_char: {dir, char}, buffer: buf} = state, :repeat_find_char) do
    apply_find_char(buf, dir, char)
    state
  end

  def execute(state, :repeat_find_char), do: state

  def execute(
        %{last_find_char: {dir, char}, buffer: buf} = state,
        :repeat_find_char_reverse
      ) do
    reverse_dir = reverse_find_direction(dir)
    apply_find_char(buf, reverse_dir, char)
    state
  end

  def execute(state, :repeat_find_char_reverse), do: state

  # ── Bracket matching ──────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :match_bracket) do
    apply_motion(buf, &Minga.Motion.match_bracket/2)
    state
  end

  # ── Paragraph motions ─────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :paragraph_forward) do
    apply_motion(buf, &Minga.Motion.paragraph_forward/2)
    state
  end

  def execute(%{buffer: buf} = state, :paragraph_backward) do
    apply_motion(buf, &Minga.Motion.paragraph_backward/2)
    state
  end

  # ── Screen-relative motions ───────────────────────────────────────────────

  def execute(%{buffer: buf, viewport: vp} = state, {:move_to_screen, position}) do
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

  # ── Single-key editing ────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :join_lines) do
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

  def execute(%{buffer: buf} = state, {:replace_char, char}) do
    BufferServer.delete_at(buf)
    BufferServer.insert_char(buf, char)
    BufferServer.move(buf, :left)
    state
  end

  def execute(%{buffer: buf} = state, :toggle_case) do
    {line, col} = BufferServer.cursor(buf)

    case BufferServer.get_lines(buf, line, 1) do
      [text] ->
        graphemes = String.graphemes(text)

        if col < length(graphemes) do
          char = Enum.at(graphemes, col)
          toggled = toggle_char_case(char)
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
        %{buffer: buf, mode_state: %Minga.Mode.ReplaceState{} = ms} = state,
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
          mode_state: %Minga.Mode.ReplaceState{original_chars: [orig | rest]} = ms
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
        %{mode_state: %Minga.Mode.ReplaceState{original_chars: []}} = state,
        :replace_restore
      ),
      do: state

  def execute(state, :replace_restore), do: state

  # ── Indent / dedent ───────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :indent_line) do
    {line, col} = BufferServer.cursor(buf)
    BufferServer.move_to(buf, {line, 0})
    BufferServer.insert_char(buf, "  ")
    BufferServer.move_to(buf, {line, col + 2})
    state
  end

  def execute(%{buffer: buf} = state, :dedent_line) do
    {line, col} = BufferServer.cursor(buf)

    case BufferServer.get_lines(buf, line, 1) do
      [text] -> dedent_single_line(buf, line, col, text)
      _ -> :ok
    end

    state
  end

  def execute(%{buffer: buf} = state, {:indent_lines, n}) do
    {cursor_line, _} = BufferServer.cursor(buf)
    total = BufferServer.line_count(buf)
    end_line = min(cursor_line + n - 1, total - 1)
    do_indent_lines(buf, cursor_line, end_line)
    state
  end

  def execute(%{buffer: buf} = state, {:dedent_lines, n}) do
    {cursor_line, _} = BufferServer.cursor(buf)
    total = BufferServer.line_count(buf)
    end_line = min(cursor_line + n - 1, total - 1)
    do_dedent_lines(buf, cursor_line, end_line)
    state
  end

  def execute(%{buffer: buf} = state, {:indent_motion, motion}) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    target = resolve_motion(tmp_buf, cursor, motion)
    {cursor_line, _} = cursor
    {target_line, _} = target
    start_line = min(cursor_line, target_line)
    end_line = max(cursor_line, target_line)
    do_indent_lines(buf, start_line, end_line)
    state
  end

  def execute(%{buffer: buf} = state, {:dedent_motion, motion}) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    target = resolve_motion(tmp_buf, cursor, motion)
    {cursor_line, _} = cursor
    {target_line, _} = target
    start_line = min(cursor_line, target_line)
    end_line = max(cursor_line, target_line)
    do_dedent_lines(buf, start_line, end_line)
    state
  end

  def execute(%{buffer: buf, mode_state: %VisualState{} = ms} = state, :indent_visual_selection) do
    anchor = ms.visual_anchor
    cursor = BufferServer.cursor(buf)
    {anchor_line, _} = anchor
    {cursor_line, _} = cursor
    start_line = min(anchor_line, cursor_line)
    end_line = max(anchor_line, cursor_line)
    do_indent_lines(buf, start_line, end_line)
    state
  end

  def execute(%{buffer: buf, mode_state: %VisualState{} = ms} = state, :dedent_visual_selection) do
    anchor = ms.visual_anchor
    cursor = BufferServer.cursor(buf)
    {anchor_line, _} = anchor
    {cursor_line, _} = cursor
    start_line = min(anchor_line, cursor_line)
    end_line = max(anchor_line, cursor_line)
    do_dedent_lines(buf, start_line, end_line)
    state
  end

  # ── Line navigation ───────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :next_line_first_non_blank) do
    {content, {line, _col}} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    total = GapBuffer.line_count(tmp_buf)
    next_line = min(line + 1, total - 1)
    new_pos = Minga.Motion.first_non_blank(tmp_buf, {next_line, 0})
    BufferServer.move_to(buf, new_pos)
    state
  end

  def execute(%{buffer: buf} = state, :prev_line_first_non_blank) do
    {content, {line, _col}} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    prev_line = max(line - 1, 0)
    new_pos = Minga.Motion.first_non_blank(tmp_buf, {prev_line, 0})
    BufferServer.move_to(buf, new_pos)
    state
  end

  # ── Operator + motion ─────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, {:delete_motion, motion}) do
    apply_operator_motion(buf, state, motion, :delete)
  end

  def execute(%{buffer: buf} = state, {:change_motion, motion}) do
    apply_operator_motion(buf, state, motion, :delete)
  end

  def execute(%{buffer: buf} = state, {:yank_motion, motion}) do
    apply_operator_motion(buf, state, motion, :yank)
  end

  # ── Open lines ────────────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :insert_line_below) do
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

  def execute(%{buffer: buf} = state, :insert_line_above) do
    {line, _col} = BufferServer.cursor(buf)
    BufferServer.move_to(buf, {line, 0})
    BufferServer.insert_char(buf, "\n")
    BufferServer.move(buf, :up)
    state
  end

  # ── Save / quit ───────────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :save) do
    case BufferServer.save(buf) do
      :ok ->
        name = buffer_display_name(buf)
        %{state | status_msg: "Wrote #{name}"}

      {:error, :file_changed} ->
        %{state | status_msg: "WARNING: File changed on disk. Use :w! to force save."}

      {:error, :no_file_path} ->
        %{state | status_msg: "No file name — use :w <filename>"}

      {:error, reason} ->
        %{state | status_msg: "Save failed: #{inspect(reason)}"}
    end
  end

  def execute(%{buffer: buf} = state, :force_save) do
    case BufferServer.force_save(buf) do
      :ok ->
        name = buffer_display_name(buf)
        %{state | status_msg: "Wrote #{name} (force)"}

      {:error, :no_file_path} ->
        %{state | status_msg: "No file name — use :w <filename>"}

      {:error, reason} ->
        %{state | status_msg: "Force save failed: #{inspect(reason)}"}
    end
  end

  def execute(%{buffer: buf} = state, :reload) do
    case BufferServer.reload(buf) do
      :ok ->
        name = buffer_display_name(buf)
        %{state | status_msg: "Reloaded #{name}"}

      {:error, :no_file_path} ->
        %{state | status_msg: "No file to reload"}

      {:error, reason} ->
        %{state | status_msg: "Reload failed: #{inspect(reason)}"}
    end
  end

  def execute(state, :quit) do
    System.stop(0)
    state
  end

  # ── Page / half-page scrolling ────────────────────────────────────────────

  def execute(%{buffer: buf, viewport: vp} = state, :half_page_down) do
    page_move(buf, vp, div(Viewport.content_rows(vp), 2))
    state
  end

  def execute(%{buffer: buf, viewport: vp} = state, :half_page_up) do
    page_move(buf, vp, -div(Viewport.content_rows(vp), 2))
    state
  end

  def execute(%{buffer: buf, viewport: vp} = state, :page_down) do
    page_move(buf, vp, Viewport.content_rows(vp))
    state
  end

  def execute(%{buffer: buf, viewport: vp} = state, :page_up) do
    page_move(buf, vp, -Viewport.content_rows(vp))
    state
  end

  # ── Undo / redo ───────────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, :undo) do
    BufferServer.undo(buf)
    state
  end

  def execute(%{buffer: buf} = state, :redo) do
    BufferServer.redo(buf)
    state
  end

  # ── Paste ─────────────────────────────────────────────────────────────────

  def execute(%{buffer: buf, register: text} = state, :paste_before) when is_binary(text) do
    BufferServer.insert_char(buf, text)
    state
  end

  def execute(state, :paste_before), do: state

  def execute(%{buffer: buf, register: text} = state, :paste_after) when is_binary(text) do
    BufferServer.move(buf, :right)
    BufferServer.insert_char(buf, text)
    state
  end

  def execute(state, :paste_after), do: state

  # ── Line-wise operators (dd / yy / cc / S) ────────────────────────────────

  def execute(%{buffer: buf} = state, :delete_line) do
    {line, _col} = BufferServer.cursor(buf)
    yanked = BufferServer.get_lines_content(buf, line, line)
    BufferServer.delete_lines(buf, line, line)
    %{state | register: yanked <> "\n"}
  end

  def execute(%{buffer: buf} = state, :change_line) do
    {line, _col} = BufferServer.cursor(buf)
    {:ok, yanked} = BufferServer.clear_line(buf, line)
    %{state | register: yanked <> "\n"}
  end

  def execute(%{buffer: buf} = state, :yank_line) do
    {line, _col} = BufferServer.cursor(buf)
    yanked = BufferServer.get_lines_content(buf, line, line)
    %{state | register: yanked <> "\n"}
  end

  # ── Ex commands ───────────────────────────────────────────────────────────

  def execute(state, {:execute_ex_command, {:save, []}}) do
    execute(state, :save)
  end

  def execute(state, {:execute_ex_command, {:force_save, []}}) do
    execute(state, :force_save)
  end

  def execute(state, {:execute_ex_command, {:force_edit, []}}) do
    execute(state, :reload)
  end

  def execute(state, {:execute_ex_command, {:checktime, []}}) do
    Minga.FileWatcher.check_all()
    state
  end

  def execute(state, {:execute_ex_command, {:quit, []}}) do
    execute(state, :quit)
  end

  def execute(state, {:execute_ex_command, {:force_quit, []}}) do
    Logger.debug("Force quitting editor")
    System.stop(0)
    state
  end

  def execute(state, {:execute_ex_command, {:save_quit, []}}) do
    state_after_save = execute(state, :save)
    Logger.debug("Quitting editor after save")
    System.stop(0)
    state_after_save
  end

  def execute(state, {:execute_ex_command, {:edit, file_path}}) do
    case find_buffer_by_path(state, file_path) do
      nil ->
        case start_buffer(file_path) do
          {:ok, pid} ->
            add_buffer(state, pid)

          {:error, reason} ->
            Logger.error("Failed to open file: #{inspect(reason)}")
            state
        end

      idx ->
        switch_to_buffer(state, idx)
    end
  end

  def execute(%{buffer: buf} = state, {:execute_ex_command, {:goto_line, line_num}}) do
    target_line = max(0, line_num - 1)
    BufferServer.move_to(buf, {target_line, 0})
    state
  end

  def execute(state, :cycle_line_numbers) do
    next =
      case state.line_numbers do
        :hybrid -> :absolute
        :absolute -> :relative
        :relative -> :none
        :none -> :hybrid
      end

    %{state | line_numbers: next}
  end

  def execute(state, {:execute_ex_command, {:set, :number}}) do
    %{state | line_numbers: :absolute}
  end

  def execute(state, {:execute_ex_command, {:set, :nonumber}}) do
    %{state | line_numbers: :none}
  end

  def execute(state, {:execute_ex_command, {:set, :relativenumber}}) do
    new_style =
      case state.line_numbers do
        :absolute -> :hybrid
        _ -> :relative
      end

    %{state | line_numbers: new_style}
  end

  def execute(state, {:execute_ex_command, {:set, :norelativenumber}}) do
    new_style =
      case state.line_numbers do
        :hybrid -> :absolute
        _ -> :none
      end

    %{state | line_numbers: new_style}
  end

  def execute(state, {:execute_ex_command, {:unknown, raw}}) do
    Logger.debug("Unknown ex command: #{raw}")
    state
  end

  # ── Visual selection operations ───────────────────────────────────────────

  def execute(%{buffer: buf, mode_state: %VisualState{} = ms} = state, :delete_visual_selection) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = BufferServer.cursor(buf)

    yanked =
      case visual_type do
        :char ->
          text = BufferServer.get_range(buf, anchor, cursor)
          BufferServer.delete_range(buf, anchor, cursor)
          text

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          text = BufferServer.get_lines_content(buf, start_line, end_line)
          BufferServer.delete_lines(buf, start_line, end_line)
          text <> "\n"
      end

    %{state | register: yanked}
  end

  def execute(%{buffer: buf, mode_state: %VisualState{} = ms} = state, :yank_visual_selection) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type
    cursor = BufferServer.cursor(buf)

    yanked =
      case visual_type do
        :char ->
          BufferServer.get_range(buf, anchor, cursor)

        :line ->
          {anchor_line, _} = anchor
          {cursor_line, _} = cursor
          start_line = min(anchor_line, cursor_line)
          end_line = max(anchor_line, cursor_line)
          BufferServer.get_lines_content(buf, start_line, end_line) <> "\n"
      end

    Logger.debug("Yanked visual selection")
    %{state | register: yanked}
  end

  # ── Visual wrapping (auto-pair) ───────────────────────────────────────────

  def execute(
        %{buffer: buf, mode_state: %VisualState{} = ms} = state,
        {:wrap_visual_selection, open, close}
      ) do
    anchor = ms.visual_anchor
    cursor = BufferServer.cursor(buf)
    {start_pos, end_pos} = sort_positions(anchor, cursor)
    {end_line, end_col} = end_pos
    {start_line, start_col} = start_pos

    BufferServer.move_to(buf, {end_line, end_col + 1})
    BufferServer.insert_char(buf, close)
    BufferServer.move_to(buf, {start_line, start_col})
    BufferServer.insert_char(buf, open)
    BufferServer.move_to(buf, {start_line, start_col})
    state
  end

  # ── Leader / which-key ────────────────────────────────────────────────────

  def execute(state, {:leader_start, node}) do
    if state.whichkey_timer, do: WhichKey.cancel_timeout(state.whichkey_timer)
    timer = WhichKey.start_timeout()

    Process.put(:__leader_update__, %{
      whichkey_node: node,
      whichkey_timer: timer,
      show_whichkey: false
    })

    state
  end

  def execute(state, {:leader_progress, node}) do
    if state.whichkey_timer, do: WhichKey.cancel_timeout(state.whichkey_timer)
    timer = WhichKey.start_timeout()

    Process.put(:__leader_update__, %{
      whichkey_node: node,
      whichkey_timer: timer,
      show_whichkey: state.show_whichkey
    })

    state
  end

  def execute(state, :leader_cancel) do
    if state.whichkey_timer, do: WhichKey.cancel_timeout(state.whichkey_timer)

    Process.put(:__leader_update__, %{
      whichkey_node: nil,
      whichkey_timer: nil,
      show_whichkey: false
    })

    state
  end

  # ── Text objects ──────────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, {:delete_text_object, modifier, spec}) when is_pid(buf) do
    apply_text_object(state, modifier, spec, :delete)
  end

  def execute(%{buffer: buf} = state, {:change_text_object, modifier, spec}) when is_pid(buf) do
    apply_text_object(state, modifier, spec, :delete)
  end

  def execute(%{buffer: buf} = state, {:yank_text_object, modifier, spec}) when is_pid(buf) do
    apply_text_object(state, modifier, spec, :yank)
  end

  # ── Buffer management ─────────────────────────────────────────────────────

  def execute(state, :buffer_list) do
    PickerUI.open(state, Minga.Picker.BufferSource)
  end

  def execute(state, :buffer_next), do: next_buffer(state)
  def execute(state, :buffer_prev), do: prev_buffer(state)
  def execute(state, :kill_buffer), do: remove_current_buffer(state)

  # ── Search ─────────────────────────────────────────────────────────────────

  def execute(
        %{buffer: buf, mode_state: %Minga.Mode.SearchState{} = ms} = state,
        :incremental_search
      ) do
    if ms.input == "" do
      # Empty pattern — restore cursor to original position
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

  def execute(%{buffer: buf, mode_state: %Minga.Mode.SearchState{} = ms} = state, :confirm_search) do
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

  def execute(%{buffer: buf, mode_state: %Minga.Mode.SearchState{} = ms} = state, :cancel_search) do
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

  # ── Unimplemented stubs ───────────────────────────────────────────────────

  def execute(state, :window_left), do: state
  def execute(state, :window_right), do: state
  def execute(state, :window_up), do: state
  def execute(state, :window_down), do: state
  def execute(state, :split_vertical), do: state
  def execute(state, :split_horizontal), do: state
  def execute(state, :describe_key), do: state

  # Unknown / unimplemented commands are silently ignored.
  def execute(state, _cmd), do: state

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Apply a motion function (buf, pos) -> new_pos to the buffer's cursor.
  @spec apply_motion(pid(), (GapBuffer.t(), Minga.Motion.position() -> Minga.Motion.position())) ::
          :ok
  defp apply_motion(buf, motion_fn) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    new_pos = motion_fn.(tmp_buf, cursor)
    BufferServer.move_to(buf, new_pos)
  end

  # Apply an operator (delete/yank) over a motion range.
  @typedoc "How to apply an operator+motion."
  @type operator_action :: :delete | :yank

  @spec apply_operator_motion(pid(), state(), atom(), operator_action()) :: state()
  defp apply_operator_motion(buf, state, motion, action) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    target = resolve_motion(tmp_buf, cursor, motion)
    {start_pos, end_pos} = sort_positions(cursor, target)

    case action do
      :delete ->
        text = BufferServer.get_range(buf, start_pos, end_pos)
        BufferServer.delete_range(buf, start_pos, end_pos)
        %{state | register: text}

      :yank ->
        text = BufferServer.get_range(buf, start_pos, end_pos)
        %{state | register: text}
    end
  end

  @spec resolve_motion(GapBuffer.t(), Minga.Motion.position(), atom()) ::
          Minga.Motion.position()
  defp resolve_motion(buf, cursor, :word_forward), do: Minga.Motion.word_forward(buf, cursor)
  defp resolve_motion(buf, cursor, :word_backward), do: Minga.Motion.word_backward(buf, cursor)
  defp resolve_motion(buf, cursor, :word_end), do: Minga.Motion.word_end(buf, cursor)
  defp resolve_motion(buf, cursor, :line_start), do: Minga.Motion.line_start(buf, cursor)
  defp resolve_motion(buf, cursor, :line_end), do: Minga.Motion.line_end(buf, cursor)
  defp resolve_motion(buf, _cursor, :document_start), do: Minga.Motion.document_start(buf)
  defp resolve_motion(buf, _cursor, :document_end), do: Minga.Motion.document_end(buf)

  defp resolve_motion(buf, cursor, :first_non_blank),
    do: Minga.Motion.first_non_blank(buf, cursor)

  defp resolve_motion(_buf, cursor, :half_page_down), do: cursor
  defp resolve_motion(_buf, cursor, :half_page_up), do: cursor
  defp resolve_motion(_buf, cursor, :page_down), do: cursor
  defp resolve_motion(_buf, cursor, :page_up), do: cursor

  defp resolve_motion(buf, cursor, :word_forward_big),
    do: Minga.Motion.word_forward_big(buf, cursor)

  defp resolve_motion(buf, cursor, :word_backward_big),
    do: Minga.Motion.word_backward_big(buf, cursor)

  defp resolve_motion(buf, cursor, :word_end_big), do: Minga.Motion.word_end_big(buf, cursor)

  defp resolve_motion(buf, cursor, :paragraph_forward),
    do: Minga.Motion.paragraph_forward(buf, cursor)

  defp resolve_motion(buf, cursor, :paragraph_backward),
    do: Minga.Motion.paragraph_backward(buf, cursor)

  defp resolve_motion(buf, cursor, :match_bracket), do: Minga.Motion.match_bracket(buf, cursor)
  defp resolve_motion(_buf, cursor, _unknown), do: cursor

  @spec apply_find_char(pid(), Minga.Mode.State.find_direction(), String.t()) :: :ok
  defp apply_find_char(buf, dir, char) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)

    motion_fn =
      case dir do
        :f -> &Minga.Motion.find_char_forward/3
        :F -> &Minga.Motion.find_char_backward/3
        :t -> &Minga.Motion.till_char_forward/3
        :T -> &Minga.Motion.till_char_backward/3
      end

    new_pos = motion_fn.(tmp_buf, cursor, char)
    BufferServer.move_to(buf, new_pos)
  end

  @spec reverse_find_direction(Minga.Mode.State.find_direction()) ::
          Minga.Mode.State.find_direction()
  defp reverse_find_direction(:f), do: :F
  defp reverse_find_direction(:F), do: :f
  defp reverse_find_direction(:t), do: :T
  defp reverse_find_direction(:T), do: :t

  @spec toggle_char_case(String.t()) :: String.t()
  defp toggle_char_case(char) do
    up = String.upcase(char)
    if char == up, do: String.downcase(char), else: up
  end

  @typedoc "How to apply a text object to the buffer."
  @type text_object_action :: :delete | :yank

  @spec apply_text_object(
          state(),
          Minga.Mode.OperatorPendingState.text_object_modifier(),
          term(),
          text_object_action()
        ) :: state()
  defp apply_text_object(%{buffer: buf} = state, modifier, spec, action) do
    {content, cursor} = BufferServer.content_and_cursor(buf)
    tmp_buf = GapBuffer.new(content)
    range = compute_text_object_range(tmp_buf, cursor, modifier, spec)

    case {action, range} do
      {_, nil} ->
        state

      {:delete, {start_pos, end_pos}} ->
        text = BufferServer.get_range(buf, start_pos, end_pos)
        BufferServer.delete_range(buf, start_pos, end_pos)
        %{state | register: text}

      {:yank, {start_pos, end_pos}} ->
        text = BufferServer.get_range(buf, start_pos, end_pos)
        Logger.debug("Yanked text object: #{byte_size(text)} bytes")
        %{state | register: text}
    end
  end

  @spec compute_text_object_range(GapBuffer.t(), TextObject.position(), atom(), term()) ::
          TextObject.range()
  defp compute_text_object_range(buf, pos, :inner, :word), do: TextObject.inner_word(buf, pos)
  defp compute_text_object_range(buf, pos, :around, :word), do: TextObject.a_word(buf, pos)

  defp compute_text_object_range(buf, pos, :inner, {:quote, q}),
    do: TextObject.inner_quotes(buf, pos, q)

  defp compute_text_object_range(buf, pos, :around, {:quote, q}),
    do: TextObject.a_quotes(buf, pos, q)

  defp compute_text_object_range(buf, pos, :inner, {:paren, open, close}),
    do: TextObject.inner_parens(buf, pos, open, close)

  defp compute_text_object_range(buf, pos, :around, {:paren, open, close}),
    do: TextObject.a_parens(buf, pos, open, close)

  defp compute_text_object_range(_buf, _pos, _modifier, _spec), do: nil

  @spec page_move(pid(), Viewport.t(), integer()) :: :ok
  defp page_move(buf, _vp, delta) do
    {line, col} = BufferServer.cursor(buf)
    total_lines = BufferServer.line_count(buf)
    target_line = line + delta
    target_line = max(0, min(target_line, total_lines - 1))

    target_col =
      case BufferServer.get_lines(buf, target_line, 1) do
        [text] -> min(col, max(0, String.length(text) - 1))
        [] -> 0
      end

    BufferServer.move_to(buf, {target_line, target_col})
  end

  @spec sort_positions(
          Minga.Buffer.GapBuffer.position(),
          Minga.Buffer.GapBuffer.position()
        ) :: {Minga.Buffer.GapBuffer.position(), Minga.Buffer.GapBuffer.position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @doc "Starts a new buffer process for the given file path."
  @spec start_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_buffer(file_path) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {BufferServer, file_path: file_path}
    )
  end

  # ── Buffer management helpers ─────────────────────────────────────────────

  @doc "Adds a new buffer to the list and makes it active."
  @spec add_buffer(state(), pid()) :: state()
  def add_buffer(state, pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    buffers = state.buffers ++ [pid]
    idx = Enum.count(buffers) - 1
    %{state | buffers: buffers, active_buffer: idx, buffer: pid}
  end

  @spec switch_to_buffer(state(), non_neg_integer()) :: state()
  defp switch_to_buffer(%{buffers: [_ | _] = buffers} = state, idx) do
    len = Enum.count(buffers)
    idx = rem(idx, len)
    idx = if idx < 0, do: idx + len, else: idx
    pid = Enum.at(buffers, idx)
    %{state | active_buffer: idx, buffer: pid}
  end

  defp switch_to_buffer(state, _idx), do: state

  @spec next_buffer(state()) :: state()
  defp next_buffer(%{buffers: [_, _ | _] = buffers, active_buffer: idx} = state) do
    switch_to_buffer(state, rem(idx + 1, Enum.count(buffers)))
  end

  defp next_buffer(state), do: state

  @spec prev_buffer(state()) :: state()
  defp prev_buffer(%{buffers: [_, _ | _] = buffers, active_buffer: idx} = state) do
    len = Enum.count(buffers)
    new_idx = if idx == 0, do: len - 1, else: idx - 1
    switch_to_buffer(state, new_idx)
  end

  defp prev_buffer(state), do: state

  @spec remove_current_buffer(state()) :: state()
  defp remove_current_buffer(%{buffers: [_ | _] = buffers, active_buffer: idx} = state) do
    buf = Enum.at(buffers, idx)
    if buf && Process.alive?(buf), do: GenServer.stop(buf, :normal)

    new_buffers = List.delete_at(buffers, idx)

    case new_buffers do
      [] ->
        %{state | buffers: [], active_buffer: 0, buffer: nil}

      _ ->
        new_idx = min(idx, Enum.count(new_buffers) - 1)
        new_active = Enum.at(new_buffers, new_idx)
        %{state | buffers: new_buffers, active_buffer: new_idx, buffer: new_active}
    end
  end

  defp remove_current_buffer(state), do: state

  @spec find_buffer_by_path(state(), String.t()) :: non_neg_integer() | nil
  defp find_buffer_by_path(%{buffers: buffers}, file_path) do
    Enum.find_index(buffers, fn buf ->
      Process.alive?(buf) && BufferServer.file_path(buf) == file_path
    end)
  end

  # ── Indent helpers ────────────────────────────────────────────────────────

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

  @spec buffer_display_name(pid()) :: String.t()
  defp buffer_display_name(buf) do
    case BufferServer.file_path(buf) do
      nil -> "[scratch]"
      path -> Path.basename(path)
    end
  end
end
