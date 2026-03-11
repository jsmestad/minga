defmodule Minga.Input.Vim do
  @moduledoc """
  Vim grammar interpreter for text input fields.

  Pure state machine that pairs with a `TextField` to provide vim-style
  editing: normal mode motions, operators composed with any motion or
  text object, visual selection, count prefixes, and undo/redo.

  Designed as a shared module usable by any text input surface in Minga
  (agent prompt, command line, search, eval input).

  ## Architecture

  The caller owns the mode lifecycle and routes keys accordingly:

  - In insert mode, the caller handles keys directly (self-insert,
    special keys like Enter and Ctrl+C via scope trie).
  - On Escape in insert mode, the caller calls `enter_normal/2`.
  - While in normal/visual/operator-pending mode, all keys go through
    `handle_key/4`. If it returns `:not_handled`, the caller falls
    through to scope bindings for meta keys (Ctrl+C, etc.).
  - When `handle_key/4` transitions to insert mode, `mode/1` returns
    `:insert` and the caller switches back to insert dispatch.

  ## Operator + motion composition

  Operators (d, c, y) compose with any motion or text object. Pressing
  `d` enters operator-pending mode. The next key(s) resolve a motion
  (e.g., `w`, `$`, `gg`) or text object (e.g., `iw`, `a"`). The
  operator is then applied to the range defined by the motion/object.

  Doubling the operator key (dd, cc, yy) applies to the current line.

  ## Count prefixes

  Digits 1-9 (and 0 after a count has started) accumulate a count that
  multiplies the next motion or operator. `3dw` = delete 3 words.
  `5j` = move down 5 lines.
  """

  alias Minga.Input.TextField
  alias Minga.Motion
  alias Minga.Text.Readable
  alias Minga.TextObject

  import Bitwise, only: [band: 2]

  @ctrl Minga.Port.Protocol.mod_ctrl()

  # Maximum undo history depth
  @max_undo 100

  @typedoc "Operator type for operator-pending mode."
  @type operator :: :delete | :change | :yank

  @typedoc """
  Internal state machine position.

  Most states are transient (operator-pending, find-char, text-object).
  The caller-visible mode is derived via `mode/1`.
  """
  @type state ::
          :insert
          | :normal
          | :visual
          | :visual_line
          | {:operator, operator()}
          | {:text_object, operator(), :inner | :a}
          | {:visual_text_object, :inner | :a}
          | {:find_char, :f | :F | :t | :T}
          | {:operator_find, operator(), :f | :F | :t | :T}
          | :g_prefix
          | {:operator_g, operator()}
          | {:replace_char}

  @typedoc "Vim editing state. Pair with a `TextField.t()` for use."
  @type t :: %__MODULE__{
          state: state(),
          count: non_neg_integer(),
          register: String.t(),
          visual_anchor: TextField.cursor() | nil,
          undo_stack: [TextField.t()],
          redo_stack: [TextField.t()]
        }

  @enforce_keys []
  defstruct state: :insert,
            count: 0,
            register: "",
            visual_anchor: nil,
            undo_stack: [],
            redo_stack: []

  # ── Public API ─────────────────────────────────────────────────────────

  @doc "Creates a new Vim state starting in insert mode."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Transitions to normal mode. Clamps the cursor so it can't be past the
  last character on the line (vim normal-mode semantics).
  """
  @spec enter_normal(t(), TextField.t()) :: {t(), TextField.t()}
  def enter_normal(vim, tf) do
    tf = clamp_cursor_normal(tf)
    {%{vim | state: :normal, count: 0}, tf}
  end

  @doc "Transitions to insert mode."
  @spec enter_insert(t()) :: t()
  def enter_insert(vim), do: %{vim | state: :insert, count: 0}

  @doc "Returns the caller-visible mode for UI display and dispatch."
  @spec mode(t()) :: :insert | :normal | :visual | :visual_line | :operator_pending
  def mode(%__MODULE__{state: :insert}), do: :insert
  def mode(%__MODULE__{state: :normal}), do: :normal
  def mode(%__MODULE__{state: :visual}), do: :visual
  def mode(%__MODULE__{state: :visual_line}), do: :visual_line
  def mode(%__MODULE__{state: :g_prefix}), do: :normal
  def mode(%__MODULE__{state: {:find_char, _}}), do: :normal
  def mode(%__MODULE__{state: {:replace_char}}), do: :normal
  def mode(%__MODULE__{state: _}), do: :operator_pending

  @doc """
  Returns the visual selection range as `{from, to}` (sorted), or nil if
  not in visual mode. For visual line mode, the range covers full lines.
  """
  @spec visual_range(t(), TextField.t()) :: {TextField.cursor(), TextField.cursor()} | nil
  def visual_range(%__MODULE__{state: :visual, visual_anchor: anchor}, tf)
      when is_tuple(anchor) do
    sort_positions(anchor, tf.cursor)
  end

  def visual_range(%__MODULE__{state: :visual_line, visual_anchor: anchor}, tf)
      when is_tuple(anchor) do
    {from, to} = sort_positions(anchor, tf.cursor)
    {from_line, _} = from
    {to_line, _} = to
    to_line_len = String.length(Readable.line_at(tf, to_line) || "")
    {{from_line, 0}, {to_line, to_line_len}}
  end

  def visual_range(_, _), do: nil

  @doc """
  Main key dispatch. Call for every key event when `mode/1` is not
  `:insert`. Returns `{:handled, vim, tf}` if the key was consumed,
  or `:not_handled` to fall through to scope bindings.
  """
  @spec handle_key(t(), TextField.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, t(), TextField.t()} | :not_handled
  def handle_key(%__MODULE__{state: :insert}, _tf, _cp, _mods), do: :not_handled
  def handle_key(%__MODULE__{state: :normal} = v, tf, cp, m), do: handle_normal(v, tf, cp, m)
  def handle_key(%__MODULE__{state: :g_prefix} = v, tf, cp, _m), do: handle_g_prefix(v, tf, cp)

  def handle_key(%__MODULE__{state: {:operator, _}} = v, tf, cp, m),
    do: handle_operator(v, tf, cp, m)

  def handle_key(%__MODULE__{state: {:operator_g, _}} = v, tf, cp, _m),
    do: handle_operator_g(v, tf, cp)

  def handle_key(%__MODULE__{state: {:text_object, _, _}} = v, tf, cp, _m),
    do: handle_text_object_key(v, tf, cp)

  def handle_key(%__MODULE__{state: {:find_char, _}} = v, tf, cp, _m),
    do: handle_find(v, tf, cp)

  def handle_key(%__MODULE__{state: {:operator_find, _, _}} = v, tf, cp, _m),
    do: handle_operator_find_char(v, tf, cp)

  def handle_key(%__MODULE__{state: :visual} = v, tf, cp, m),
    do: handle_visual(v, tf, cp, m)

  def handle_key(%__MODULE__{state: :visual_line} = v, tf, cp, m),
    do: handle_visual_line(v, tf, cp, m)

  def handle_key(%__MODULE__{state: {:visual_text_object, _}} = v, tf, cp, _m),
    do: handle_visual_text_object(v, tf, cp)

  def handle_key(%__MODULE__{state: {:replace_char}} = v, tf, cp, _m),
    do: handle_replace_char(v, tf, cp)

  # ── Normal mode ────────────────────────────────────────────────────────

  @spec handle_normal(t(), TextField.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, t(), TextField.t()} | :not_handled
  defp handle_normal(vim, tf, cp, mods) when band(mods, @ctrl) != 0 do
    case cp do
      # Ctrl+R = redo
      ?r -> redo(vim, tf)
      _ -> :not_handled
    end
  end

  defp handle_normal(vim, tf, cp, _mods) do
    if counting?(vim, cp) do
      {:handled, accumulate_count(vim, cp - ?0), tf}
    else
      handle_normal_key(vim, tf, cp)
    end
  end

  @spec handle_normal_key(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()} | :not_handled
  defp handle_normal_key(vim, tf, cp) do
    normal_mode_transition(vim, tf, cp) ||
      normal_operator(vim, tf, cp) ||
      normal_shortcut(vim, tf, cp) ||
      normal_state_change(vim, tf, cp) ||
      try_motion(vim, tf, cp)
  end

  @spec normal_mode_transition(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()} | nil
  defp normal_mode_transition(vim, tf, ?i), do: to_insert(vim, tf)
  defp normal_mode_transition(vim, tf, ?a), do: to_insert(vim, TextField.move_right(tf))
  defp normal_mode_transition(vim, tf, ?A), do: to_insert(vim, TextField.move_end(tf))
  defp normal_mode_transition(vim, tf, ?I), do: to_insert(vim, TextField.move_home(tf))
  defp normal_mode_transition(vim, tf, ?o), do: open_line(vim, tf, :below)
  defp normal_mode_transition(vim, tf, ?O), do: open_line(vim, tf, :above)

  defp normal_mode_transition(vim, tf, ?v),
    do: {:handled, %{vim | state: :visual, visual_anchor: tf.cursor, count: 0}, tf}

  defp normal_mode_transition(vim, tf, ?V),
    do: {:handled, %{vim | state: :visual_line, visual_anchor: tf.cursor, count: 0}, tf}

  defp normal_mode_transition(_vim, _tf, _cp), do: nil

  @spec normal_operator(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()} | nil
  defp normal_operator(vim, tf, ?d), do: {:handled, %{vim | state: {:operator, :delete}}, tf}
  defp normal_operator(vim, tf, ?c), do: {:handled, %{vim | state: {:operator, :change}}, tf}
  defp normal_operator(vim, tf, ?y), do: {:handled, %{vim | state: {:operator, :yank}}, tf}
  defp normal_operator(vim, tf, ?x), do: delete_chars(vim, tf, :forward)
  defp normal_operator(vim, tf, ?X), do: delete_chars(vim, tf, :backward)
  defp normal_operator(vim, tf, ?D), do: operator_to_eol(vim, tf, :delete)
  defp normal_operator(vim, tf, ?C), do: operator_to_eol(vim, tf, :change)
  defp normal_operator(vim, tf, ?s), do: substitute_char(vim, tf)
  defp normal_operator(vim, tf, ?S), do: line_operator(vim, tf, :change)
  defp normal_operator(vim, tf, ?r), do: {:handled, %{vim | state: {:replace_char}}, tf}
  defp normal_operator(_vim, _tf, _cp), do: nil

  @spec normal_shortcut(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()} | nil
  defp normal_shortcut(vim, tf, ?p), do: paste(vim, tf, :after)
  defp normal_shortcut(vim, tf, ?P), do: paste(vim, tf, :before)
  defp normal_shortcut(vim, tf, ?u), do: undo(vim, tf)
  defp normal_shortcut(vim, tf, ?J), do: join_lines(vim, tf)
  defp normal_shortcut(vim, tf, ?G), do: go_to_line(vim, tf)
  defp normal_shortcut(_vim, _tf, _cp), do: nil

  @spec normal_state_change(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()} | :not_handled | nil
  defp normal_state_change(vim, tf, ?f), do: {:handled, %{vim | state: {:find_char, :f}}, tf}
  defp normal_state_change(vim, tf, ?F), do: {:handled, %{vim | state: {:find_char, :F}}, tf}
  defp normal_state_change(vim, tf, ?t), do: {:handled, %{vim | state: {:find_char, :t}}, tf}
  defp normal_state_change(vim, tf, ?T), do: {:handled, %{vim | state: {:find_char, :T}}, tf}
  defp normal_state_change(vim, tf, ?g), do: {:handled, %{vim | state: :g_prefix}, tf}
  # Escape → pass through to scope (unfocus, etc.)
  defp normal_state_change(_vim, _tf, 27), do: :not_handled
  defp normal_state_change(_vim, _tf, _cp), do: nil

  # ── g prefix (gg, etc.) ─────────────────────────────────────────────────

  @spec handle_g_prefix(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_g_prefix(vim, tf, ?g) do
    count = effective_count(vim)

    target =
      if vim.count > 0 do
        # 3gg = go to line 3 (1-based)
        line = min(count - 1, TextField.line_count(tf) - 1) |> max(0)
        {line, 0}
      else
        Motion.document_start(tf)
      end

    {:handled, %{vim | state: :normal, count: 0}, TextField.set_cursor(tf, target)}
  end

  defp handle_g_prefix(vim, tf, _cp) do
    # Unknown g-command, cancel
    {:handled, %{vim | state: :normal, count: 0}, tf}
  end

  # ── Operator-pending mode ───────────────────────────────────────────────

  @spec handle_operator(t(), TextField.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_operator(%{state: {:operator, op}} = vim, tf, cp, mods)
       when band(mods, @ctrl) != 0 do
    # Ctrl key in operator-pending: cancel
    _ = {op, cp}
    {:handled, %{vim | state: :normal, count: 0}, tf}
  end

  defp handle_operator(%{state: {:operator, op}} = vim, tf, cp, _mods) do
    if counting?(vim, cp) do
      {:handled, accumulate_count(vim, cp - ?0), tf}
    else
      handle_operator_key(vim, tf, op, cp)
    end
  end

  @spec handle_operator_key(t(), TextField.t(), operator(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_operator_key(vim, tf, op, cp) do
    # Check for doubled operator first (dd, cc, yy)
    if cp == operator_codepoint(op) do
      line_operator(vim, tf, op)
    else
      handle_operator_key_dispatch(vim, tf, op, cp)
    end
  end

  @spec handle_operator_key_dispatch(t(), TextField.t(), operator(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_operator_key_dispatch(vim, tf, op, cp) do
    case cp do
      # Text object prefix
      ?i -> {:handled, %{vim | state: {:text_object, op, :inner}}, tf}
      ?a -> {:handled, %{vim | state: {:text_object, op, :a}}, tf}
      # Find-char in operator context
      ?f -> {:handled, %{vim | state: {:operator_find, op, :f}}, tf}
      ?F -> {:handled, %{vim | state: {:operator_find, op, :F}}, tf}
      ?t -> {:handled, %{vim | state: {:operator_find, op, :t}}, tf}
      ?T -> {:handled, %{vim | state: {:operator_find, op, :T}}, tf}
      # g prefix in operator context (dgg, cgg, ygg)
      ?g -> {:handled, %{vim | state: {:operator_g, op}}, tf}
      # G in operator context (dG, cG, yG)
      ?G -> operator_to_line(vim, tf, op)
      # Escape cancels
      27 -> {:handled, %{vim | state: :normal, count: 0}, tf}
      # Try as motion
      _ -> try_operator_motion(vim, tf, op, cp)
    end
  end

  # ── operator + g prefix (dgg, etc.) ─────────────────────────────────────

  @spec handle_operator_g(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_operator_g(%{state: {:operator_g, op}} = vim, tf, ?g) do
    # dgg = delete from cursor to start of document
    target = Motion.document_start(tf)
    apply_operator_with_motion(vim, tf, op, tf.cursor, target, :linewise)
  end

  defp handle_operator_g(vim, tf, _cp) do
    {:handled, %{vim | state: :normal, count: 0}, tf}
  end

  # ── Text object resolution ──────────────────────────────────────────────

  @spec handle_text_object_key(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_text_object_key(%{state: {:text_object, op, scope}} = vim, tf, cp) do
    case resolve_text_object(tf, tf.cursor, scope, cp) do
      {from, to} ->
        apply_text_object_operator(vim, tf, op, from, to)

      nil ->
        # Unknown text object key, cancel
        {:handled, %{vim | state: :normal, count: 0}, tf}
    end
  end

  # ── Find-char (normal mode) ─────────────────────────────────────────────

  @spec handle_find(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_find(%{state: {:find_char, type}} = vim, tf, cp) when cp >= 32 do
    char = <<cp::utf8>>
    count = effective_count(vim)
    target = apply_find_n(tf, tf.cursor, type, char, count)
    {:handled, %{vim | state: :normal, count: 0}, TextField.set_cursor(tf, target)}
  end

  defp handle_find(vim, tf, _cp) do
    {:handled, %{vim | state: :normal, count: 0}, tf}
  end

  # ── Find-char (operator context: df, dt, etc.) ──────────────────────────

  @spec handle_operator_find_char(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_operator_find_char(%{state: {:operator_find, op, type}} = vim, tf, cp)
       when cp >= 32 do
    char = <<cp::utf8>>
    count = effective_count(vim)
    target = apply_find_n(tf, tf.cursor, type, char, count)

    if target == tf.cursor do
      # Character not found, cancel
      {:handled, %{vim | state: :normal, count: 0}, tf}
    else
      motion_type = find_motion_type(type)
      apply_operator_with_motion(vim, tf, op, tf.cursor, target, motion_type)
    end
  end

  defp handle_operator_find_char(vim, tf, _cp) do
    {:handled, %{vim | state: :normal, count: 0}, tf}
  end

  # ── Replace char ────────────────────────────────────────────────────────

  @spec handle_replace_char(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_replace_char(vim, tf, cp) when cp >= 32 do
    vim = push_undo(vim, tf)
    {line, col} = tf.cursor
    line_text = Readable.line_at(tf, line) || ""
    line_len = String.length(line_text)

    new_tf =
      if col < line_len do
        {new_tf, _} = TextField.delete_range(tf, {line, col}, {line, col + 1})

        TextField.insert_char(new_tf, <<cp::utf8>>)
        |> TextField.move_left()
      else
        tf
      end

    {:handled, %{vim | state: :normal, count: 0}, new_tf}
  end

  defp handle_replace_char(vim, tf, _cp) do
    {:handled, %{vim | state: :normal, count: 0}, tf}
  end

  # ── Visual mode ─────────────────────────────────────────────────────────

  @spec handle_visual(t(), TextField.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_visual(vim, tf, cp, mods) when band(mods, @ctrl) != 0 do
    _ = cp
    # Ctrl key in visual: cancel
    {:handled, %{vim | state: :normal, visual_anchor: nil, count: 0}, tf}
  end

  defp handle_visual(vim, tf, cp, _mods) do
    visual_key(vim, tf, cp) || try_visual_motion(vim, tf, cp)
  end

  @spec visual_key(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()} | nil
  defp visual_key(vim, tf, 27),
    do: {:handled, %{vim | state: :normal, visual_anchor: nil, count: 0}, tf}

  defp visual_key(vim, tf, ?v),
    do: {:handled, %{vim | state: :normal, visual_anchor: nil, count: 0}, tf}

  defp visual_key(vim, tf, ?V), do: {:handled, %{vim | state: :visual_line, count: 0}, tf}
  defp visual_key(vim, tf, ?d), do: visual_operator(vim, tf, :delete)
  defp visual_key(vim, tf, ?x), do: visual_operator(vim, tf, :delete)
  defp visual_key(vim, tf, ?c), do: visual_operator(vim, tf, :change)
  defp visual_key(vim, tf, ?s), do: visual_operator(vim, tf, :change)
  defp visual_key(vim, tf, ?y), do: visual_operator(vim, tf, :yank)
  defp visual_key(vim, tf, ?i), do: {:handled, %{vim | state: {:visual_text_object, :inner}}, tf}
  defp visual_key(vim, tf, ?a), do: {:handled, %{vim | state: {:visual_text_object, :a}}, tf}
  defp visual_key(vim, tf, ?f), do: {:handled, %{vim | state: {:find_char, :f}}, tf}
  defp visual_key(vim, tf, ?F), do: {:handled, %{vim | state: {:find_char, :F}}, tf}
  defp visual_key(vim, tf, ?t), do: {:handled, %{vim | state: {:find_char, :t}}, tf}
  defp visual_key(vim, tf, ?T), do: {:handled, %{vim | state: {:find_char, :T}}, tf}
  defp visual_key(vim, tf, ?g), do: {:handled, %{vim | state: :g_prefix}, tf}
  defp visual_key(vim, tf, ?G), do: go_to_line(vim, tf)
  defp visual_key(_vim, _tf, _cp), do: nil

  # ── Visual line mode ────────────────────────────────────────────────────

  @spec handle_visual_line(t(), TextField.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_visual_line(vim, tf, cp, mods) when band(mods, @ctrl) != 0 do
    _ = cp
    {:handled, %{vim | state: :normal, visual_anchor: nil, count: 0}, tf}
  end

  defp handle_visual_line(vim, tf, cp, _mods) do
    case cp do
      27 -> {:handled, %{vim | state: :normal, visual_anchor: nil, count: 0}, tf}
      ?V -> {:handled, %{vim | state: :normal, visual_anchor: nil, count: 0}, tf}
      ?v -> {:handled, %{vim | state: :visual, count: 0}, tf}
      ?d -> visual_line_operator(vim, tf, :delete)
      ?x -> visual_line_operator(vim, tf, :delete)
      ?c -> visual_line_operator(vim, tf, :change)
      ?y -> visual_line_operator(vim, tf, :yank)
      ?g -> {:handled, %{vim | state: :g_prefix}, tf}
      ?G -> go_to_line(vim, tf)
      _ -> try_visual_motion(vim, tf, cp)
    end
  end

  # ── Visual text objects ──────────────────────────────────────────────────

  @spec handle_visual_text_object(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp handle_visual_text_object(%{state: {:visual_text_object, scope}} = vim, tf, cp) do
    case resolve_text_object(tf, tf.cursor, scope, cp) do
      {from, to} ->
        # Extend the visual selection to cover the text object
        {:handled, %{vim | state: :visual, visual_anchor: from}, TextField.set_cursor(tf, to)}

      nil ->
        {:handled, %{vim | state: :visual, count: 0}, tf}
    end
  end

  # ── Motion dispatch (shared by normal, visual, operator-pending) ────────

  @spec try_motion(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()} | :not_handled
  defp try_motion(vim, tf, cp) do
    case resolve_motion(tf, tf.cursor, cp, effective_count(vim)) do
      {:ok, target} ->
        new_tf = TextField.set_cursor(tf, clamp_normal(tf, target))
        {:handled, %{vim | count: 0}, new_tf}

      :not_found ->
        # Unknown key in normal mode: consume it (don't pass through)
        {:handled, %{vim | count: 0}, tf}
    end
  end

  @spec try_visual_motion(t(), TextField.t(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp try_visual_motion(vim, tf, cp) do
    case resolve_motion(tf, tf.cursor, cp, effective_count(vim)) do
      {:ok, target} ->
        {:handled, %{vim | count: 0}, TextField.set_cursor(tf, target)}

      :not_found ->
        {:handled, %{vim | count: 0}, tf}
    end
  end

  @spec try_operator_motion(t(), TextField.t(), operator(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp try_operator_motion(vim, tf, op, cp) do
    case resolve_motion(tf, tf.cursor, cp, effective_count(vim)) do
      {:ok, target} ->
        mtype = motion_type(cp)
        apply_operator_with_motion(vim, tf, op, tf.cursor, target, mtype)

      :not_found ->
        # Unknown motion, cancel operator
        {:handled, %{vim | state: :normal, count: 0}, tf}
    end
  end

  # ── Resolve motion codepoint to target position ──────────────────────────

  @spec resolve_motion(TextField.t(), TextField.cursor(), non_neg_integer(), pos_integer()) ::
          {:ok, TextField.cursor()} | :not_found
  defp resolve_motion(tf, cursor, cp, count) do
    case motion_fn(cp) do
      nil -> :not_found
      fun -> {:ok, apply_n(tf, cursor, fun, count)}
    end
  end

  @spec motion_fn(non_neg_integer()) ::
          (TextField.t(), TextField.cursor() -> TextField.cursor()) | nil
  defp motion_fn(?h), do: &move_left/2
  defp motion_fn(?l), do: &move_right/2
  defp motion_fn(?j), do: &move_down/2
  defp motion_fn(?k), do: &move_up/2
  defp motion_fn(?w), do: &Motion.word_forward/2
  defp motion_fn(?b), do: &Motion.word_backward/2
  defp motion_fn(?e), do: &Motion.word_end/2
  defp motion_fn(?W), do: &Motion.word_forward_big/2
  defp motion_fn(?B), do: &Motion.word_backward_big/2
  defp motion_fn(?E), do: &Motion.word_end_big/2
  defp motion_fn(?0), do: &Motion.line_start/2
  defp motion_fn(?$), do: &Motion.line_end/2
  defp motion_fn(?^), do: &Motion.first_non_blank/2
  defp motion_fn(?{), do: &Motion.paragraph_backward/2
  defp motion_fn(?}), do: &Motion.paragraph_forward/2
  defp motion_fn(?%), do: &Motion.match_bracket/2
  # Arrow keys (macOS private-use codepoints)
  defp motion_fn(0xF700), do: &move_up/2
  defp motion_fn(0xF701), do: &move_down/2
  defp motion_fn(0xF702), do: &move_left/2
  defp motion_fn(0xF703), do: &move_right/2
  defp motion_fn(_), do: nil

  # In normal mode, h/l don't wrap across lines (vim semantics)
  @spec move_left(TextField.t(), TextField.cursor()) :: TextField.cursor()
  defp move_left(_tf, {line, col}), do: {line, max(col - 1, 0)}

  @spec move_right(TextField.t(), TextField.cursor()) :: TextField.cursor()
  defp move_right(tf, {line, col}) do
    line_len = String.length(Readable.line_at(tf, line) || "")
    {line, min(col + 1, max(line_len - 1, 0))}
  end

  @spec move_down(TextField.t(), TextField.cursor()) :: TextField.cursor()
  defp move_down(tf, {line, col}) do
    max_line = TextField.line_count(tf) - 1

    if line < max_line do
      next_len = String.length(Readable.line_at(tf, line + 1) || "")
      {line + 1, min(col, max(next_len - 1, 0))}
    else
      {line, col}
    end
  end

  @spec move_up(TextField.t(), TextField.cursor()) :: TextField.cursor()
  defp move_up(_tf, {0, col}), do: {0, col}

  defp move_up(tf, {line, col}) do
    prev_len = String.length(Readable.line_at(tf, line - 1) || "")
    {line - 1, min(col, max(prev_len - 1, 0))}
  end

  # Apply a motion function N times
  @spec apply_n(
          TextField.t(),
          TextField.cursor(),
          (TextField.t(), TextField.cursor() -> TextField.cursor()),
          pos_integer()
        ) :: TextField.cursor()
  defp apply_n(_tf, pos, _fun, 0), do: pos
  defp apply_n(tf, pos, fun, n), do: apply_n(tf, fun.(tf, pos), fun, n - 1)

  # ── Motion types (exclusive vs inclusive vs linewise) ─────────────────────

  @spec motion_type(non_neg_integer()) :: :exclusive | :inclusive | :linewise
  defp motion_type(?h), do: :exclusive
  defp motion_type(?l), do: :exclusive
  defp motion_type(?j), do: :linewise
  defp motion_type(?k), do: :linewise
  defp motion_type(?w), do: :exclusive
  defp motion_type(?b), do: :exclusive
  defp motion_type(?e), do: :inclusive
  defp motion_type(?W), do: :exclusive
  defp motion_type(?B), do: :exclusive
  defp motion_type(?E), do: :inclusive
  defp motion_type(?0), do: :exclusive
  defp motion_type(?$), do: :inclusive
  defp motion_type(?^), do: :exclusive
  defp motion_type(?{), do: :exclusive
  defp motion_type(?}), do: :exclusive
  defp motion_type(?%), do: :inclusive
  defp motion_type(0xF700), do: :linewise
  defp motion_type(0xF701), do: :linewise
  defp motion_type(0xF702), do: :exclusive
  defp motion_type(0xF703), do: :exclusive
  defp motion_type(_), do: :exclusive

  @spec find_motion_type(:f | :F | :t | :T) :: :inclusive | :exclusive
  defp find_motion_type(:f), do: :inclusive
  defp find_motion_type(:F), do: :inclusive
  defp find_motion_type(:t), do: :inclusive
  defp find_motion_type(:T), do: :inclusive

  # ── Text object resolution ──────────────────────────────────────────────

  @spec resolve_text_object(TextField.t(), TextField.cursor(), :inner | :a, non_neg_integer()) ::
          {TextField.cursor(), TextField.cursor()} | nil
  defp resolve_text_object(tf, cursor, scope, cp) do
    case text_object_spec(cp) do
      nil -> nil
      {:word} -> tobj(apply_word_object(tf, cursor, scope))
      {:quotes, char} -> tobj(apply_quotes_object(tf, cursor, scope, char))
      {:parens, open, close} -> tobj(apply_parens_object(tf, cursor, scope, open, close))
    end
  end

  @spec text_object_spec(non_neg_integer()) ::
          {:word} | {:quotes, String.t()} | {:parens, String.t(), String.t()} | nil
  defp text_object_spec(?w), do: {:word}
  defp text_object_spec(?W), do: {:word}
  defp text_object_spec(?"), do: {:quotes, "\""}
  defp text_object_spec(?'), do: {:quotes, "'"}
  defp text_object_spec(?`), do: {:quotes, "`"}
  defp text_object_spec(?\(), do: {:parens, "(", ")"}
  defp text_object_spec(?)), do: {:parens, "(", ")"}
  defp text_object_spec(?[), do: {:parens, "[", "]"}
  defp text_object_spec(?]), do: {:parens, "[", "]"}
  defp text_object_spec(?{), do: {:parens, "{", "}"}
  defp text_object_spec(?}), do: {:parens, "{", "}"}
  defp text_object_spec(?<), do: {:parens, "<", ">"}
  defp text_object_spec(?>), do: {:parens, "<", ">"}
  defp text_object_spec(_), do: nil

  defp apply_word_object(tf, cursor, :inner), do: TextObject.inner_word(tf, cursor)
  defp apply_word_object(tf, cursor, :a), do: TextObject.a_word(tf, cursor)

  defp apply_quotes_object(tf, cursor, :inner, c), do: TextObject.inner_quotes(tf, cursor, c)
  defp apply_quotes_object(tf, cursor, :a, c), do: TextObject.a_quotes(tf, cursor, c)

  defp apply_parens_object(tf, cursor, :inner, o, c),
    do: TextObject.inner_parens(tf, cursor, o, c)

  defp apply_parens_object(tf, cursor, :a, o, c), do: TextObject.a_parens(tf, cursor, o, c)

  # TextObject returns {from, to} or {pos, pos} on failure; normalize nil
  @spec tobj({TextField.cursor(), TextField.cursor()}) ::
          {TextField.cursor(), TextField.cursor()} | nil
  defp tobj({from, to}) when from == to, do: nil
  defp tobj(range), do: range

  # ── Operators ───────────────────────────────────────────────────────────

  @spec apply_operator_with_motion(
          t(),
          TextField.t(),
          operator(),
          TextField.cursor(),
          TextField.cursor(),
          :exclusive | :inclusive | :linewise
        ) ::
          {:handled, t(), TextField.t()}
  defp apply_operator_with_motion(vim, tf, op, cursor, target, :linewise) do
    {from, to} = sort_positions(cursor, target)
    {from_line, _} = from
    {to_line, _} = to
    delete_line_range(vim, tf, op, from_line, to_line)
  end

  defp apply_operator_with_motion(vim, tf, op, cursor, target, motion_type) do
    {from, to} = sort_positions(cursor, target)

    to =
      case motion_type do
        :inclusive ->
          {to_line, to_col} = to
          {to_line, to_col + 1}

        :exclusive ->
          to
      end

    apply_operator_to_range(vim, tf, op, from, to)
  end

  @spec apply_text_object_operator(
          t(),
          TextField.t(),
          operator(),
          TextField.cursor(),
          TextField.cursor()
        ) ::
          {:handled, t(), TextField.t()}
  defp apply_text_object_operator(vim, tf, op, from, to) do
    # Text objects are always inclusive of `to`
    {to_line, to_col} = to
    apply_operator_to_range(vim, tf, op, from, {to_line, to_col + 1})
  end

  @spec apply_operator_to_range(
          t(),
          TextField.t(),
          operator(),
          TextField.cursor(),
          TextField.cursor()
        ) ::
          {:handled, t(), TextField.t()}
  defp apply_operator_to_range(vim, tf, :delete, from, to) do
    vim = push_undo(vim, tf)
    {new_tf, deleted} = TextField.delete_range(tf, from, to)
    new_tf = clamp_cursor_normal(new_tf)
    {:handled, %{vim | state: :normal, count: 0, register: deleted}, new_tf}
  end

  defp apply_operator_to_range(vim, tf, :change, from, to) do
    vim = push_undo(vim, tf)
    {new_tf, deleted} = TextField.delete_range(tf, from, to)
    {:handled, %{vim | state: :insert, count: 0, register: deleted}, new_tf}
  end

  defp apply_operator_to_range(vim, tf, :yank, from, to) do
    yanked = TextField.get_range(tf, from, to)
    {:handled, %{vim | state: :normal, count: 0, register: yanked}, tf}
  end

  # ── Visual operators ─────────────────────────────────────────────────────

  @spec visual_operator(t(), TextField.t(), operator()) :: {:handled, t(), TextField.t()}
  defp visual_operator(vim, tf, op) do
    {from, to} = sort_positions(vim.visual_anchor || tf.cursor, tf.cursor)
    {to_line, to_col} = to
    # Visual selection is inclusive of the character at cursor
    apply_visual_op(vim, tf, op, from, {to_line, to_col + 1})
  end

  @spec visual_line_operator(t(), TextField.t(), operator()) :: {:handled, t(), TextField.t()}
  defp visual_line_operator(vim, tf, op) do
    {from, to} = sort_positions(vim.visual_anchor || tf.cursor, tf.cursor)
    {from_line, _} = from
    {to_line, _} = to
    delete_line_range(vim, tf, op, from_line, to_line)
  end

  @spec apply_visual_op(t(), TextField.t(), operator(), TextField.cursor(), TextField.cursor()) ::
          {:handled, t(), TextField.t()}
  defp apply_visual_op(vim, tf, op, from, to) do
    vim = %{vim | visual_anchor: nil}
    apply_operator_to_range(vim, tf, op, from, to)
  end

  # ── Line operations (dd, cc, yy, S) ──────────────────────────────────────

  @spec line_operator(t(), TextField.t(), operator()) :: {:handled, t(), TextField.t()}
  defp line_operator(vim, tf, op) do
    {line, _} = tf.cursor
    count = effective_count(vim)
    max_line = min(line + count - 1, TextField.line_count(tf) - 1)
    delete_line_range(vim, tf, op, line, max_line)
  end

  @spec delete_line_range(t(), TextField.t(), operator(), non_neg_integer(), non_neg_integer()) ::
          {:handled, t(), TextField.t()}
  defp delete_line_range(vim, tf, :yank, from_line, to_line) do
    lines = for i <- from_line..to_line, do: Readable.line_at(tf, i) || ""
    yanked = Enum.join(lines, "\n")
    {:handled, %{vim | state: :normal, count: 0, register: yanked, visual_anchor: nil}, tf}
  end

  defp delete_line_range(vim, tf, :change, from_line, to_line) do
    # cc: replace the target lines with a single empty line, enter insert.
    vim = push_undo(vim, tf)
    lines = for i <- from_line..to_line, do: Readable.line_at(tf, i) || ""
    deleted = Enum.join(lines, "\n")

    remaining =
      tf.lines
      |> Enum.with_index()
      |> Enum.reject(fn {_, i} -> i >= from_line and i <= to_line end)
      |> Enum.map(&elem(&1, 0))

    # Insert an empty line where the deleted ones were
    new_lines = List.insert_at(remaining, from_line, "")
    new_tf = %{tf | lines: new_lines, cursor: {from_line, 0}}
    {:handled, %{vim | state: :insert, count: 0, register: deleted, visual_anchor: nil}, new_tf}
  end

  defp delete_line_range(vim, tf, :delete, from_line, to_line) do
    vim = push_undo(vim, tf)
    lines = for i <- from_line..to_line, do: Readable.line_at(tf, i) || ""
    deleted = Enum.join(lines, "\n")

    remaining =
      tf.lines
      |> Enum.with_index()
      |> Enum.reject(fn {_, i} -> i >= from_line and i <= to_line end)
      |> Enum.map(&elem(&1, 0))

    new_lines = if remaining == [], do: [""], else: remaining
    new_line = min(from_line, length(new_lines) - 1)
    new_tf = %{tf | lines: new_lines, cursor: {new_line, 0}}
    {:handled, %{vim | state: :normal, count: 0, register: deleted, visual_anchor: nil}, new_tf}
  end

  # ── Shortcuts ───────────────────────────────────────────────────────────

  @spec delete_chars(t(), TextField.t(), :forward | :backward) :: {:handled, t(), TextField.t()}
  defp delete_chars(vim, tf, direction) do
    vim = push_undo(vim, tf)
    count = effective_count(vim)
    {new_tf, deleted} = delete_chars_impl(tf, direction, count, "")
    new_tf = clamp_cursor_normal(new_tf)
    {:handled, %{vim | state: :normal, count: 0, register: deleted}, new_tf}
  end

  @spec delete_chars_impl(TextField.t(), :forward | :backward, non_neg_integer(), String.t()) ::
          {TextField.t(), String.t()}
  defp delete_chars_impl(tf, _dir, 0, acc), do: {tf, acc}

  defp delete_chars_impl(tf, :forward, n, acc) do
    {line, col} = tf.cursor
    line_text = Readable.line_at(tf, line) || ""

    if col < String.length(line_text) do
      char = String.at(line_text, col)
      {new_tf, _} = TextField.delete_range(tf, {line, col}, {line, col + 1})
      delete_chars_impl(new_tf, :forward, n - 1, acc <> char)
    else
      {tf, acc}
    end
  end

  defp delete_chars_impl(tf, :backward, n, acc) do
    {_line, col} = tf.cursor

    if col > 0 do
      new_tf = TextField.delete_backward(tf)
      {new_line, new_col} = new_tf.cursor
      char = String.at(Readable.line_at(tf, new_line) || "", new_col) || ""
      delete_chars_impl(new_tf, :backward, n - 1, char <> acc)
    else
      {tf, acc}
    end
  end

  @spec operator_to_eol(t(), TextField.t(), operator()) :: {:handled, t(), TextField.t()}
  defp operator_to_eol(vim, tf, op) do
    {line, _} = tf.cursor
    line_text = Readable.line_at(tf, line) || ""
    eol = String.length(line_text)
    apply_operator_to_range(vim, tf, op, tf.cursor, {line, eol})
  end

  @spec operator_to_line(t(), TextField.t(), operator()) :: {:handled, t(), TextField.t()}
  defp operator_to_line(vim, tf, op) do
    # dG, cG, yG: operate from current line to last line (or count line)
    {line, _} = tf.cursor
    max_line = TextField.line_count(tf) - 1

    target_line =
      if vim.count > 0, do: min(vim.count - 1, max_line), else: max_line

    {from_line, to_line} =
      if target_line >= line, do: {line, target_line}, else: {target_line, line}

    delete_line_range(vim, tf, op, from_line, to_line)
  end

  @spec substitute_char(t(), TextField.t()) :: {:handled, t(), TextField.t()}
  defp substitute_char(vim, tf) do
    vim = push_undo(vim, tf)
    {line, col} = tf.cursor
    line_text = Readable.line_at(tf, line) || ""
    count = min(effective_count(vim), String.length(line_text) - col)

    {new_tf, deleted} =
      if count > 0 do
        TextField.delete_range(tf, {line, col}, {line, col + count})
      else
        {tf, ""}
      end

    {:handled, %{vim | state: :insert, count: 0, register: deleted}, new_tf}
  end

  @spec go_to_line(t(), TextField.t()) :: {:handled, t(), TextField.t()}
  defp go_to_line(vim, tf) do
    max_line = TextField.line_count(tf) - 1

    target_line =
      if vim.count > 0 do
        min(vim.count - 1, max_line) |> max(0)
      else
        max_line
      end

    {:handled, %{vim | state: :normal, count: 0}, TextField.set_cursor(tf, {target_line, 0})}
  end

  @spec join_lines(t(), TextField.t()) :: {:handled, t(), TextField.t()}
  defp join_lines(vim, tf) do
    {line, _} = tf.cursor

    if line < TextField.line_count(tf) - 1 do
      vim = push_undo(vim, tf)
      current = Readable.line_at(tf, line) || ""
      next = Readable.line_at(tf, line + 1) || ""
      joined = String.trim_trailing(current) <> " " <> String.trim_leading(next)
      new_lines = List.replace_at(tf.lines, line, joined) |> List.delete_at(line + 1)
      join_col = String.length(String.trim_trailing(current))
      new_tf = %{tf | lines: new_lines, cursor: {line, join_col}}
      {:handled, %{vim | count: 0}, new_tf}
    else
      {:handled, %{vim | count: 0}, tf}
    end
  end

  # ── Paste ────────────────────────────────────────────────────────────────

  @spec paste(t(), TextField.t(), :after | :before) :: {:handled, t(), TextField.t()}
  defp paste(%{register: ""} = vim, tf, _), do: {:handled, %{vim | count: 0}, tf}

  defp paste(vim, tf, position) do
    vim = push_undo(vim, tf)
    text = vim.register

    new_tf =
      case position do
        :after -> TextField.move_right(tf) |> TextField.insert_text(text)
        :before -> TextField.insert_text(tf, text)
      end

    {:handled, %{vim | count: 0}, new_tf}
  end

  # ── Undo / Redo ──────────────────────────────────────────────────────────

  @spec undo(t(), TextField.t()) :: {:handled, t(), TextField.t()}
  defp undo(%{undo_stack: []} = vim, tf), do: {:handled, %{vim | count: 0}, tf}

  defp undo(%{undo_stack: [prev | rest]} = vim, tf) do
    {:handled,
     %{vim | undo_stack: rest, redo_stack: [tf | vim.redo_stack], count: 0, state: :normal}, prev}
  end

  @spec redo(t(), TextField.t()) :: {:handled, t(), TextField.t()}
  defp redo(%{redo_stack: []} = vim, tf), do: {:handled, %{vim | count: 0}, tf}

  defp redo(%{redo_stack: [next | rest]} = vim, tf) do
    {:handled,
     %{vim | redo_stack: rest, undo_stack: [tf | vim.undo_stack], count: 0, state: :normal}, next}
  end

  # ── Mode transitions ────────────────────────────────────────────────────

  @spec to_insert(t(), TextField.t()) :: {:handled, t(), TextField.t()}
  defp to_insert(vim, tf), do: {:handled, enter_insert(vim), tf}

  @spec open_line(t(), TextField.t(), :above | :below) :: {:handled, t(), TextField.t()}
  defp open_line(vim, tf, :below) do
    vim = push_undo(vim, tf)
    new_tf = tf |> TextField.move_end() |> TextField.insert_newline()
    {:handled, enter_insert(vim), new_tf}
  end

  defp open_line(vim, tf, :above) do
    vim = push_undo(vim, tf)
    {line, _} = tf.cursor

    new_tf =
      if line == 0 do
        tf
        |> TextField.move_home()
        |> TextField.insert_newline()
        |> TextField.set_cursor({0, 0})
      else
        # Move to end of previous line, insert newline
        prev_len = String.length(Readable.line_at(tf, line - 1) || "")
        tf |> TextField.set_cursor({line - 1, prev_len}) |> TextField.insert_newline()
      end

    {:handled, enter_insert(vim), new_tf}
  end

  # ── Find-char helpers ───────────────────────────────────────────────────

  @spec apply_find_n(
          TextField.t(),
          TextField.cursor(),
          :f | :F | :t | :T,
          String.t(),
          pos_integer()
        ) ::
          TextField.cursor()
  defp apply_find_n(tf, cursor, type, char, count) do
    find_fn = find_function(type)
    do_find_n(tf, cursor, find_fn, char, count)
  end

  @spec do_find_n(
          TextField.t(),
          TextField.cursor(),
          (TextField.t(), TextField.cursor(), String.t() -> TextField.cursor()),
          String.t(),
          non_neg_integer()
        ) ::
          TextField.cursor()
  defp do_find_n(_tf, pos, _fun, _char, 0), do: pos

  defp do_find_n(tf, pos, fun, char, n) do
    new_pos = fun.(tf, pos, char)
    if new_pos == pos, do: pos, else: do_find_n(tf, new_pos, fun, char, n - 1)
  end

  @spec find_function(:f | :F | :t | :T) :: (TextField.t(), TextField.cursor(), String.t() ->
                                               TextField.cursor())
  defp find_function(:f), do: &Motion.find_char_forward/3
  defp find_function(:F), do: &Motion.find_char_backward/3
  defp find_function(:t), do: &Motion.till_char_forward/3
  defp find_function(:T), do: &Motion.till_char_backward/3

  # ── Count helpers ───────────────────────────────────────────────────────

  @spec counting?(t(), non_neg_integer()) :: boolean()
  defp counting?(vim, cp) do
    (cp >= ?1 and cp <= ?9) or (cp == ?0 and vim.count > 0)
  end

  @spec accumulate_count(t(), non_neg_integer()) :: t()
  defp accumulate_count(vim, digit), do: %{vim | count: vim.count * 10 + digit}

  @spec effective_count(t()) :: pos_integer()
  defp effective_count(%{count: 0}), do: 1
  defp effective_count(%{count: n}), do: n

  # ── Undo stack ──────────────────────────────────────────────────────────

  @spec push_undo(t(), TextField.t()) :: t()
  defp push_undo(vim, tf) do
    stack = [tf | vim.undo_stack] |> Enum.take(@max_undo)
    %{vim | undo_stack: stack, redo_stack: []}
  end

  # ── Cursor clamping ─────────────────────────────────────────────────────

  @spec clamp_cursor_normal(TextField.t()) :: TextField.t()
  defp clamp_cursor_normal(tf) do
    {line, col} = tf.cursor
    line_len = String.length(Readable.line_at(tf, line) || "")
    max_col = max(line_len - 1, 0)

    if col > max_col do
      TextField.set_cursor(tf, {line, max_col})
    else
      tf
    end
  end

  @spec clamp_normal(TextField.t(), TextField.cursor()) :: TextField.cursor()
  defp clamp_normal(tf, {line, col}) do
    line_len = String.length(Readable.line_at(tf, line) || "")
    max_col = max(line_len - 1, 0)
    {line, min(col, max_col)}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  @spec sort_positions(TextField.cursor(), TextField.cursor()) ::
          {TextField.cursor(), TextField.cursor()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if l1 < l2 or (l1 == l2 and c1 <= c2), do: {p1, p2}, else: {p2, p1}
  end

  @spec operator_codepoint(operator()) :: non_neg_integer()
  defp operator_codepoint(:delete), do: ?d
  defp operator_codepoint(:change), do: ?c
  defp operator_codepoint(:yank), do: ?y
end
