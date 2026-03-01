defmodule Minga.Editor.Commands do
  @moduledoc """
  Command execution for the editor.

  Translates `Mode.command()` atoms/tuples into buffer mutations and state
  updates. All public functions return `state()` or `{state(), action()}`.

  This module is a thin dispatcher — each domain has its own sub-module:

  * `Commands.Movement`        — h/j/k/l, word, find-char, bracket, page scroll
  * `Commands.Editing`         — insert/delete, join, replace, indent, undo/redo, paste
  * `Commands.Operators`       — d/c/y with motions and text objects
  * `Commands.Visual`          — visual selection delete/yank/wrap
  * `Commands.Search`          — /, n/N, *, word-under-cursor search
  * `Commands.BufferManagement`— save/reload/quit, :ex commands, buffer cycling
  * `Commands.Marks`           — m, ', `, ``

  ## Action tuples

  When a command requires the GenServer to do something outside the pure
  `state → state` pipeline (dot-repeat replay), `execute/2` returns
  `{state, {:dot_repeat, count}}`. The caller (`Editor`) dispatches it.

  ## Process dictionary side-channel

  Leader/which-key commands write to `Process.put(:__leader_update__, ...)`.
  This works because `execute/2` is always called from within the GenServer
  process; the GenServer merges the update map after all commands run.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.BufferManagement
  alias Minga.Editor.Commands.Editing
  alias Minga.Editor.Commands.Marks
  alias Minga.Editor.Commands.Movement
  alias Minga.Editor.Commands.Operators
  alias Minga.Editor.Commands.Search
  alias Minga.Editor.Commands.Visual
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode
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

  # ── Commands that do not require a buffer ─────────────────────────────────

  def execute(state, :command_palette) do
    PickerUI.open(state, Minga.Picker.CommandSource)
  end

  def execute(state, :find_file) do
    PickerUI.open(state, Minga.Picker.FileSource)
  end

  # Dot-repeat: return a tagged tuple so the GenServer can call replay_last_change/2.
  def execute(state, {:dot_repeat, count}) do
    {state, {:dot_repeat, count}}
  end

  # Register selection — stores the chosen register name for the next op.
  # `"` (unnamed) maps to the empty-string key; all others are stored as-is.
  def execute(state, {:select_register, char}) when is_binary(char) do
    name = if char == "\"", do: "", else: char
    %{state | active_register: name}
  end

  # ── Leader / which-key (no buffer required) ───────────────────────────────

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

  # ── Guard: no buffer → no-op ──────────────────────────────────────────────

  def execute(%{buffer: nil} = state, _cmd), do: state

  # ── Movement ──────────────────────────────────────────────────────────────

  def execute(state, :move_left), do: Movement.execute(state, :move_left)
  def execute(state, :move_right), do: Movement.execute(state, :move_right)
  def execute(state, :move_up), do: Movement.execute(state, :move_up)
  def execute(state, :move_down), do: Movement.execute(state, :move_down)
  def execute(state, :move_to_line_start), do: Movement.execute(state, :move_to_line_start)
  def execute(state, :move_to_line_end), do: Movement.execute(state, :move_to_line_end)
  def execute(state, :word_forward), do: Movement.execute(state, :word_forward)
  def execute(state, :word_backward), do: Movement.execute(state, :word_backward)
  def execute(state, :word_end), do: Movement.execute(state, :word_end)
  def execute(state, :word_forward_big), do: Movement.execute(state, :word_forward_big)
  def execute(state, :word_backward_big), do: Movement.execute(state, :word_backward_big)
  def execute(state, :word_end_big), do: Movement.execute(state, :word_end_big)

  def execute(state, :move_to_first_non_blank),
    do: Movement.execute(state, :move_to_first_non_blank)

  def execute(state, :move_to_document_start),
    do: Movement.execute(state, :move_to_document_start)

  def execute(state, :move_to_document_end), do: Movement.execute(state, :move_to_document_end)
  def execute(state, {:goto_line, _} = cmd), do: Movement.execute(state, cmd)

  def execute(state, :next_line_first_non_blank),
    do: Movement.execute(state, :next_line_first_non_blank)

  def execute(state, :prev_line_first_non_blank),
    do: Movement.execute(state, :prev_line_first_non_blank)

  def execute(state, {:find_char, _, _} = cmd), do: Movement.execute(state, cmd)
  def execute(state, :repeat_find_char), do: Movement.execute(state, :repeat_find_char)

  def execute(state, :repeat_find_char_reverse),
    do: Movement.execute(state, :repeat_find_char_reverse)

  def execute(state, :match_bracket), do: Movement.execute(state, :match_bracket)
  def execute(state, :paragraph_forward), do: Movement.execute(state, :paragraph_forward)
  def execute(state, :paragraph_backward), do: Movement.execute(state, :paragraph_backward)
  def execute(state, {:move_to_screen, _} = cmd), do: Movement.execute(state, cmd)
  def execute(state, :half_page_down), do: Movement.execute(state, :half_page_down)
  def execute(state, :half_page_up), do: Movement.execute(state, :half_page_up)
  def execute(state, :page_down), do: Movement.execute(state, :page_down)
  def execute(state, :page_up), do: Movement.execute(state, :page_up)
  def execute(state, :window_left), do: Movement.execute(state, :window_left)
  def execute(state, :window_right), do: Movement.execute(state, :window_right)
  def execute(state, :window_up), do: Movement.execute(state, :window_up)
  def execute(state, :window_down), do: Movement.execute(state, :window_down)
  def execute(state, :split_vertical), do: Movement.execute(state, :split_vertical)
  def execute(state, :split_horizontal), do: Movement.execute(state, :split_horizontal)
  def execute(state, :describe_key), do: Movement.execute(state, :describe_key)

  # ── Editing ───────────────────────────────────────────────────────────────

  def execute(state, :delete_before), do: Editing.execute(state, :delete_before)
  def execute(state, :delete_at), do: Editing.execute(state, :delete_at)
  def execute(state, :insert_newline), do: Editing.execute(state, :insert_newline)
  def execute(state, {:insert_char, _} = cmd), do: Editing.execute(state, cmd)
  def execute(state, :insert_line_below), do: Editing.execute(state, :insert_line_below)
  def execute(state, :insert_line_above), do: Editing.execute(state, :insert_line_above)
  def execute(state, :join_lines), do: Editing.execute(state, :join_lines)
  def execute(state, {:replace_char, _} = cmd), do: Editing.execute(state, cmd)
  def execute(state, :toggle_case), do: Editing.execute(state, :toggle_case)
  def execute(state, {:replace_overwrite, _} = cmd), do: Editing.execute(state, cmd)
  def execute(state, :replace_restore), do: Editing.execute(state, :replace_restore)
  def execute(state, :undo), do: Editing.execute(state, :undo)
  def execute(state, :redo), do: Editing.execute(state, :redo)
  def execute(state, :paste_before), do: Editing.execute(state, :paste_before)
  def execute(state, :paste_after), do: Editing.execute(state, :paste_after)
  def execute(state, :indent_line), do: Editing.execute(state, :indent_line)
  def execute(state, :dedent_line), do: Editing.execute(state, :dedent_line)
  def execute(state, {:indent_lines, _} = cmd), do: Editing.execute(state, cmd)
  def execute(state, {:dedent_lines, _} = cmd), do: Editing.execute(state, cmd)
  def execute(state, {:indent_motion, _} = cmd), do: Editing.execute(state, cmd)
  def execute(state, {:dedent_motion, _} = cmd), do: Editing.execute(state, cmd)

  def execute(state, :indent_visual_selection),
    do: Editing.execute(state, :indent_visual_selection)

  def execute(state, :dedent_visual_selection),
    do: Editing.execute(state, :dedent_visual_selection)

  # ── Operators ─────────────────────────────────────────────────────────────

  def execute(state, {:delete_motion, _} = cmd), do: Operators.execute(state, cmd)
  def execute(state, {:change_motion, _} = cmd), do: Operators.execute(state, cmd)
  def execute(state, {:yank_motion, _} = cmd), do: Operators.execute(state, cmd)
  def execute(state, :delete_line), do: Operators.execute(state, :delete_line)
  def execute(state, :change_line), do: Operators.execute(state, :change_line)
  def execute(state, :yank_line), do: Operators.execute(state, :yank_line)
  def execute(state, {:delete_text_object, _, _} = cmd), do: Operators.execute(state, cmd)
  def execute(state, {:change_text_object, _, _} = cmd), do: Operators.execute(state, cmd)
  def execute(state, {:yank_text_object, _, _} = cmd), do: Operators.execute(state, cmd)

  # ── Visual ────────────────────────────────────────────────────────────────

  def execute(state, :delete_visual_selection),
    do: Visual.execute(state, :delete_visual_selection)

  def execute(state, :yank_visual_selection), do: Visual.execute(state, :yank_visual_selection)
  def execute(state, {:wrap_visual_selection, _, _} = cmd), do: Visual.execute(state, cmd)

  # ── Search ────────────────────────────────────────────────────────────────

  def execute(state, :incremental_search), do: Search.execute(state, :incremental_search)
  def execute(state, :confirm_search), do: Search.execute(state, :confirm_search)
  def execute(state, :cancel_search), do: Search.execute(state, :cancel_search)
  def execute(state, :search_next), do: Search.execute(state, :search_next)
  def execute(state, :search_prev), do: Search.execute(state, :search_prev)

  def execute(state, :search_word_under_cursor_forward),
    do: Search.execute(state, :search_word_under_cursor_forward)

  def execute(state, :search_word_under_cursor_backward),
    do: Search.execute(state, :search_word_under_cursor_backward)

  # ── Marks ─────────────────────────────────────────────────────────────────

  def execute(state, {:set_mark, _} = cmd), do: Marks.execute(state, cmd)
  def execute(state, {:jump_to_mark_line, _} = cmd), do: Marks.execute(state, cmd)
  def execute(state, {:jump_to_mark_exact, _} = cmd), do: Marks.execute(state, cmd)
  def execute(state, :jump_to_last_pos_line), do: Marks.execute(state, :jump_to_last_pos_line)
  def execute(state, :jump_to_last_pos_exact), do: Marks.execute(state, :jump_to_last_pos_exact)

  # ── Buffer management ─────────────────────────────────────────────────────

  def execute(state, :save), do: BufferManagement.execute(state, :save)
  def execute(state, :force_save), do: BufferManagement.execute(state, :force_save)
  def execute(state, :reload), do: BufferManagement.execute(state, :reload)
  def execute(state, :quit), do: BufferManagement.execute(state, :quit)
  def execute(state, :buffer_list), do: BufferManagement.execute(state, :buffer_list)
  def execute(state, :buffer_next), do: BufferManagement.execute(state, :buffer_next)
  def execute(state, :buffer_prev), do: BufferManagement.execute(state, :buffer_prev)
  def execute(state, :kill_buffer), do: BufferManagement.execute(state, :kill_buffer)

  def execute(state, :cycle_line_numbers),
    do: BufferManagement.execute(state, :cycle_line_numbers)

  def execute(state, {:execute_ex_command, _} = cmd), do: BufferManagement.execute(state, cmd)

  # Unknown / unimplemented commands are silently ignored.
  def execute(state, _cmd), do: state

  # ── Public buffer helpers (called directly from Editor) ───────────────────

  @doc "Starts a new buffer process for the given file path."
  @spec start_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_buffer(file_path) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {BufferServer, file_path: file_path}
    )
  end

  @doc "Adds a new buffer to the list and makes it active."
  @spec add_buffer(state(), pid()) :: state()
  def add_buffer(state, pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    buffers = state.buffers ++ [pid]
    idx = Enum.count(buffers) - 1
    %{state | buffers: buffers, active_buffer: idx, buffer: pid}
  end
end
