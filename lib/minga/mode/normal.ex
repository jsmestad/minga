defmodule Minga.Mode.Normal do
  @moduledoc """
  Vim Normal mode key handler.

  In Normal mode, keys are interpreted as commands — motions, operators, or
  keys that enter other modes. Digit keys `1`–`9` (and `0` after a count has
  started) accumulate a repeat count stored in the FSM state. The accumulated
  count is applied by the `Minga.Mode` dispatcher when an `:execute` result
  is returned.

  ## Leader key sequences

  Pressing **SPC** (space) enters leader mode. Subsequent keys are looked up in
  the `Minga.Keymap.Defaults` leader trie:

  * **Prefix match** — continue accumulating (`SPC f` waits for `f`, `s`, …).
    The editor starts (or resets) a 300 ms which-key timer. When the timer fires
    the editor shows a popup with the available continuations.
  * **Command match** — the bound command is executed and leader mode ends.
  * **No match** — leader mode is cancelled.

  The FSM state carries `:leader_node` (current trie node, `nil` when not in
  leader mode) and `:leader_keys` (list of formatted key strings accumulated so
  far, for status-bar display).

  ## Supported keys

  | Key      | Action                                 |
  |----------|----------------------------------------|
  | `SPC`    | Enter leader key mode                  |
  | `i`      | Transition to Insert mode              |
  | `a`      | Move right, transition to Insert       |
  | `A`      | Move to line end, transition to Insert |
  | `I`      | Move to line start, transition to Insert |
  | `o`      | Insert line below, transition to Insert |
  | `O`      | Insert line above, transition to Insert |
  | `h`      | Move left                              |
  | `j`      | Move down                              |
  | `k`      | Move up                                |
  | `l`      | Move right                             |
  | `0`      | Move to line start (when no count) or continue count |
  | `1`–`9`  | Accumulate count prefix                |
  | `d`      | Enter operator-pending (delete)        |
  | `c`      | Enter operator-pending (change)        |
  | `y`      | Enter operator-pending (yank)          |
  | `p`      | Paste after cursor                     |
  | `P`      | Paste before cursor                    |
  | `w`      | Word forward                           |
  | `b`      | Word backward                          |
  | `e`      | Word end                               |
  | `$`      | Line end                               |
  | `^`      | First non-blank                        |
  | `G`      | Document end                           |
  | `Escape` | Clear count prefix / cancel leader     |
  | `Ctrl+d`  | Half-page down                       |
  | `Ctrl+u`  | Half-page up                         |
  | `Ctrl+f`  | Full page down                       |
  | `Ctrl+b`  | Full page up                         |
  | Arrow keys | Move in corresponding direction     |
  """

  @behaviour Minga.Mode

  import Bitwise

  alias Minga.Keymap.Defaults
  alias Minga.Keymap.Trie
  alias Minga.Mode
  alias Minga.Mode.State, as: ModeState
  alias Minga.WhichKey

  # Special codepoints
  @escape 27
  @space 32

  # Modifier flags (mirrors Minga.Port.Protocol)
  @ctrl 0x02

  # Arrow key codepoints sent by libvaxis
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  @impl Mode
  @doc """
  Handles a key event in Normal mode.

  Returns a `t:Minga.Mode.result/0` indicating the FSM transition and
  any commands to execute.
  """
  @spec handle_key(Mode.key(), Mode.state()) :: Mode.result()

  # ── Leader key handling ───────────────────────────────────────────────────

  # SPC pressed while not in leader mode → start leader sequence.
  def handle_key({@space, 0}, %ModeState{leader_node: nil} = state) do
    leader_trie = Defaults.leader_trie()
    new_state = %{state | leader_node: leader_trie, leader_keys: ["SPC"]}
    {:execute, {:leader_start, leader_trie}, new_state}
  end

  # SPC pressed while already in leader mode → cancel and restart.
  def handle_key({@space, 0}, %ModeState{leader_node: _node} = state) do
    leader_trie = Defaults.leader_trie()
    new_state = %{state | leader_node: leader_trie, leader_keys: ["SPC"]}
    {:execute, [:leader_cancel, {:leader_start, leader_trie}], new_state}
  end

  # Any other key while in leader mode → walk the trie.
  def handle_key(key, %ModeState{leader_node: node} = state) when is_map(node) do
    case Trie.lookup(node, key) do
      :not_found ->
        new_state = %{state | leader_node: nil, leader_keys: []}
        {:execute, :leader_cancel, new_state}

      {:prefix, sub_node} ->
        formatted = WhichKey.format_key(key)
        new_keys = [formatted | state.leader_keys]
        new_state = %{state | leader_node: sub_node, leader_keys: new_keys}
        {:execute, {:leader_progress, sub_node}, new_state}

      {:command, command} ->
        new_state = %{state | leader_node: nil, leader_keys: []}
        {:execute, [command, :leader_cancel], new_state}
    end
  end

  # ── Pending completions ────────────────────────────────────────────────────
  # Placed FIRST (before count prefix and all other handlers) so that any
  # pending multi-key sequence takes priority regardless of which codepoint
  # the user presses next — including 0, digits, or normal motion keys.

  # Complete register selection: " + valid register char
  # Valid: a-z, A-Z, 0, +, _, " (unnamed)
  def handle_key({char, 0}, %ModeState{pending_register: true} = state)
      when char in ?a..?z or char in ?A..?Z or char == ?0 or
             char == ?+ or char == ?_ or char == ?" do
    {:execute, {:select_register, <<char::utf8>>}, %{state | pending_register: false}}
  end

  # Cancel register selection on any other key
  def handle_key(_key, %ModeState{pending_register: true} = state) do
    {:continue, %{state | pending_register: false}}
  end

  # Complete set-mark: m + {a-z}
  def handle_key({char, 0}, %ModeState{pending_mark: :set} = state)
      when char in ?a..?z do
    {:execute, {:set_mark, <<char::utf8>>}, %{state | pending_mark: nil}}
  end

  # Complete jump-to-mark-line: ' + {a-z}
  def handle_key({char, 0}, %ModeState{pending_mark: :jump_line} = state)
      when char in ?a..?z do
    {:execute, {:jump_to_mark_line, <<char::utf8>>}, %{state | pending_mark: nil}}
  end

  # '' → jump to last jump position (line, first non-blank)
  def handle_key({?', 0}, %ModeState{pending_mark: :jump_line} = state) do
    {:execute, :jump_to_last_pos_line, %{state | pending_mark: nil}}
  end

  # Complete jump-to-mark-exact: ` + {a-z}
  def handle_key({char, 0}, %ModeState{pending_mark: :jump_exact} = state)
      when char in ?a..?z do
    {:execute, {:jump_to_mark_exact, <<char::utf8>>}, %{state | pending_mark: nil}}
  end

  # `` → jump to last jump position (exact position)
  def handle_key({?`, 0}, %ModeState{pending_mark: :jump_exact} = state) do
    {:execute, :jump_to_last_pos_exact, %{state | pending_mark: nil}}
  end

  # Cancel pending mark on any other key
  def handle_key(_key, %ModeState{pending_mark: kind} = state) when kind != nil do
    {:continue, %{state | pending_mark: nil}}
  end

  # Complete macro register selection: q + {a-z} → start recording
  def handle_key({char, 0}, %ModeState{pending_macro_register: true} = state)
      when char in ?a..?z do
    {:execute, {:start_macro_recording, <<char::utf8>>}, %{state | pending_macro_register: false}}
  end

  # Cancel macro register selection on any other key
  def handle_key(_key, %ModeState{pending_macro_register: true} = state) do
    {:continue, %{state | pending_macro_register: false}}
  end

  # Complete macro replay: @ + {a-z} → replay macro
  def handle_key({char, 0}, %ModeState{pending_macro_replay: true} = state)
      when char in ?a..?z do
    {:execute, {:replay_macro, <<char::utf8>>}, %{state | pending_macro_replay: false}}
  end

  # @@ → replay last macro
  def handle_key({?@, 0}, %ModeState{pending_macro_replay: true} = state) do
    {:execute, :replay_last_macro, %{state | pending_macro_replay: false}}
  end

  # Cancel macro replay selection on any other key
  def handle_key(_key, %ModeState{pending_macro_replay: true} = state) do
    {:continue, %{state | pending_macro_replay: false}}
  end

  # ── Count prefix accumulation ─────────────────────────────────────────────

  # Digits 1-9 always start or extend the count.
  def handle_key({digit, 0}, %ModeState{count: count} = state)
      when digit in ?1..?9 do
    digit_value = digit - ?0
    new_count = if count, do: count * 10 + digit_value, else: digit_value
    {:continue, %{state | count: new_count}}
  end

  # `0` continues an in-progress count; otherwise it's the "go to line start" motion.
  def handle_key({?0, 0}, %ModeState{count: count} = state) when is_integer(count) do
    {:continue, %{state | count: count * 10}}
  end

  def handle_key({?0, 0}, state) do
    {:execute, :move_to_line_start, state}
  end

  # ── Mode transitions ──────────────────────────────────────────────────────

  def handle_key({?i, 0}, state) do
    {:transition, :insert, state}
  end

  def handle_key({?a, 0}, state) do
    {:execute_then_transition, [:move_right], :insert, state}
  end

  def handle_key({?A, 0}, state) do
    {:execute_then_transition, [:move_to_line_end], :insert, state}
  end

  def handle_key({?I, 0}, state) do
    {:execute_then_transition, [:move_to_line_start], :insert, state}
  end

  def handle_key({?o, 0}, state) do
    {:execute_then_transition, [:insert_line_below], :insert, state}
  end

  def handle_key({?O, 0}, state) do
    {:execute_then_transition, [:insert_line_above], :insert, state}
  end

  # ── Movements ─────────────────────────────────────────────────────────────

  def handle_key({?h, 0}, state) do
    {:execute, :move_left, state}
  end

  def handle_key({?j, 0}, state) do
    {:execute, :move_down, state}
  end

  def handle_key({?k, 0}, state) do
    {:execute, :move_up, state}
  end

  def handle_key({?l, 0}, state) do
    {:execute, :move_right, state}
  end

  # Arrow keys
  def handle_key({@arrow_up, _mods}, state) do
    {:execute, :move_up, state}
  end

  def handle_key({@arrow_down, _mods}, state) do
    {:execute, :move_down, state}
  end

  def handle_key({@arrow_left, _mods}, state) do
    {:execute, :move_left, state}
  end

  def handle_key({@arrow_right, _mods}, state) do
    {:execute, :move_right, state}
  end

  # ── Visual mode entry ─────────────────────────────────────────────────────

  # v → characterwise visual mode.
  # The editor injects the :visual_anchor after the transition.
  def handle_key({?v, 0}, %ModeState{} = state) do
    {:transition, :visual, %Minga.Mode.VisualState{count: state.count, visual_type: :char}}
  end

  # V → linewise visual mode.
  def handle_key({?V, 0}, %ModeState{} = state) do
    {:transition, :visual, %Minga.Mode.VisualState{count: state.count, visual_type: :line}}
  end

  # ── Word / line motions ───────────────────────────────────────────────────

  def handle_key({?w, 0}, state) do
    {:execute, :word_forward, state}
  end

  def handle_key({?b, 0}, state) do
    {:execute, :word_backward, state}
  end

  def handle_key({?e, 0}, state) do
    {:execute, :word_end, state}
  end

  def handle_key({?$, 0}, state) do
    {:execute, :move_to_line_end, state}
  end

  def handle_key({?^, 0}, state) do
    {:execute, :move_to_first_non_blank, state}
  end

  def handle_key({?G, 0}, %ModeState{count: nil} = state) do
    {:execute, :move_to_document_end, state}
  end

  # G with count → go to line N
  def handle_key({?G, 0}, %ModeState{count: count} = state) when is_integer(count) do
    {:execute, {:goto_line, count}, %{state | count: nil}}
  end

  # g prefix — wait for second key
  def handle_key({?g, 0}, %ModeState{pending_g: false} = state) do
    {:continue, %{state | pending_g: true}}
  end

  # gg — document start
  def handle_key({?g, 0}, %ModeState{pending_g: true} = state) do
    {:execute, :move_to_document_start, %{state | pending_g: false}}
  end

  # ── Find-char motions (f/F/t/T) ──────────────────────────────────────────

  def handle_key({?f, 0}, state) do
    {:continue, %{state | pending_find: :f}}
  end

  def handle_key({?F, 0}, state) do
    {:continue, %{state | pending_find: :F}}
  end

  def handle_key({?t, 0}, state) do
    {:continue, %{state | pending_find: :t}}
  end

  def handle_key({?T, 0}, state) do
    {:continue, %{state | pending_find: :T}}
  end

  # Complete the find-char motion with the target character
  def handle_key({codepoint, 0}, %ModeState{pending_find: dir} = state)
      when dir in [:f, :F, :t, :T] and codepoint >= 32 do
    char = <<codepoint::utf8>>
    {:execute, {:find_char, dir, char}, %{state | pending_find: nil}}
  end

  # ── Repeat find-char (;  ,) ─────────────────────────────────────────────

  def handle_key({?;, 0}, state) do
    {:execute, :repeat_find_char, state}
  end

  def handle_key({?,, 0}, state) do
    {:execute, :repeat_find_char_reverse, state}
  end

  # ── Bracket matching (%) ─────────────────────────────────────────────────

  def handle_key({?%, 0}, state) do
    {:execute, :match_bracket, state}
  end

  # ── Paragraph motions ({ / }) ────────────────────────────────────────────

  def handle_key({?{, 0}, state) do
    {:execute, :paragraph_backward, state}
  end

  def handle_key({?}, 0}, state) do
    {:execute, :paragraph_forward, state}
  end

  # ── Screen-relative motions (H / M / L) ─────────────────────────────────

  def handle_key({?H, 0}, state) do
    {:execute, {:move_to_screen, :top}, state}
  end

  def handle_key({?M, 0}, state) do
    {:execute, {:move_to_screen, :middle}, state}
  end

  def handle_key({?L, 0}, state) do
    {:execute, {:move_to_screen, :bottom}, state}
  end

  # ── WORD motions (W / B / E) ─────────────────────────────────────────────

  def handle_key({?W, 0}, state) do
    {:execute, :word_forward_big, state}
  end

  def handle_key({?B, 0}, state) do
    {:execute, :word_backward_big, state}
  end

  def handle_key({?E, 0}, state) do
    {:execute, :word_end_big, state}
  end

  # ── Operator entry (d / c / y) ────────────────────────────────────────────

  def handle_key({?d, 0}, %ModeState{count: count} = _state) do
    {:transition, :operator_pending,
     %Minga.Mode.OperatorPendingState{operator: :delete, op_count: count || 1}}
  end

  def handle_key({?c, 0}, %ModeState{count: count} = _state) do
    {:transition, :operator_pending,
     %Minga.Mode.OperatorPendingState{operator: :change, op_count: count || 1}}
  end

  def handle_key({?y, 0}, %ModeState{count: count} = _state) do
    {:transition, :operator_pending,
     %Minga.Mode.OperatorPendingState{operator: :yank, op_count: count || 1}}
  end

  # ── Paste ─────────────────────────────────────────────────────────────────

  def handle_key({?p, 0}, state) do
    {:execute, :paste_after, state}
  end

  def handle_key({?P, 0}, state) do
    {:execute, :paste_before, state}
  end

  # ── Page / half-page scrolling ──────────────────────────────────────────────

  # Ctrl+D → half-page down
  def handle_key({?d, mods}, state) when band(mods, @ctrl) != 0 do
    {:execute, :half_page_down, state}
  end

  # Ctrl+U → half-page up
  def handle_key({?u, mods}, state) when band(mods, @ctrl) != 0 do
    {:execute, :half_page_up, state}
  end

  # Ctrl+F → full page down
  def handle_key({?f, mods}, state) when band(mods, @ctrl) != 0 do
    {:execute, :page_down, state}
  end

  # Ctrl+B → full page up
  def handle_key({?b, mods}, state) when band(mods, @ctrl) != 0 do
    {:execute, :page_up, state}
  end

  # ── Single-key editing commands ────────────────────────────────────────────

  # r — replace char (wait for next char)
  def handle_key({?r, 0}, %ModeState{pending_replace: false} = state) do
    {:continue, %{state | pending_replace: true}}
  end

  # Complete replace with the target character.
  # MUST come before x/X/J/etc. so those codepoints are correctly captured
  # as the replacement target when pending_replace is true.
  def handle_key({codepoint, 0}, %ModeState{pending_replace: true} = state)
      when codepoint >= 32 do
    char = <<codepoint::utf8>>
    {:execute, {:replace_char, char}, %{state | pending_replace: false}}
  end

  # x — delete char at cursor
  def handle_key({?x, 0}, state) do
    {:execute, :delete_at, state}
  end

  # X — delete char before cursor
  def handle_key({?X, 0}, state) do
    {:execute, :delete_before, state}
  end

  # J — join current line with next
  def handle_key({?J, 0}, state) do
    {:execute, :join_lines, state}
  end

  # ~ — toggle case
  def handle_key({?~, 0}, state) do
    {:execute, :toggle_case, state}
  end

  # s — delete char at cursor, enter Insert mode (substitute char)
  def handle_key({?s, 0}, state) do
    {:execute_then_transition, [:delete_at], :insert, state}
  end

  # S — clear line and enter Insert mode (substitute line)
  def handle_key({?S, 0}, state) do
    {:execute_then_transition, [:change_line], :insert, state}
  end

  # C — delete from cursor to end of line, enter Insert mode (change to EOL)
  def handle_key({?C, 0}, state) do
    {:execute_then_transition, [{:delete_motion, :line_end}], :insert, state}
  end

  # D — delete from cursor to end of line, stay in Normal mode
  def handle_key({?D, 0}, state) do
    {:execute, {:delete_motion, :line_end}, state}
  end

  # R — enter Replace mode
  def handle_key({?R, 0}, _state) do
    {:transition, :replace, %Minga.Mode.ReplaceState{}}
  end

  # > — enter operator-pending for indent
  def handle_key({?>, 0}, %ModeState{count: count} = _state) do
    {:transition, :operator_pending,
     %Minga.Mode.OperatorPendingState{operator: :indent, op_count: count || 1}}
  end

  # < — enter operator-pending for dedent
  def handle_key({?<, 0}, %ModeState{count: count} = _state) do
    {:transition, :operator_pending,
     %Minga.Mode.OperatorPendingState{operator: :dedent, op_count: count || 1}}
  end

  # + — next line first non-blank
  def handle_key({?+, 0}, state) do
    {:execute, :next_line_first_non_blank, state}
  end

  # - — prev line first non-blank
  def handle_key({?-, 0}, state) do
    {:execute, :prev_line_first_non_blank, state}
  end

  # ── Macro recording / replay ─────────────────────────────────────────────

  # q — toggle macro recording or start register selection
  # Note: this is only reached when NOT in pending_macro_register (handled above)
  def handle_key({?q, 0}, state) do
    # If currently recording, this is handled at the editor level via
    # :stop_macro_recording. We emit it as a command.
    {:execute, :toggle_macro_recording, %{state | pending_macro_register: false}}
  end

  # @ — start macro replay register selection
  def handle_key({?@, 0}, state) do
    {:continue, %{state | pending_macro_replay: true}}
  end

  # ── Dot repeat ──────────────────────────────────────────────────────────

  # Dot repeat carries its own count — pass it as a parameter rather than
  # letting the dispatcher multiply the command via List.duplicate.
  def handle_key({?., 0}, %ModeState{count: count} = state) do
    {:execute, {:dot_repeat, count}, %{state | count: nil}}
  end

  # ── Undo / redo ───────────────────────────────────────────────────────────

  def handle_key({?u, 0}, state) do
    {:execute, :undo, state}
  end

  def handle_key({?r, mods}, state) when band(mods, @ctrl) != 0 do
    {:execute, :redo, state}
  end

  # ── Register prefix ───────────────────────────────────────────────────────

  # " → start register-selection sequence (completion is in the pending block above)
  def handle_key({?", 0}, state) do
    {:continue, %{state | pending_register: true}}
  end

  # ── Marks: starters ───────────────────────────────────────────────────────
  # Completions are near the top (after count prefix) to take priority over
  # regular motion/mode-transition bindings.

  # m → start set-mark sequence
  def handle_key({?m, 0}, state) do
    {:continue, %{state | pending_mark: :set}}
  end

  # ' → start jump-to-mark-line sequence
  def handle_key({?', 0}, state) do
    {:continue, %{state | pending_mark: :jump_line}}
  end

  # ` → start jump-to-mark-exact sequence
  def handle_key({?`, 0}, state) do
    {:continue, %{state | pending_mark: :jump_exact}}
  end

  # ── Escape: already in Normal, clear count and cancel any leader sequence ──

  def handle_key({@escape, _mods}, %ModeState{leader_node: node} = state)
      when is_map(node) do
    new_state = %{state | leader_node: nil, leader_keys: [], count: nil}
    {:execute, :leader_cancel, new_state}
  end

  def handle_key({@escape, _mods}, %ModeState{} = state) do
    {:continue, %{state | count: nil}}
  end

  # ── Search ──────────────────────────────────────────────────────────────────

  # / → enter search mode (forward)
  def handle_key({?/, 0}, _state) do
    {:transition, :search, %Minga.Mode.SearchState{direction: :forward}}
  end

  # ? → enter search mode (backward)
  def handle_key({??, 0}, _state) do
    {:transition, :search, %Minga.Mode.SearchState{direction: :backward}}
  end

  # n → search next
  def handle_key({?n, 0}, state) do
    {:execute, :search_next, state}
  end

  # N → search prev
  def handle_key({?N, 0}, state) do
    {:execute, :search_prev, state}
  end

  # * → search word under cursor forward
  def handle_key({?*, 0}, state) do
    {:execute, :search_word_under_cursor_forward, state}
  end

  # # → search word under cursor backward
  def handle_key({?#, 0}, state) do
    {:execute, :search_word_under_cursor_backward, state}
  end

  # ── Command mode entry ────────────────────────────────────────────────────

  # `:` → enter command-line mode.
  def handle_key({?:, 0}, state) do
    {:transition, :command, state}
  end

  # ── Unknown key: no-op ───────────────────────────────────────────────────

  def handle_key(_key, state) do
    {:continue, state}
  end
end
