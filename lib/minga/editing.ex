defmodule Minga.Editing do
  @moduledoc """
  Editing domain facade.

  Cursor motions, text operations, search, bracket matching, comment
  toggling, formatting, and scroll state. This module is the only
  valid entry point from outside the domain.

  External callers use this facade for behavior. Struct types
  (`Minga.Editing.Completion.t()`, `Minga.Editing.Search.Match.t()`,
  `Minga.Editing.Scroll.t()`) may be referenced directly in `@spec`
  annotations per AGENTS.md type-crossing rules. Protocols
  (`Minga.Editing.Text.Readable`) and behaviours
  (`Minga.Editing.Model`) are also part of the public API.
  """

  # ── Cursor motions ─────────────────────────────────────────────────────
  # Each motion takes a readable (Document or BufferSnapshot) and a
  # cursor position, returns the new position.

  defdelegate line_start(readable, pos), to: Minga.Editing.Motion
  defdelegate line_end(readable, pos), to: Minga.Editing.Motion
  defdelegate first_non_blank(readable, pos), to: Minga.Editing.Motion
  defdelegate word_forward(readable, pos), to: Minga.Editing.Motion
  defdelegate word_backward(readable, pos), to: Minga.Editing.Motion
  defdelegate word_end(readable, pos), to: Minga.Editing.Motion
  defdelegate word_forward_big(readable, pos), to: Minga.Editing.Motion
  defdelegate word_backward_big(readable, pos), to: Minga.Editing.Motion
  defdelegate word_end_big(readable, pos), to: Minga.Editing.Motion
  defdelegate document_start(readable), to: Minga.Editing.Motion
  defdelegate document_end(readable), to: Minga.Editing.Motion
  defdelegate match_bracket(readable, pos), to: Minga.Editing.Motion
  defdelegate paragraph_forward(readable, pos), to: Minga.Editing.Motion
  defdelegate paragraph_backward(readable, pos), to: Minga.Editing.Motion
  defdelegate find_char_forward(readable, pos, char), to: Minga.Editing.Motion
  defdelegate find_char_backward(readable, pos, char), to: Minga.Editing.Motion
  defdelegate till_char_forward(readable, pos, char), to: Minga.Editing.Motion
  defdelegate till_char_backward(readable, pos, char), to: Minga.Editing.Motion

  # ── Text operations (operators) ────────────────────────────────────────

  defdelegate delete(buf, start_pos, end_pos), to: Minga.Editing.Operator
  defdelegate change(buf, start_pos, end_pos), to: Minga.Editing.Operator
  defdelegate yank(buf, start_pos, end_pos), to: Minga.Editing.Operator

  # ── Visual line motions ──────────────────────────────────────────────

  defdelegate visual_line_down(doc, pos, content_w),
    to: Minga.Editing.Motion.VisualLine,
    as: :visual_down

  defdelegate visual_line_up(doc, pos, content_w),
    to: Minga.Editing.Motion.VisualLine,
    as: :visual_up

  defdelegate visual_line_start(doc, pos, content_w), to: Minga.Editing.Motion.VisualLine
  defdelegate visual_line_end(doc, pos, content_w), to: Minga.Editing.Motion.VisualLine

  # ── Text objects ───────────────────────────────────────────────────────

  defdelegate select_inner_word(readable, pos), to: Minga.Editing.TextObject, as: :inner_word
  defdelegate select_around_word(readable, pos), to: Minga.Editing.TextObject, as: :a_word

  defdelegate select_inner_quotes(readable, pos, quote_char),
    to: Minga.Editing.TextObject,
    as: :inner_quotes

  defdelegate select_around_quotes(readable, pos, quote_char),
    to: Minga.Editing.TextObject,
    as: :a_quotes

  defdelegate select_inner_parens(readable, pos, open, close),
    to: Minga.Editing.TextObject,
    as: :inner_parens

  defdelegate select_around_parens(readable, pos, open, close),
    to: Minga.Editing.TextObject,
    as: :a_parens

  defdelegate select_structural_inner(tree_data),
    to: Minga.Editing.TextObject,
    as: :structural_inner

  defdelegate select_structural_around(tree_data),
    to: Minga.Editing.TextObject,
    as: :structural_around

  # ── Bracket matching ───────────────────────────────────────────────────

  @doc "Insert a character, auto-inserting the matching bracket when appropriate."
  defdelegate insert_with_pairs(buf, pos, char), to: Minga.Editing.AutoPair, as: :on_insert

  @doc "Backspace, removing the matching bracket when the cursor is between a pair."
  defdelegate backspace_with_pairs(buf, pos), to: Minga.Editing.AutoPair, as: :on_backspace

  # ── Comment toggling ───────────────────────────────────────────────────

  @doc "Compute comment toggle edits for the given lines (pure, no Buffer I/O)."
  defdelegate compute_comment_edits(lines, prefix, start_line),
    to: Minga.Editing.Comment,
    as: :compute_toggle_edits

  @doc "Resolve comment prefix with nil fallback."
  defdelegate comment_prefix(token), to: Minga.Editing.Comment

  @doc "Resolve comment prefix accounting for injection ranges."
  defdelegate comment_prefix_at(default_token, byte_offset, injection_ranges, token_for_lang),
    to: Minga.Editing.Comment

  # ── Search ─────────────────────────────────────────────────────────────

  @doc "Find the next match for a pattern starting from a position."
  defdelegate search_next(readable, pattern, pos, direction),
    to: Minga.Editing.Search,
    as: :find_next

  @doc "Find all matches for a pattern within a line range."
  defdelegate search_all_in_range(readable, pattern, range),
    to: Minga.Editing.Search,
    as: :find_all_in_range

  @doc "Returns the word under the cursor, or nil."
  defdelegate word_under_cursor(readable, pos),
    to: Minga.Editing.Search,
    as: :word_at_cursor

  @doc "Substitute matches in a single line, returning styled spans for preview."
  defdelegate substitute_line_preview(readable, pattern, replacement, line),
    to: Minga.Editing.Search,
    as: :substitute_line_with_spans

  @doc "Substitute all matches in buffer content."
  defdelegate substitute(content, pattern, replacement, global?),
    to: Minga.Editing.Search

  # ── Scroll state ───────────────────────────────────────────────────────

  @doc "Creates a new scroll state with default values."
  defdelegate new_scroll(), to: Minga.Editing.Scroll, as: :new

  @doc "Resolve a scroll target given total content lines and visible height."
  defdelegate resolve_scroll(scroll, total_lines, visible_height),
    to: Minga.Editing.Scroll,
    as: :resolve

  @doc "Scroll up by the given number of lines."
  defdelegate scroll_up(scroll, amount), to: Minga.Editing.Scroll

  @doc "Scroll down by the given number of lines."
  defdelegate scroll_down(scroll, amount), to: Minga.Editing.Scroll

  @doc "Pin scroll to the bottom of content."
  defdelegate pin_to_bottom(scroll), to: Minga.Editing.Scroll

  @doc "Scroll to the top of content."
  defdelegate scroll_to_top(scroll), to: Minga.Editing.Scroll

  @doc "Set the scroll offset directly."
  defdelegate set_scroll_offset(scroll, offset), to: Minga.Editing.Scroll, as: :set_offset

  # ── Formatting ─────────────────────────────────────────────────────────

  @doc "Resolve the formatter spec for a filetype and file path."
  defdelegate resolve_formatter(filetype, file_path), to: Minga.Editing.Formatter

  @doc "Format content using a formatter command string."
  defdelegate format(content, command_string), to: Minga.Editing.Formatter

  @doc "Apply save-time transforms (trim trailing whitespace, final newline)."
  defdelegate apply_save_transforms(content, trim, final_newline), to: Minga.Editing.Formatter

  # ── Editing model queries ────────────────────────────────────────────────
  # Model-agnostic queries about the editing state. These dispatch through
  # the active editing model (Vim or CUA) and work identically regardless
  # of which model is active. External code uses these to ask "what is the
  # user doing?" without knowing about vim modes or CUA selection state.

  alias Minga.Editing.Model.CUA, as: CUAModel
  alias Minga.Editing.Model.Vim, as: VimModel

  @doc "Returns the active editing model module from editor state."
  @spec active_model(map()) :: module()
  def active_model(%{editing_model: :cua}), do: CUAModel
  def active_model(%{editing_model: :vim}), do: VimModel
  def active_model(_state), do: VimModel

  @doc "Returns the active editing model module from global config. Prefer active_model/1 when state is available."
  @spec active_model() :: module()
  def active_model do
    case Minga.Config.get(:editing_model) do
      :vim -> VimModel
      :cua -> CUAModel
    end
  catch
    :exit, _ -> VimModel
  end

  @doc "Is the user currently inserting text?"
  @spec inserting?(map()) :: boolean()
  def inserting?(state), do: active_model(state).inserting?(model_state(state))

  @doc "Does the user have an active selection?"
  @spec selecting?(map()) :: boolean()
  def selecting?(state), do: active_model(state).selecting?(model_state(state))

  @doc "What cursor shape should the frontend render?"
  @spec cursor_shape(map()) :: :beam | :block | :underline
  def cursor_shape(state), do: active_model(state).cursor_shape(model_state(state))

  @doc "Is a multi-key sequence in progress (leader key, operator-pending, etc.)?"
  @spec key_sequence_pending?(map()) :: boolean()
  def key_sequence_pending?(state),
    do: active_model(state).key_sequence_pending?(model_state(state))

  @doc "Short mode label for the status bar (e.g., 'NORMAL', 'INSERT', '')."
  @spec status_segment(map()) :: String.t()
  def status_segment(state), do: active_model(state).status_segment(model_state(state))

  @doc "Current editing mode atom (e.g., :normal, :insert, :visual, :cua)."
  @spec mode(map()) :: atom()
  def mode(%{workspace: %{editing: vim}}), do: vim.mode

  @doc """
  Returns the keymap binding state for scope trie resolution.

  This is the discriminator that `Scope.resolve_key/3` uses to select
  which trie of bindings to look up. CUA always returns `:cua`. Vim
  returns the current mode mapped to the scope-relevant subset
  (`:normal`, `:insert`, `:input_normal`).

  Use this instead of manually checking `cua_active?` and branching
  on the editing model in input handlers.
  """
  @spec binding_state(map()) :: atom()
  def binding_state(state) do
    case active_model(state) do
      CUAModel -> :cua
      VimModel -> state.workspace.editing.mode
    end
  end

  @doc "Is a leader key sequence in progress?"
  @spec in_leader?(map()) :: boolean()
  def in_leader?(%{workspace: %{editing: %{mode_state: ms}}}) when is_map_key(ms, :leader_node),
    do: is_map(ms.leader_node)

  def in_leader?(_state), do: false

  @doc "Is the editor in a minibuffer-occupying mode (command line, search, eval)?"
  @spec minibuffer_mode?(map()) :: boolean()
  def minibuffer_mode?(%{workspace: %{editing: vim}}),
    do: vim.mode in [:command, :search, :eval, :search_prompt]

  @doc "Is a macro currently being recorded? Returns {true, register} or false."
  @spec macro_recording_status(map()) :: {true, String.t()} | false
  def macro_recording_status(%{workspace: %{editing: vim}}) do
    MingaEditor.MacroRecorder.recording?(vim.macro_recorder)
  end

  # Builds a lightweight model state struct for behaviour dispatch.
  @spec model_state(map()) :: Minga.Editing.Model.state()
  defp model_state(state) do
    case active_model(state) do
      VimModel ->
        VimModel.from_editor(state.workspace.editing.mode, state.workspace.editing.mode_state)

      CUAModel ->
        CUAModel.from_editor()
    end
  end
end
