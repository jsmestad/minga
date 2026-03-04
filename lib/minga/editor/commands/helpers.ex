defmodule Minga.Editor.Commands.Helpers do
  @moduledoc """
  Shared helper functions used across Editor.Commands sub-modules.

  All functions are public so sub-modules can call them directly. These
  helpers are intentionally not part of the public Commands API — callers
  should use `Editor.Commands.execute/2` instead.
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Clipboard
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

  # ── Register helpers ────────────────────────────────────────────────────────

  @doc """
  Writes `text` into the appropriate register(s) based on `reg.active`
  and the operation kind (`:yank` or `:delete`).
  """
  @spec put_register(state(), String.t(), :yank | :delete) :: state()
  def put_register(%{reg: %{active: "_"}} = state, _text, _kind) do
    reset_active_register(state)
  end

  def put_register(%{reg: %{active: "+"}} = state, text, kind) do
    Clipboard.write(text)
    state |> write_unnamed(text) |> maybe_write_yank(text, kind) |> reset_active_register()
  end

  def put_register(%{reg: %{active: name} = reg} = state, text, kind)
      when name >= "A" and name <= "Z" do
    lower = String.downcase(name)
    existing = Registers.get(reg, lower) || ""
    appended = existing <> text

    state
    |> put_in_register(lower, appended)
    |> write_unnamed(text)
    |> maybe_write_yank(text, kind)
    |> reset_active_register()
  end

  def put_register(%{reg: %{active: name}} = state, text, kind)
      when name >= "a" and name <= "z" do
    state
    |> put_in_register(name, text)
    |> write_unnamed(text)
    |> maybe_write_yank(text, kind)
    |> reset_active_register()
  end

  def put_register(state, text, kind) do
    name = if state.reg.active == "", do: "", else: state.reg.active

    state
    |> put_in_register(name, text)
    |> maybe_write_yank(text, kind)
    |> reset_active_register()
  end

  @doc "Reads from the active register, falling back to the unnamed register."
  @spec get_register(state()) :: {String.t() | nil, state()}
  def get_register(%{reg: %{active: "+"}} = state) do
    text = Clipboard.read()
    {text, reset_active_register(state)}
  end

  def get_register(%{reg: reg} = state) do
    key = if reg.active == "", do: "", else: reg.active
    text = Registers.get(reg, key)
    {text, reset_active_register(state)}
  end

  @spec put_in_register(state(), String.t(), String.t()) :: state()
  def put_in_register(state, name, text) do
    %{state | reg: Registers.put(state.reg, name, text)}
  end

  @spec write_unnamed(state(), String.t()) :: state()
  def write_unnamed(state, text), do: put_in_register(state, "", text)

  @spec maybe_write_yank(state(), String.t(), :yank | :delete) :: state()
  def maybe_write_yank(state, text, :yank), do: put_in_register(state, "0", text)
  def maybe_write_yank(state, _text, :delete), do: state

  @spec reset_active_register(state()) :: state()
  def reset_active_register(state), do: %{state | reg: Registers.reset_active(state.reg)}

  # ── Positional helpers ──────────────────────────────────────────────────────

  @doc "Returns the two positions sorted so the lesser comes first."
  @spec sort_positions(GapBuffer.position(), GapBuffer.position()) ::
          {GapBuffer.position(), GapBuffer.position()}
  def sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @doc "Saves the jump position when the cursor crosses a line boundary."
  @spec save_jump_pos(state(), GapBuffer.position(), GapBuffer.position()) :: state()
  def save_jump_pos(state, {from_line, _} = from_pos, {to_line, _})
      when from_line != to_line do
    %{state | last_jump_pos: from_pos}
  end

  def save_jump_pos(state, _from_pos, _to_pos), do: state

  # ── Motion application ──────────────────────────────────────────────────────

  @doc "Applies a `(buf, pos) -> new_pos` motion function to the buffer cursor."
  @spec apply_motion(
          pid(),
          (GapBuffer.t(), Minga.Motion.position() -> Minga.Motion.position())
        ) :: :ok
  def apply_motion(buf, motion_fn) do
    gb = BufferServer.snapshot(buf)
    new_pos = motion_fn.(gb, GapBuffer.cursor(gb))
    BufferServer.move_to(buf, new_pos)
  end

  @doc "Resolves a motion atom to a new position in the buffer."
  @spec resolve_motion(GapBuffer.t(), Minga.Motion.position(), atom()) ::
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
    cursor = GapBuffer.cursor(gb)

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
    cursor = GapBuffer.cursor(gb)
    target = resolve_motion(gb, cursor, motion)
    {start_pos, end_pos} = sort_positions(cursor, target)

    case action do
      :delete ->
        text = GapBuffer.get_range(gb, start_pos, end_pos)
        BufferServer.delete_range(buf, start_pos, end_pos)
        put_register(state, text, :delete)

      :yank ->
        text = GapBuffer.get_range(gb, start_pos, end_pos)
        put_register(state, text, :yank)
    end
  end

  @doc "Applies a delete or yank operator over a text object range."
  @spec apply_text_object(state(), atom(), term(), text_object_action()) :: state()
  def apply_text_object(%{buf: %{buffer: buf}} = state, modifier, spec, action) do
    gb = BufferServer.snapshot(buf)
    cursor = GapBuffer.cursor(gb)
    range = compute_text_object_range(gb, cursor, modifier, spec)

    case {action, range} do
      {_, nil} ->
        state

      {:delete, {start_pos, end_pos}} ->
        text = GapBuffer.get_range(gb, start_pos, end_pos)
        BufferServer.delete_range(buf, start_pos, end_pos)
        put_register(state, text, :delete)

      {:yank, {start_pos, end_pos}} ->
        text = GapBuffer.get_range(gb, start_pos, end_pos)
        put_register(state, text, :yank)
    end
  end

  @doc "Computes the range for a text object modifier + spec pair."
  @spec compute_text_object_range(GapBuffer.t(), TextObject.position(), atom(), term()) ::
          TextObject.range()
  def compute_text_object_range(buf, pos, :inner, :word), do: TextObject.inner_word(buf, pos)
  def compute_text_object_range(buf, pos, :around, :word), do: TextObject.a_word(buf, pos)

  def compute_text_object_range(buf, pos, :inner, {:quote, q}),
    do: TextObject.inner_quotes(buf, pos, q)

  def compute_text_object_range(buf, pos, :around, {:quote, q}),
    do: TextObject.a_quotes(buf, pos, q)

  def compute_text_object_range(buf, pos, :inner, {:paren, open, close}),
    do: TextObject.inner_parens(buf, pos, open, close)

  def compute_text_object_range(buf, pos, :around, {:paren, open, close}),
    do: TextObject.a_parens(buf, pos, open, close)

  def compute_text_object_range(_buf, _pos, _modifier, _spec), do: nil

  @doc "Scrolls the buffer cursor by `delta` lines, clamping to bounds."
  @spec page_move(pid(), Viewport.t(), integer()) :: :ok
  def page_move(buf, _vp, delta) do
    gb = BufferServer.snapshot(buf)
    {line, col} = GapBuffer.cursor(gb)
    total_lines = GapBuffer.line_count(gb)
    target_line = max(0, min(line + delta, total_lines - 1))

    target_col =
      case GapBuffer.lines(gb, target_line, 1) do
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

  @doc "Returns a human-readable name for the buffer (buffer name, basename, or `[scratch]`)."
  @spec buffer_display_name(pid()) :: String.t()
  def buffer_display_name(buf) do
    case BufferServer.buffer_name(buf) do
      nil ->
        case BufferServer.file_path(buf) do
          nil -> "[scratch]"
          path -> Path.basename(path)
        end

      name ->
        name
    end
  end
end
