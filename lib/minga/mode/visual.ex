defmodule Minga.Mode.Visual do
  @moduledoc """
  Vim Visual mode key handler.

  Visual mode is entered from Normal mode via:

  * `v` — characterwise visual (selects individual characters)
  * `V` — linewise visual (selects whole lines)

  The selection spans from the **anchor** (cursor position when visual mode was
  entered, injected into the FSM state by `Minga.Editor`) to the **current
  cursor position** (the moving end). All standard motion keys move the cursor
  end, extending or shrinking the selection.

  ## Operators

  | Key      | Action                                          |
  |----------|-------------------------------------------------|
  | `d`      | Delete selection → Normal mode                  |
  | `c`      | Delete selection → Insert mode                  |
  | `y`      | Yank (copy) selection → Normal mode             |
  | `Escape` | Cancel selection → Normal mode                  |

  ## Motions (extend selection)

  | Key    | Motion          |
  |--------|-----------------|
  | `h`    | Move left       |
  | `j`    | Move down       |
  | `k`    | Move up         |
  | `l`    | Move right      |
  | `w`    | Word forward    |
  | `b`    | Word backward   |
  | `e`    | End of word     |
  | `C-d`  | Half-page down  |
  | `C-u`  | Half-page up    |
  | `C-f`  | Page down       |
  | `C-b`  | Page up         |
  | Arrows | Directional move|

  ## State contract

  Visual mode expects the following extra keys in the FSM state (set by the
  editor when transitioning *into* visual mode):

  * `:visual_anchor` — `t:Minga.Buffer.Document.position/0` — the fixed end
    of the selection.
  * `:visual_type` — `:char | :line` — selection granularity.
  """

  @behaviour Minga.Mode

  import Bitwise

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Mode
  alias Minga.Mode.VisualState

  # Special codepoints
  @escape 27

  # Modifier flags (mirrors Minga.Frontend.Protocol)
  @ctrl 0x02
  @super 0x08

  # Arrow key codepoints sent by libvaxis
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  @impl Mode
  @doc """
  Handles a key event in Visual mode.

  Returns a `t:Minga.Mode.result/0` describing what the editor should do.
  """
  @spec handle_key(Mode.key(), VisualState.t()) :: Mode.result()

  # ── Motions ─────────────────────────────────────────────────────────────────

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

  def handle_key({?w, 0}, %VisualState{text_object_modifier: nil} = state) do
    {:execute, :word_forward, state}
  end

  def handle_key({?b, 0}, %VisualState{text_object_modifier: nil} = state) do
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

  def handle_key({?0, 0}, state) do
    {:execute, :move_to_line_start, state}
  end

  def handle_key({?G, 0}, state) do
    {:execute, :move_to_document_end, state}
  end

  # g prefix for gg
  def handle_key({?g, 0}, %{pending_g: true} = state) do
    {:execute, :move_to_document_start, %{state | pending_g: false}}
  end

  # gc — toggle comment on visual selection
  def handle_key({?c, 0}, %{pending_g: true} = state) do
    {:execute_then_transition, [:comment_visual_selection], :normal, %{state | pending_g: false}}
  end

  def handle_key({?g, 0}, state) do
    {:continue, Map.put(state, :pending_g, true)}
  end

  # WORD motions
  def handle_key({?W, 0}, state) do
    {:execute, :word_forward_big, state}
  end

  def handle_key({?B, 0}, state) do
    {:execute, :word_backward_big, state}
  end

  def handle_key({?E, 0}, state) do
    {:execute, :word_end_big, state}
  end

  # Paragraph motions (guarded: only fire when no text object modifier is
  # pending, so vi{ / vi} can dispatch to the brace text object handler).
  def handle_key({?{, 0}, %VisualState{text_object_modifier: nil} = state) do
    {:execute, :paragraph_backward, state}
  end

  def handle_key({?}, 0}, %VisualState{text_object_modifier: nil} = state) do
    {:execute, :paragraph_forward, state}
  end

  # Bracket matching
  def handle_key({?%, 0}, state) do
    {:execute, :match_bracket, state}
  end

  # Screen-relative
  def handle_key({?H, 0}, state) do
    {:execute, {:move_to_screen, :top}, state}
  end

  def handle_key({?M, 0}, state) do
    {:execute, {:move_to_screen, :middle}, state}
  end

  def handle_key({?L, 0}, state) do
    {:execute, {:move_to_screen, :bottom}, state}
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

  # ── Wrapping (auto-pair) ──────────────────────────────────────────────────────

  # Typing an opening delimiter wraps the visual selection (only when no text
  # object modifier is pending, to avoid conflicts with vi"/va(/etc.).
  def handle_key({?(, 0}, %VisualState{text_object_modifier: nil} = state) do
    {:execute_then_transition, [{:wrap_visual_selection, "(", ")"}], :normal, state}
  end

  def handle_key({?[, 0}, %VisualState{text_object_modifier: nil} = state) do
    {:execute_then_transition, [{:wrap_visual_selection, "[", "]"}], :normal, state}
  end

  # Note: { and } are paragraph motions in Visual mode, so { wrapping is not
  # available here. Use operator-pending text objects instead (e.g. vi{).

  def handle_key({?", 0}, %VisualState{text_object_modifier: nil} = state) do
    {:execute_then_transition, [{:wrap_visual_selection, "\"", "\""}], :normal, state}
  end

  def handle_key({?', 0}, %VisualState{text_object_modifier: nil} = state) do
    {:execute_then_transition, [{:wrap_visual_selection, "'", "'"}], :normal, state}
  end

  def handle_key({?`, 0}, %VisualState{text_object_modifier: nil} = state) do
    {:execute_then_transition, [{:wrap_visual_selection, "`", "`"}], :normal, state}
  end

  # ── Text object selection ──────────────────────────────────────────────────────

  # `i` enters "inner" text object mode.
  def handle_key({?i, 0}, %VisualState{text_object_modifier: nil} = state) do
    {:continue, %{state | text_object_modifier: :inner}}
  end

  # `a` enters "around" text object mode (only when no modifier set).
  def handle_key({?a, 0}, %VisualState{text_object_modifier: nil} = state) do
    {:continue, %{state | text_object_modifier: :around}}
  end

  # Word text object
  def handle_key({?w, 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    {:execute, [{:visual_text_object, modifier, :word}], %{state | text_object_modifier: nil}}
  end

  # Quote text objects
  def handle_key({?", 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    {:execute, [{:visual_text_object, modifier, {:quote, "\""}}],
     %{state | text_object_modifier: nil}}
  end

  def handle_key({?', 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    {:execute, [{:visual_text_object, modifier, {:quote, "'"}}],
     %{state | text_object_modifier: nil}}
  end

  # Paren text objects
  def handle_key({paren, 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] and paren in [?(, ?)] do
    {:execute, [{:visual_text_object, modifier, {:paren, "(", ")"}}],
     %{state | text_object_modifier: nil}}
  end

  def handle_key({bracket, 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] and bracket in [?[, ?]] do
    {:execute, [{:visual_text_object, modifier, {:paren, "[", "]"}}],
     %{state | text_object_modifier: nil}}
  end

  def handle_key({brace, 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] and brace in [?{, ?}] do
    {:execute, [{:visual_text_object, modifier, {:paren, "{", "}"}}],
     %{state | text_object_modifier: nil}}
  end

  # Structural text objects (tree-sitter)
  def handle_key({?f, 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    {:execute, [{:visual_text_object, modifier, {:structural, :function}}],
     %{state | text_object_modifier: nil}}
  end

  def handle_key({?c, 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    {:execute, [{:visual_text_object, modifier, {:structural, :class}}],
     %{state | text_object_modifier: nil}}
  end

  def handle_key({?a, 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    {:execute, [{:visual_text_object, modifier, {:structural, :parameter}}],
     %{state | text_object_modifier: nil}}
  end

  def handle_key({?b, 0}, %VisualState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    {:execute, [{:visual_text_object, modifier, {:structural, :block}}],
     %{state | text_object_modifier: nil}}
  end

  # ── Operators ────────────────────────────────────────────────────────────────

  @doc false
  # > — indent visual selection, return to Normal
  def handle_key({?>, 0}, state) do
    {:execute_then_transition, [:indent_visual_selection], :normal, state}
  end

  # < — dedent visual selection, return to Normal
  def handle_key({?<, 0}, state) do
    {:execute_then_transition, [:dedent_visual_selection], :normal, state}
  end

  # = — reindent visual selection, return to Normal
  def handle_key({?=, 0}, state) do
    {:execute_then_transition, [:reindent_visual_selection], :normal, state}
  end

  # d — delete selection, return to Normal
  def handle_key({?d, 0}, state) do
    {:execute_then_transition, [:delete_visual_selection], :normal, state}
  end

  # Cmd+C (GUI) / Super+C — copy selection to system clipboard, return to Normal
  def handle_key({?c, mods}, state) when band(mods, @super) != 0 do
    {:execute_then_transition, [:yank_visual_selection], :normal, state}
  end

  # c — delete selection, enter Insert
  def handle_key({?c, 0}, state) do
    {:execute_then_transition, [:delete_visual_selection], :insert, state}
  end

  # y — yank selection, return to Normal
  def handle_key({?y, 0}, state) do
    {:execute_then_transition, [:yank_visual_selection], :normal, state}
  end

  # ── Escape: cancel visual selection ─────────────────────────────────────────

  def handle_key({@escape, _mods}, state) do
    {:transition, :normal, state}
  end

  # ── User-defined visual-mode overrides ──────────────────────────────────
  # Before giving up, check user-defined visual-mode bindings.
  def handle_key(key, state) do
    filetype = Map.get(state, :filetype)

    case check_user_override(:visual, filetype, key) do
      {:command, command} ->
        {:execute, command, state}

      :not_found ->
        {:continue, state}
    end
  end

  @spec check_user_override(atom(), atom() | nil, Mode.key()) :: {:command, atom()} | :not_found
  defp check_user_override(mode, filetype, key) do
    KeymapActive.resolve_mode_binding(mode, filetype, key)
  catch
    :exit, _ -> :not_found
  end
end
