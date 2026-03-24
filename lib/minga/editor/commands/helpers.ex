defmodule Minga.Editor.Commands.Helpers do
  @moduledoc """
  Shared helper functions used across Editor.Commands sub-modules.

  All functions are public so sub-modules can call them directly. These
  helpers are intentionally not part of the public Commands API — callers
  should use `Editor.Commands.execute/2` instead.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Clipboard
  alias Minga.Editor.Editing
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Registers
  alias Minga.Editor.Viewport
  alias Minga.Mode.State, as: ModeState
  alias Minga.TextObject

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Operator kind for register and range operations."
  @type operator_action :: :delete | :yank

  @typedoc "Text object action kind."
  @type text_object_action :: :delete | :yank

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
    state
  end

  def maybe_sync_clipboard(state, _text, _clipboard), do: state

  @spec reset_active_register(state()) :: state()
  def reset_active_register(state),
    do: Editing.reset_active_register(state)

  # Reads clipboard mode from the active buffer's options. Falls back to
  # :none if no buffer is active (safe default: no clipboard calls).
  @spec resolve_clipboard(state()) :: clipboard_mode()
  defp resolve_clipboard(%{buffers: %{active: buf}}) when is_pid(buf) do
    BufferServer.get_option(buf, :clipboard)
  catch
    :exit, _ -> :none
  end

  defp resolve_clipboard(_state), do: :none

  # ── Positional helpers ──────────────────────────────────────────────────────

  @doc "Returns the two positions sorted so the lesser comes first."
  @spec sort_positions(Document.position(), Document.position()) ::
          {Document.position(), Document.position()}
  def sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @doc "Saves the jump position when the cursor crosses a line boundary."
  @spec save_jump_pos(state(), Document.position(), Document.position()) :: state()
  def save_jump_pos(state, {from_line, _} = from_pos, {to_line, _})
      when from_line != to_line do
    Editing.save_jump_pos(state, from_pos)
  end

  def save_jump_pos(state, _from_pos, _to_pos), do: state

  # ── Motion application ──────────────────────────────────────────────────────

  @doc "Applies a `(buf, pos) -> new_pos` motion function to the buffer cursor."
  @spec apply_motion(
          pid(),
          (Document.t(), Minga.Motion.position() -> Minga.Motion.position())
        ) :: :ok
  def apply_motion(buf, motion_fn) do
    gb = BufferServer.snapshot(buf)
    new_pos = motion_fn.(gb, Document.cursor(gb))
    BufferServer.move_to(buf, new_pos)
  end

  @doc "Resolves a motion atom to a new position in the buffer."
  @spec resolve_motion(Document.t(), Minga.Motion.position(), atom()) ::
          Minga.Motion.position()
  def resolve_motion(buf, cursor, :word_forward), do: Minga.Motion.word_forward(buf, cursor)
  def resolve_motion(buf, cursor, :word_backward), do: Minga.Motion.word_backward(buf, cursor)
  def resolve_motion(buf, cursor, :word_end), do: Minga.Motion.word_end(buf, cursor)
  def resolve_motion(buf, cursor, :line_start), do: Minga.Motion.line_start(buf, cursor)
  def resolve_motion(buf, cursor, :line_end), do: Minga.Motion.line_end(buf, cursor)
  def resolve_motion(buf, _cursor, :document_start), do: Minga.Motion.document_start(buf)
  def resolve_motion(buf, _cursor, :document_end), do: Minga.Motion.document_end(buf)

  def resolve_motion(buf, cursor, :first_non_blank),
    do: Minga.Motion.first_non_blank(buf, cursor)

  def resolve_motion(_buf, cursor, :half_page_down), do: cursor
  def resolve_motion(_buf, cursor, :half_page_up), do: cursor
  def resolve_motion(_buf, cursor, :page_down), do: cursor
  def resolve_motion(_buf, cursor, :page_up), do: cursor

  def resolve_motion(buf, cursor, :word_forward_big),
    do: Minga.Motion.word_forward_big(buf, cursor)

  def resolve_motion(buf, cursor, :word_backward_big),
    do: Minga.Motion.word_backward_big(buf, cursor)

  def resolve_motion(buf, cursor, :word_end_big), do: Minga.Motion.word_end_big(buf, cursor)

  def resolve_motion(buf, cursor, :paragraph_forward),
    do: Minga.Motion.paragraph_forward(buf, cursor)

  def resolve_motion(buf, cursor, :paragraph_backward),
    do: Minga.Motion.paragraph_backward(buf, cursor)

  def resolve_motion(buf, cursor, :match_bracket), do: Minga.Motion.match_bracket(buf, cursor)
  def resolve_motion(_buf, cursor, _unknown), do: cursor

  @doc "Applies a find-char motion in the given direction."
  @spec apply_find_char(pid(), ModeState.find_direction(), String.t()) :: :ok
  def apply_find_char(buf, dir, char) do
    gb = BufferServer.snapshot(buf)
    cursor = Document.cursor(gb)

    motion_fn =
      case dir do
        :f -> &Minga.Motion.find_char_forward/3
        :F -> &Minga.Motion.find_char_backward/3
        :t -> &Minga.Motion.till_char_forward/3
        :T -> &Minga.Motion.till_char_backward/3
      end

    new_pos = motion_fn.(gb, cursor, char)
    BufferServer.move_to(buf, new_pos)
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
    gb = BufferServer.snapshot(buf)
    cursor = Document.cursor(gb)
    target = resolve_motion(gb, cursor, motion)
    {start_pos, end_pos} = sort_positions(cursor, target)

    case action do
      :delete ->
        text = Document.get_range(gb, start_pos, end_pos)
        BufferServer.delete_range(buf, start_pos, end_pos)
        put_register(state, text, :delete)

      :yank ->
        text = Document.get_range(gb, start_pos, end_pos)
        put_register(state, text, :yank)
    end
  end

  @doc "Applies a delete or yank operator over a text object range."
  @spec apply_text_object(state(), atom(), term(), text_object_action()) :: state()
  def apply_text_object(%{buffers: %{active: buf}} = state, modifier, spec, action) do
    gb = BufferServer.snapshot(buf)
    cursor = Document.cursor(gb)
    buffer_id = HighlightSync.buffer_id_for(state, buf)
    range = compute_text_object_range(gb, cursor, modifier, spec, buffer_id)

    case {action, range} do
      {_, nil} ->
        state

      {:delete, {start_pos, end_pos}} ->
        text = Document.get_range(gb, start_pos, end_pos)
        BufferServer.delete_range(buf, start_pos, end_pos)
        put_register(state, text, :delete)

      {:yank, {start_pos, end_pos}} ->
        text = Document.get_range(gb, start_pos, end_pos)
        put_register(state, text, :yank)
    end
  end

  @doc "Computes the range for a text object modifier + spec pair."
  @spec compute_text_object_range(
          Document.t(),
          TextObject.position(),
          atom(),
          term(),
          non_neg_integer()
        ) ::
          TextObject.range()
  def compute_text_object_range(buf, pos, :inner, :word, _bid),
    do: TextObject.inner_word(buf, pos)

  def compute_text_object_range(buf, pos, :around, :word, _bid),
    do: TextObject.a_word(buf, pos)

  def compute_text_object_range(buf, pos, :inner, {:quote, q}, _bid),
    do: TextObject.inner_quotes(buf, pos, q)

  def compute_text_object_range(buf, pos, :around, {:quote, q}, _bid),
    do: TextObject.a_quotes(buf, pos, q)

  def compute_text_object_range(buf, pos, :inner, {:paren, open, close}, _bid),
    do: TextObject.inner_parens(buf, pos, open, close)

  def compute_text_object_range(buf, pos, :around, {:paren, open, close}, _bid),
    do: TextObject.a_parens(buf, pos, open, close)

  def compute_text_object_range(_buf, pos, :inner, {:structural, type}, bid),
    do: TextObject.structural_inner(type, pos, bid)

  def compute_text_object_range(_buf, pos, :around, {:structural, type}, bid),
    do: TextObject.structural_around(type, pos, bid)

  def compute_text_object_range(_buf, _pos, _modifier, _spec, _bid), do: nil

  @doc "Scrolls the buffer cursor by `delta` lines, clamping to bounds."
  @spec page_move(pid(), Viewport.t(), integer()) :: :ok
  def page_move(buf, _vp, delta) do
    gb = BufferServer.snapshot(buf)
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

    BufferServer.move_to(buf, {target_line, target_col})
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
    case BufferServer.buffer_name(buf) do
      nil ->
        case BufferServer.file_path(buf) do
          nil -> "[no file]"
          path -> Path.basename(path)
        end

      name ->
        name
    end
  end
end
