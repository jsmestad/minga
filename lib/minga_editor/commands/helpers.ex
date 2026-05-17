defmodule MingaEditor.Commands.Helpers do
  @moduledoc """
  Shared helper functions used across MingaEditor.Commands sub-modules.

  All functions are public so sub-modules can call them directly. These
  helpers are intentionally not part of the public Commands API — callers
  should use `MingaEditor.Commands.execute/2` instead.
  """

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Clipboard
  alias Minga.Core.Unicode
  alias MingaEditor.Editing
  alias MingaEditor.HighlightSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Registers
  alias MingaEditor.Viewport
  alias Minga.Mode.State, as: ModeState
  alias Minga.Parser.Manager, as: ParserManager

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Operator kind for register and range operations."
  @type operator_action :: :delete | :yank

  @typedoc "Text object action kind."
  @type text_object_action :: :delete | :yank | :change

  @typedoc "Clipboard sync mode controlling automatic system clipboard integration."
  @type clipboard_mode :: :unnamedplus | :unnamed | :none

  # ── Register helpers ────────────────────────────────────────────────────────

  @doc """
  Writes `text` into the appropriate register(s) based on `reg.active`
  and the operation kind (`:yank` or `:delete`).

  Reads `clipboard_mode` from `state` to decide whether to sync to the
  system clipboard. The 4-arity version lets callers override this
  explicitly (useful in tests to avoid depending on global Options state).
  """
  @spec put_register(state(), String.t(), :yank | :delete, Registers.reg_type()) :: state()
  def put_register(state, text, kind, reg_type \\ :charwise) do
    put_register_with_clipboard(state, text, kind, reg_type, resolve_clipboard(state))
  end

  @doc """
  Like `put_register/4` but with an explicit clipboard mode override.
  Used in tests to avoid depending on global Options state.
  """
  @spec put_register_with_clipboard_override(
          state(),
          String.t(),
          :yank | :delete,
          Registers.reg_type(),
          clipboard_mode()
        ) :: state()
  def put_register_with_clipboard_override(state, text, kind, reg_type, clipboard) do
    put_register_with_clipboard(state, text, kind, reg_type, clipboard)
  end

  @spec put_register_with_clipboard(
          state(),
          String.t(),
          :yank | :delete,
          Registers.reg_type(),
          clipboard_mode()
        ) :: state()
  defp put_register_with_clipboard(state, text, kind, reg_type, clipboard) do
    name = Editing.active_register(state)

    case name do
      "_" ->
        reset_active_register(state)

      "+" ->
        Clipboard.write_async(text)

        state
        |> write_unnamed(text, reg_type)
        |> maybe_write_yank(text, kind, reg_type)
        |> reset_active_register()

      name when name >= "A" and name <= "Z" ->
        lower = String.downcase(name)
        reg = Editing.registers(state)

        {existing_text, _existing_type} =
          case Registers.get(reg, lower) do
            {t, ty} -> {t, ty}
            nil -> {"", :charwise}
          end

        appended = existing_text <> text

        state
        |> put_in_register(lower, appended, reg_type)
        |> write_unnamed(text, reg_type)
        |> maybe_write_yank(text, kind, reg_type)
        |> maybe_sync_clipboard(text, clipboard)
        |> reset_active_register()

      name when name >= "a" and name <= "z" ->
        state
        |> put_in_register(name, text, reg_type)
        |> write_unnamed(text, reg_type)
        |> maybe_write_yank(text, kind, reg_type)
        |> maybe_sync_clipboard(text, clipboard)
        |> reset_active_register()

      _ ->
        effective_name = if name == "", do: "", else: name

        state
        |> put_in_register(effective_name, text, reg_type)
        |> maybe_write_yank(text, kind, reg_type)
        |> maybe_sync_clipboard(text, clipboard)
        |> reset_active_register()
    end
  end

  @doc """
  Reads from the active register, falling back to the unnamed register.

  When `clipboard: :unnamedplus` is set and the active register is unnamed
  (no explicit `"x` prefix), the system clipboard is read and preferred
  if it contains content that differs from the stored unnamed register
  (indicating the user copied something in another app).

  Reads `clipboard_mode` from `state` by default. The 2-arity version
  lets callers override this explicitly for testing.
  """
  @spec get_register(state()) :: {String.t() | nil, Registers.reg_type(), state()}
  def get_register(state) do
    get_register(state, resolve_clipboard(state))
  end

  @spec get_register(state(), clipboard_mode()) ::
          {String.t() | nil, Registers.reg_type(), state()}
  def get_register(state, clipboard) do
    name = Editing.active_register(state)

    if name == "+" do
      text = Clipboard.read()
      {text, :charwise, reset_active_register(state)}
    else
      reg = Editing.registers(state)
      key = if name == "", do: "", else: name
      entry = Registers.get(reg, key)

      {text, reg_type} =
        case entry do
          {t, ty} -> {t, ty}
          nil -> {nil, :charwise}
        end

      {final_text, final_type} = maybe_read_clipboard(key, text, reg_type, clipboard)
      {final_text, final_type, reset_active_register(state)}
    end
  end

  # When pasting from the unnamed register with clipboard sync enabled,
  # check the system clipboard. If its content differs from what we stored,
  # the user copied something externally, so prefer the clipboard content.
  # Clipboard reads are always :charwise since we have no type metadata.
  @spec maybe_read_clipboard(
          String.t(),
          String.t() | nil,
          Registers.reg_type(),
          clipboard_mode()
        ) :: {String.t() | nil, Registers.reg_type()}
  defp maybe_read_clipboard("", stored, reg_type, clipboard) do
    if clipboard in [:unnamedplus, :unnamed] do
      read_clipboard_or_fallback(stored, reg_type)
    else
      {stored, reg_type}
    end
  end

  defp maybe_read_clipboard(_key, stored, reg_type, _clipboard), do: {stored, reg_type}

  @spec read_clipboard_or_fallback(String.t() | nil, Registers.reg_type()) ::
          {String.t() | nil, Registers.reg_type()}
  defp read_clipboard_or_fallback(stored, reg_type) do
    case Clipboard.read() do
      nil -> {stored, reg_type}
      "" -> {stored, reg_type}
      clipboard_text when clipboard_text != stored -> {clipboard_text, :charwise}
      _same -> {stored, reg_type}
    end
  end

  @spec put_in_register(state(), String.t(), String.t(), Registers.reg_type()) :: state()
  def put_in_register(state, name, text, reg_type \\ :charwise) do
    Editing.put_register(state, name, text, reg_type)
  end

  @spec write_unnamed(state(), String.t(), Registers.reg_type()) :: state()
  def write_unnamed(state, text, reg_type \\ :charwise),
    do: put_in_register(state, "", text, reg_type)

  @spec maybe_write_yank(state(), String.t(), :yank | :delete, Registers.reg_type()) :: state()
  def maybe_write_yank(state, text, :yank, reg_type),
    do: put_in_register(state, "0", text, reg_type)

  def maybe_write_yank(state, _text, :delete, _reg_type), do: state

  @doc """
  Syncs text to the system clipboard when the `clipboard` option is set
  to `:unnamedplus` or `:unnamed`. Called automatically by `put_register/4`
  for all register writes except `"_"` (black hole) and `"+"` (explicit
  clipboard, which already writes directly).

  The `clipboard` parameter is passed through from `put_register/4` so
  the decision is made once at the top of the call chain.
  """
  @spec maybe_sync_clipboard(state(), String.t(), clipboard_mode()) :: state()
  def maybe_sync_clipboard(state, text, clipboard) when clipboard in [:unnamedplus, :unnamed] do
    Clipboard.write_async(text)

    # Also send the clipboard write opcode to native GUI frontends.
    # This writes to NSPasteboard directly, avoiding the pbcopy subprocess.
    if state.backend in [:gui, :native_gui] and state.port_manager do
      MingaEditor.Frontend.clipboard_write(state.port_manager, text)
    end

    state
  end

  def maybe_sync_clipboard(state, _text, _clipboard), do: state

  @doc """
  Unconditionally syncs text to the system clipboard, regardless of the
  user's `clipboard` config setting. Used by Cmd+C/X menu actions which
  are explicitly system clipboard operations.
  """
  @spec force_clipboard_sync(state(), String.t()) :: state()
  def force_clipboard_sync(state, text) do
    Clipboard.write_async(text)

    if state.backend in [:gui, :native_gui] and state.port_manager do
      MingaEditor.Frontend.clipboard_write(state.port_manager, text)
    end

    state
  end

  @spec reset_active_register(state()) :: state()
  def reset_active_register(state),
    do: Editing.reset_active_register(state)

  # Reads clipboard mode from the active buffer's options. Falls back to
  # :none if no buffer is active (safe default: no clipboard calls).
  @spec resolve_clipboard(state()) :: clipboard_mode()
  defp resolve_clipboard(%{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    Buffer.get_option(buf, :clipboard)
  catch
    :exit, _ -> :none
  end

  defp resolve_clipboard(_state), do: :none

  # ── Yank flash ─────────────────────────────────────────────────────────────

  alias Minga.Config
  alias Minga.Core.Face
  alias MingaEditor.YankFlash

  @doc """
  Starts a yank flash highlight on the yanked region if the feature is enabled.

  When active, cancels any existing yank flash, adds a highlight decoration
  to the buffer, and schedules the first timer step. No-op in headless mode
  or when the `:yank_flash` config option is false.
  """
  @spec maybe_start_yank_flash(
          state(),
          pid(),
          Buffer.position(),
          Buffer.position(),
          YankFlash.range_type()
        ) :: state()
  def maybe_start_yank_flash(state, buf, start_pos, end_pos, range_type) do
    if state.backend != :headless and Config.get(:yank_flash) do
      do_start_yank_flash(state, buf, start_pos, end_pos, range_type)
    else
      state
    end
  end

  @spec do_start_yank_flash(
          state(),
          pid(),
          Buffer.position(),
          Buffer.position(),
          YankFlash.range_type()
        ) :: state()
  defp do_start_yank_flash(state, buf, start_pos, end_pos, range_type) do
    old_flash = EditorState.yank_flash(state)

    if old_flash do
      cancel_existing_yank_flash(old_flash)
    end

    {flash, effects} = YankFlash.start(buf, start_pos, end_pos, range_type)

    flash_bg = yank_flash_color(state)
    {hl_start, hl_end} = YankFlash.highlight_bounds(buf, start_pos, end_pos, range_type)

    try do
      Buffer.add_highlight(buf, hl_start, hl_end,
        style: Face.new(bg: flash_bg),
        group: YankFlash.flash_group(),
        priority: 50
      )
    catch
      :exit, _ -> :ok
    end

    flash = MingaEditor.FlashEffects.apply(state, flash, effects)
    EditorState.set_yank_flash(state, flash)
  end

  @spec cancel_existing_yank_flash(YankFlash.t()) :: :ok
  defp cancel_existing_yank_flash(%YankFlash{buf: buf} = flash) do
    for {:cancel_timer, ref} <- YankFlash.cancel_effects(flash) do
      Process.cancel_timer(ref)
    end

    try do
      Buffer.remove_highlight_group(buf, YankFlash.flash_group())
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @spec yank_flash_color(state()) :: non_neg_integer()
  defp yank_flash_color(state) do
    case state do
      %{theme: %{editor: %{yank_flash_bg: bg}}} when bg != nil -> bg
      _ -> YankFlash.default_flash_bg()
    end
  end

  # ── Positional helpers ──────────────────────────────────────────────────────

  @doc "Returns the two positions sorted so the lesser comes first."
  @spec sort_positions(Buffer.position(), Buffer.position()) ::
          {Buffer.position(), Buffer.position()}
  def sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @doc "Saves the jump position when the cursor crosses a line boundary."
  @spec save_jump_pos(state(), Buffer.position(), Buffer.position()) :: state()
  def save_jump_pos(state, {from_line, _} = from_pos, {to_line, _})
      when from_line != to_line do
    Editing.save_jump_pos(state, from_pos)
  end

  def save_jump_pos(state, _from_pos, _to_pos), do: state

  # ── Motion application ──────────────────────────────────────────────────────

  @doc "Applies a `(buf, pos) -> new_pos` motion function to the buffer cursor."
  @spec apply_motion(
          pid(),
          (Buffer.document(), Minga.Editing.Motion.position() -> Minga.Editing.Motion.position())
        ) :: :ok
  def apply_motion(buf, motion_fn) do
    gb = Buffer.snapshot(buf)
    new_pos = motion_fn.(gb, Document.cursor(gb))
    Buffer.move_to(buf, new_pos)
  end

  @doc "Sets up parser state only for motions that need tree-sitter."
  @spec setup_for_motion(state(), atom()) :: state()
  def setup_for_motion(%{workspace: %{buffers: %{active: buf}}} = state, :match_bracket)
      when is_pid(buf) do
    if HighlightSync.buffer_id_for(state, buf) == 0 do
      HighlightSync.setup_for_buffer(state)
    else
      state
    end
  end

  def setup_for_motion(state, :match_bracket), do: state
  def setup_for_motion(state, _motion), do: state

  @doc "Returns the parser buffer id only for motions that need tree-sitter."
  @spec buffer_id_for_motion(state(), pid(), atom()) :: non_neg_integer()
  def buffer_id_for_motion(state, buf, :match_bracket),
    do: HighlightSync.buffer_id_for(state, buf)

  def buffer_id_for_motion(_state, _buf, _motion), do: 0

  @doc "Resolves a motion atom to a new position in the buffer."
  @spec resolve_motion(
          Buffer.document(),
          Minga.Editing.Motion.position(),
          atom(),
          non_neg_integer()
        ) :: Minga.Editing.Motion.position()
  def resolve_motion(buf, cursor, :word_forward, _buffer_id),
    do: Minga.Editing.word_forward(buf, cursor)

  def resolve_motion(buf, cursor, :word_backward, _buffer_id),
    do: Minga.Editing.word_backward(buf, cursor)

  def resolve_motion(buf, cursor, :word_end, _buffer_id), do: Minga.Editing.word_end(buf, cursor)

  def resolve_motion(buf, cursor, :line_start, _buffer_id),
    do: Minga.Editing.line_start(buf, cursor)

  def resolve_motion(buf, cursor, :line_end, _buffer_id), do: Minga.Editing.line_end(buf, cursor)

  def resolve_motion(buf, _cursor, :document_start, _buffer_id),
    do: Minga.Editing.document_start(buf)

  def resolve_motion(buf, _cursor, :document_end, _buffer_id), do: Minga.Editing.document_end(buf)

  def resolve_motion(buf, cursor, :first_non_blank, _buffer_id),
    do: Minga.Editing.first_non_blank(buf, cursor)

  def resolve_motion(_buf, cursor, :half_page_down, _buffer_id), do: cursor
  def resolve_motion(_buf, cursor, :half_page_up, _buffer_id), do: cursor
  def resolve_motion(_buf, cursor, :page_down, _buffer_id), do: cursor
  def resolve_motion(_buf, cursor, :page_up, _buffer_id), do: cursor

  def resolve_motion(buf, cursor, :word_forward_big, _buffer_id),
    do: Minga.Editing.word_forward_big(buf, cursor)

  def resolve_motion(buf, cursor, :word_backward_big, _buffer_id),
    do: Minga.Editing.word_backward_big(buf, cursor)

  def resolve_motion(buf, cursor, :word_end_big, _buffer_id),
    do: Minga.Editing.word_end_big(buf, cursor)

  def resolve_motion(buf, cursor, :paragraph_forward, _buffer_id),
    do: Minga.Editing.paragraph_forward(buf, cursor)

  def resolve_motion(buf, cursor, :paragraph_backward, _buffer_id),
    do: Minga.Editing.paragraph_backward(buf, cursor)

  def resolve_motion(_buf, cursor, :match_bracket, buffer_id) do
    case request_match_item(buffer_id, cursor) do
      nil -> cursor
      match -> match
    end
  end

  def resolve_motion(_buf, cursor, _unknown, _buffer_id), do: cursor

  @doc "Resolves a motion target, preserving no-match results for tree-sitter motions."
  @spec resolve_motion_target(
          Buffer.document(),
          Minga.Editing.Motion.position(),
          atom(),
          non_neg_integer()
        ) :: Minga.Editing.Motion.position() | nil
  def resolve_motion_target(_buf, cursor, :match_bracket, buffer_id),
    do: request_match_item(buffer_id, cursor)

  def resolve_motion_target(buf, cursor, motion, buffer_id),
    do: resolve_motion(buf, cursor, motion, buffer_id)

  @doc "Applies a find-char motion in the given direction."
  @spec apply_find_char(pid(), ModeState.find_direction(), String.t()) :: :ok
  def apply_find_char(buf, dir, char) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)

    motion_fn =
      case dir do
        :f -> &Minga.Editing.find_char_forward/3
        :F -> &Minga.Editing.find_char_backward/3
        :t -> &Minga.Editing.till_char_forward/3
        :T -> &Minga.Editing.till_char_backward/3
      end

    new_pos = motion_fn.(gb, cursor, char)
    Buffer.move_to(buf, new_pos)
  end

  @doc "Reverses a find-char direction (`f`↔`F`, `t`↔`T`)."
  @spec reverse_find_direction(ModeState.find_direction()) :: ModeState.find_direction()
  def reverse_find_direction(:f), do: :F
  def reverse_find_direction(:F), do: :f
  def reverse_find_direction(:t), do: :T
  def reverse_find_direction(:T), do: :t

  # ── Operator helpers ────────────────────────────────────────────────────────

  @doc "Applies a delete or yank operator over a motion range."
  @spec apply_operator_motion(pid(), state(), atom(), operator_action()) :: state()
  def apply_operator_motion(buf, state, motion, action) do
    state = setup_for_motion(state, motion)
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)
    buffer_id = buffer_id_for_motion(state, buf, motion)

    case resolve_motion_target(gb, cursor, motion, buffer_id) do
      nil ->
        state

      target ->
        {start_pos, end_pos} = sort_positions(cursor, target)
        end_pos = operator_target(gb, motion, end_pos)

        case action do
          :delete ->
            text = Document.content_between_inclusive(gb, start_pos, end_pos)
            Buffer.delete_range(buf, start_pos, end_pos)
            put_register(state, text, :delete)

          :yank ->
            text = Document.content_between_inclusive(gb, start_pos, end_pos)
            state = put_register(state, text, :yank)
            maybe_start_yank_flash(state, buf, start_pos, end_pos, :charwise)
        end
    end
  end

  @spec operator_target(Buffer.document(), atom(), Minga.Editing.Motion.position()) ::
          Minga.Editing.Motion.position()
  defp operator_target(buf, :match_bracket, {line, col}) do
    line_text = Document.line_at(buf, line) || ""
    {line, match_item_operator_col(line_text, col)}
  end

  defp operator_target(_buf, _motion, target), do: target

  @spec match_item_operator_col(String.t(), non_neg_integer()) :: non_neg_integer()
  defp match_item_operator_col(line_text, col) when col >= byte_size(line_text), do: col

  defp match_item_operator_col(line_text, col) do
    if match_item_token_byte?(:binary.at(line_text, col)) do
      match_item_token_end_col(line_text, col + 1)
    else
      col
    end
  end

  @spec match_item_token_end_col(String.t(), non_neg_integer()) :: non_neg_integer()
  defp match_item_token_end_col(line_text, col) when col >= byte_size(line_text),
    do: byte_size(line_text) - 1

  defp match_item_token_end_col(line_text, col) do
    if match_item_token_byte?(:binary.at(line_text, col)) do
      match_item_token_end_col(line_text, col + 1)
    else
      col - 1
    end
  end

  @spec match_item_token_byte?(byte()) :: boolean()
  defp match_item_token_byte?(byte) do
    byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?_, ?-, ?:]
  end

  @doc "Applies a delete or yank operator over a text object range."
  @spec apply_text_object(state(), atom(), term(), text_object_action()) :: state()
  def apply_text_object(%{workspace: %{buffers: %{active: buf}}} = state, modifier, spec, action) do
    gb = Buffer.snapshot(buf)
    cursor = Document.cursor(gb)
    buffer_id = HighlightSync.buffer_id_for(state, buf)
    range = compute_text_object_range(gb, cursor, modifier, spec, buffer_id)

    case {linewise_spec?(spec), action, range} do
      {_, _, nil} ->
        state

      {true, :delete, {start_pos, end_pos}} ->
        apply_linewise_text_object(buf, state, start_pos, end_pos, :delete)

      {true, :change, {start_pos, end_pos}} ->
        apply_linewise_text_object(buf, state, start_pos, end_pos, :change)

      {true, :yank, {start_pos, end_pos}} ->
        apply_linewise_text_object(buf, state, start_pos, end_pos, :yank)

      {false, :delete, {start_pos, end_pos}} ->
        text = Document.content_between_inclusive(gb, start_pos, end_pos)
        Buffer.delete_range(buf, start_pos, end_pos)
        put_register(state, text, :delete)

      {false, :change, {start_pos, end_pos}} ->
        text = Document.content_between_inclusive(gb, start_pos, end_pos)
        Buffer.delete_range(buf, start_pos, end_pos)
        put_register(state, text, :delete)

      {false, :yank, {start_pos, end_pos}} ->
        text = Document.content_between_inclusive(gb, start_pos, end_pos)
        state = put_register(state, text, :yank)
        maybe_start_yank_flash(state, buf, start_pos, end_pos, :charwise)
    end
  end

  defp apply_linewise_text_object(
         buf,
         state,
         {start_line, _start_col},
         {end_line, _end_col},
         action
       ) do
    first_line = min(start_line, end_line)
    last_line = max(start_line, end_line)
    text = Buffer.content_on_lines(buf, first_line, last_line) <> "\n"

    case action do
      :delete ->
        Buffer.delete_lines(buf, first_line, last_line)
        put_register(state, text, :delete, :linewise)

      :change ->
        if first_line < last_line do
          Buffer.delete_lines(buf, first_line + 1, last_line)
        end

        {:ok, _} = Buffer.clear_line(buf, first_line)
        put_register(state, text, :delete, :linewise)

      :yank ->
        state = put_register(state, text, :yank, :linewise)
        maybe_start_yank_flash(state, buf, {first_line, 0}, {last_line, 0}, :linewise)
    end
  end

  @spec linewise_spec?(term()) :: boolean()
  defp linewise_spec?(:paragraph), do: true
  defp linewise_spec?(_spec), do: false

  @doc "Computes the range for a text object modifier + spec pair."
  @spec compute_text_object_range(
          Buffer.document(),
          Minga.Editing.TextObject.position(),
          atom(),
          term(),
          non_neg_integer()
        ) ::
          Minga.Editing.TextObject.range()
  def compute_text_object_range(buf, pos, :inner, :word, _bid),
    do: Minga.Editing.select_inner_word(buf, pos)

  def compute_text_object_range(buf, pos, :around, :word, _bid),
    do: Minga.Editing.select_around_word(buf, pos)

  def compute_text_object_range(buf, pos, :inner, {:quote, q}, _bid),
    do: Minga.Editing.select_inner_quotes(buf, pos, q)

  def compute_text_object_range(buf, pos, :around, {:quote, q}, _bid),
    do: Minga.Editing.select_around_quotes(buf, pos, q)

  def compute_text_object_range(buf, pos, :inner, {:paren, open, close}, _bid),
    do: Minga.Editing.select_inner_parens(buf, pos, open, close)

  def compute_text_object_range(buf, pos, :around, {:paren, open, close}, _bid),
    do: Minga.Editing.select_around_parens(buf, pos, open, close)

  def compute_text_object_range(buf, pos, :inner, :paragraph, _bid),
    do: Minga.Editing.select_inner_paragraph(buf, pos)

  def compute_text_object_range(buf, pos, :around, :paragraph, _bid),
    do: Minga.Editing.select_around_paragraph(buf, pos)

  def compute_text_object_range(buf, pos, :inner, :sentence, _bid),
    do: Minga.Editing.select_inner_sentence(buf, pos)

  def compute_text_object_range(buf, pos, :around, :sentence, _bid),
    do: Minga.Editing.select_around_sentence(buf, pos)

  def compute_text_object_range(_buf, {line, col}, :inner, {:structural, type}, bid) do
    capture = Atom.to_string(type) <> ".inside"
    tree_data = request_textobject(bid, line, col, capture)
    Minga.Editing.select_structural_inner(tree_data)
  end

  def compute_text_object_range(_buf, {line, col}, :around, {:structural, type}, bid) do
    capture = Atom.to_string(type) <> ".around"
    tree_data = request_textobject(bid, line, col, capture)
    Minga.Editing.select_structural_around(tree_data)
  end

  def compute_text_object_range(_buf, _pos, _modifier, _spec, _bid), do: nil

  @doc "Scrolls the buffer cursor by `delta` lines, clamping to bounds."
  @spec page_move(pid(), Viewport.t(), integer()) :: :ok
  def page_move(buf, _vp, delta) do
    gb = Buffer.snapshot(buf)
    {line, col} = Document.cursor(gb)
    total_lines = Document.line_count(gb)
    target_line = max(0, min(line + delta, total_lines - 1))

    target_col =
      case Document.lines(gb, target_line, 1) do
        [text] when byte_size(text) > 0 ->
          min(col, Unicode.last_grapheme_byte_offset(text))

        _ ->
          0
      end

    Buffer.move_to(buf, {target_line, target_col})
  end

  @doc "Toggles the case of a single grapheme."
  @spec toggle_char_case(String.t()) :: String.t()
  def toggle_char_case(char) do
    up = String.upcase(char)
    if char == up, do: String.downcase(char), else: up
  end

  @doc "Returns a human-readable name for the buffer (buffer name, basename, or `[no file]`)."
  @spec buffer_display_name(pid()) :: String.t()
  def buffer_display_name(buf) do
    case Buffer.buffer_name(buf) do
      nil ->
        case Buffer.file_path(buf) do
          nil -> "[no file]"
          path -> Path.basename(path)
        end

      name ->
        name
    end
  end

  # Queries the tree-sitter parser for a textobject range, returning the raw
  # 4-tuple or nil. Gracefully returns nil when the parser is not running.
  @spec request_textobject(non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()) ::
          Minga.Editing.TextObject.tree_range()
  defp request_textobject(buffer_id, row, col, capture_name) do
    ParserManager.request_textobject(buffer_id, row, col, capture_name)
  catch
    :exit, _ -> nil
  end

  @spec request_match_item(non_neg_integer(), Minga.Editing.Motion.position()) ::
          Minga.Editing.Motion.position() | nil
  defp request_match_item(buffer_id, {line, col}) do
    ParserManager.request_match_item(buffer_id, line, col)
  end
end
