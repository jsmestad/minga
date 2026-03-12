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
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Loader, as: ConfigLoader
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.Commands.BufferManagement
  alias Minga.Editor.Commands.Diagnostics
  alias Minga.Editor.Commands.Editing
  alias Minga.Editor.Commands.Eval
  alias Minga.Editor.Commands.Git, as: GitCommands
  alias Minga.Editor.Commands.Help
  alias Minga.Editor.Commands.Marks
  alias Minga.Editor.Commands.Movement
  alias Minga.Editor.Commands.Operators
  alias Minga.Editor.Commands.Project
  alias Minga.Editor.Commands.Search
  alias Minga.Editor.Commands.Visual
  alias Minga.Editor.Layout
  alias Minga.Editor.LspActions
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.TabBar
  alias Minga.FileTree
  alias Minga.FileTree.BufferSync
  alias Minga.Formatter
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings
  alias Minga.Mode
  alias Minga.WhichKey

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Action the GenServer must dispatch after execute/2."
  @type action ::
          {:dot_repeat, non_neg_integer() | nil}
          | {:replay_macro, String.t()}
          | {:whichkey_update, Minga.Editor.State.WhichKey.t()}

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

  def execute(state, :theme_picker) do
    PickerUI.open(state, Minga.Picker.ThemeSource)
  end

  def execute(state, :search_project) do
    %{state | mode: :search_prompt, mode_state: %Minga.Mode.SearchPromptState{}}
  end

  # Dot-repeat: return a tagged tuple so the GenServer can call replay_last_change/2.
  def execute(state, {:dot_repeat, count}) do
    {state, {:dot_repeat, count}}
  end

  # Register selection — stores the chosen register name for the next op.
  # `"` (unnamed) maps to the empty-string key; all others are stored as-is.
  def execute(state, {:select_register, char}) when is_binary(char) do
    name = if char == "\"", do: "", else: char
    put_in(state.reg.active, name)
  end

  # ── Leader / which-key (no buffer required) ───────────────────────────────

  def execute(state, {:leader_start, node}) do
    if state.whichkey.timer, do: WhichKey.cancel_timeout(state.whichkey.timer)
    timer = WhichKey.start_timeout()

    whichkey = %Minga.Editor.State.WhichKey{node: node, timer: timer, show: false}
    {state, {:whichkey_update, whichkey}}
  end

  def execute(state, {:leader_progress, node}) do
    if state.whichkey.timer, do: WhichKey.cancel_timeout(state.whichkey.timer)
    timer = WhichKey.start_timeout()

    # When the leader walk reaches SPC m, substitute the filetype-specific
    # trie based on the active buffer's filetype. This makes SPC m t resolve
    # to the correct command for the current filetype.
    {effective_node, state} = maybe_substitute_filetype_trie(state, node)

    whichkey = %Minga.Editor.State.WhichKey{
      node: effective_node,
      timer: timer,
      show: state.whichkey.show
    }

    {state, {:whichkey_update, whichkey}}
  end

  def execute(state, :leader_cancel) do
    if state.whichkey.timer, do: WhichKey.cancel_timeout(state.whichkey.timer)

    whichkey = %Minga.Editor.State.WhichKey{node: nil, timer: nil, show: false}
    {state, {:whichkey_update, whichkey}}
  end

  # ── Eval ───────────────────────────────────────────────────────────────────

  def execute(state, {:eval_expression, _} = cmd), do: Eval.execute(state, cmd)

  # ── Help ───────────────────────────────────────────────────────────────────

  def execute(state, {:describe_key_result, _, _, _} = cmd), do: Help.execute(state, cmd)
  def execute(state, {:describe_key_not_found, _} = cmd), do: Help.execute(state, cmd)

  # ── File tree ─────────────────────────────────────────────────────────────

  def execute(state, :toggle_file_tree), do: toggle_file_tree(state)

  # ── AI Agent (before no-buffer guard — agent works without a buffer) ─────
  def execute(state, :toggle_agent_panel), do: AgentCommands.toggle_panel(state)
  def execute(state, :toggle_agentic_view), do: AgentCommands.toggle_agentic_view(state)
  def execute(state, :toggle_agent_split), do: AgentCommands.toggle_agent_split(state)
  def execute(state, :cycle_agent_tabs), do: AgentCommands.cycle_agent_tabs(state)
  def execute(state, :agent_abort), do: AgentCommands.abort_agent(state)
  def execute(state, :agent_new_session), do: AgentCommands.new_agent_session(state)

  def execute(state, {:agent_set_provider, [provider]}),
    do: AgentCommands.set_provider(state, provider)

  def execute(state, {:agent_set_model, [model]}), do: AgentCommands.set_model(state, model)
  def execute(state, :agent_pick_model), do: PickerUI.open(state, Minga.Picker.AgentModelSource)

  def execute(state, :agent_session_history),
    do: PickerUI.open(state, Minga.Picker.SessionHistorySource)

  def execute(state, :agent_cycle_model), do: AgentCommands.cycle_model(state)

  def execute(state, :agent_cycle_thinking), do: AgentCommands.cycle_thinking_level(state)

  # ── Agent scope commands (dispatched via keymap scope resolution) ──────────
  # Chat scroll commands for normal mode (:agent_scroll_down/up/etc.) removed.
  # Navigation keys now pass through the scope trie to AgentChatNav, which
  # routes them through the Mode FSM against the *Agent* buffer.
  # These two remain for scrolling chat while the prompt input is focused:
  def execute(state, :agent_scroll_half_down), do: AgentCommands.scroll_chat_down(state)
  def execute(state, :agent_scroll_half_up), do: AgentCommands.scroll_chat_up(state)
  def execute(state, :agent_toggle_collapse), do: AgentCommands.scope_toggle_collapse(state)

  def execute(state, :agent_toggle_all_collapse),
    do: AgentCommands.scope_toggle_all_collapse(state)

  def execute(state, :agent_expand_at_cursor), do: AgentCommands.scope_expand_at_cursor(state)
  def execute(state, :agent_collapse_at_cursor), do: AgentCommands.scope_collapse_at_cursor(state)
  def execute(state, :agent_collapse_all), do: AgentCommands.scope_collapse_all(state)
  def execute(state, :agent_expand_all), do: AgentCommands.scope_expand_all(state)
  def execute(state, :agent_next_message), do: AgentCommands.scope_next_message(state)
  def execute(state, :agent_next_code_block), do: AgentCommands.scope_next_code_block(state)
  def execute(state, :agent_next_tool_call), do: AgentCommands.scope_next_tool_call(state)
  def execute(state, :agent_prev_message), do: AgentCommands.scope_prev_message(state)
  def execute(state, :agent_prev_code_block), do: AgentCommands.scope_prev_code_block(state)
  def execute(state, :agent_prev_tool_call), do: AgentCommands.scope_prev_tool_call(state)
  def execute(state, :agent_copy_code_block), do: AgentCommands.scope_copy_code_block(state)
  def execute(state, :agent_copy_message), do: AgentCommands.scope_copy_message(state)
  def execute(state, :agent_open_code_block), do: AgentCommands.scope_open_code_block(state)
  def execute(state, :agent_focus_input), do: AgentCommands.scope_focus_input(state)
  def execute(state, :agent_unfocus_input), do: AgentCommands.scope_unfocus_input(state)
  def execute(state, :agent_unfocus_and_quit), do: AgentCommands.scope_unfocus_and_quit(state)
  def execute(state, :agent_grow_panel), do: AgentCommands.scope_grow_panel(state)
  def execute(state, :agent_shrink_panel), do: AgentCommands.scope_shrink_panel(state)
  def execute(state, :agent_reset_panel), do: AgentCommands.scope_reset_panel(state)
  def execute(state, :agent_switch_focus), do: AgentCommands.scope_switch_focus(state)
  def execute(state, :agent_start_search), do: AgentCommands.scope_start_search(state)
  def execute(state, :agent_next_search_match), do: AgentCommands.scope_next_search_match(state)
  def execute(state, :agent_prev_search_match), do: AgentCommands.scope_prev_search_match(state)
  def execute(state, :agent_session_switcher), do: AgentCommands.scope_session_switcher(state)
  def execute(state, :agent_toggle_help), do: AgentCommands.scope_toggle_help(state)
  def execute(state, :agent_close), do: AgentCommands.scope_close(state)
  def execute(state, :agent_dismiss_or_noop), do: AgentCommands.scope_dismiss_or_noop(state)
  def execute(state, :agent_clear_chat), do: AgentCommands.scope_clear_chat(state)
  def execute(state, :agent_submit_or_newline), do: AgentCommands.scope_submit_or_newline(state)
  def execute(state, :agent_insert_newline), do: AgentCommands.scope_insert_newline(state)
  def execute(state, :agent_submit_or_abort), do: AgentCommands.scope_submit_or_abort(state)
  def execute(state, :agent_input_backspace), do: AgentCommands.input_backspace(state)
  def execute(state, :agent_input_up), do: AgentCommands.scope_input_up(state)
  def execute(state, :agent_input_down), do: AgentCommands.scope_input_down(state)
  def execute(state, :agent_save_buffer), do: AgentCommands.scope_save_buffer(state)

  def execute(state, {:agent_self_insert, char}),
    do: AgentCommands.scope_self_insert(state, char)

  # Input mode transition (insert → normal on Escape)
  def execute(state, :agent_input_to_normal), do: AgentCommands.input_to_normal(state)

  def execute(state, :agent_accept_hunk), do: AgentCommands.scope_accept_hunk(state)
  def execute(state, :agent_reject_hunk), do: AgentCommands.scope_reject_hunk(state)
  def execute(state, :agent_accept_all_hunks), do: AgentCommands.scope_accept_all_hunks(state)
  def execute(state, :agent_reject_all_hunks), do: AgentCommands.scope_reject_all_hunks(state)
  def execute(state, :agent_approve_tool), do: AgentCommands.scope_approve_tool(state)
  def execute(state, :agent_deny_tool), do: AgentCommands.scope_deny_tool(state)

  def execute(state, :agent_trigger_mention),
    do: AgentCommands.scope_trigger_mention(state)

  # ── File tree scope commands ──────────────────────────────────────────────
  def execute(state, :tree_open_or_toggle), do: tree_open_or_toggle(state)
  def execute(state, :tree_toggle_directory), do: tree_toggle_directory(state)
  def execute(state, :tree_expand), do: tree_expand(state)
  def execute(state, :tree_collapse), do: tree_collapse(state)
  def execute(state, :tree_toggle_hidden), do: tree_toggle_hidden(state)
  def execute(state, :tree_refresh), do: tree_refresh(state)
  def execute(state, :tree_close), do: tree_close(state)

  # ── Guard: no buffer → no-op ──────────────────────────────────────────────

  def execute(%{buffers: %{active: nil}} = state, _cmd), do: state

  # ── Movement ──────────────────────────────────────────────────────────────

  def execute(state, :move_left), do: Movement.execute(state, :move_left)
  def execute(state, :move_right), do: Movement.execute(state, :move_right)
  def execute(state, :move_up), do: Movement.execute(state, :move_up)
  def execute(state, :move_down), do: Movement.execute(state, :move_down)
  def execute(state, :move_logical_up), do: Movement.execute(state, :move_logical_up)
  def execute(state, :move_logical_down), do: Movement.execute(state, :move_logical_down)

  def execute(state, :move_to_logical_line_start),
    do: Movement.execute(state, :move_to_logical_line_start)

  def execute(state, :move_to_logical_line_end),
    do: Movement.execute(state, :move_to_logical_line_end)

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
  def execute(state, :window_close), do: Movement.execute(state, :window_close)
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
  def execute(state, :comment_line), do: Editing.execute(state, :comment_line)
  def execute(state, {:comment_motion, _} = cmd), do: Editing.execute(state, cmd)

  def execute(state, :comment_visual_selection),
    do: Editing.execute(state, :comment_visual_selection)

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

  def execute(state, :confirm_project_search),
    do: Search.execute(state, :confirm_project_search)

  def execute(state, :substitute_confirm_advance),
    do: Search.execute(state, :substitute_confirm_advance)

  def execute(state, :apply_substitute_confirm),
    do: Search.execute(state, :apply_substitute_confirm)

  # ── Marks ─────────────────────────────────────────────────────────────────

  def execute(state, {:set_mark, _} = cmd), do: Marks.execute(state, cmd)
  def execute(state, {:jump_to_mark_line, _} = cmd), do: Marks.execute(state, cmd)
  def execute(state, {:jump_to_mark_exact, _} = cmd), do: Marks.execute(state, cmd)
  def execute(state, :jump_to_last_pos_line), do: Marks.execute(state, :jump_to_last_pos_line)
  def execute(state, :jump_to_last_pos_exact), do: Marks.execute(state, :jump_to_last_pos_exact)

  # ── Project ────────────────────────────────────────────────────────────────

  def execute(state, :project_find_file), do: Project.execute(state, :project_find_file)
  def execute(state, :project_switch), do: Project.execute(state, :project_switch)
  def execute(state, :project_invalidate), do: Project.execute(state, :project_invalidate)
  def execute(state, :project_add), do: Project.execute(state, :project_add)
  def execute(state, :project_remove), do: Project.execute(state, :project_remove)
  def execute(state, :project_recent_files), do: Project.execute(state, :project_recent_files)

  # ── Buffer management ─────────────────────────────────────────────────────

  def execute(state, :save), do: BufferManagement.execute(state, :save)
  def execute(state, :force_save), do: BufferManagement.execute(state, :force_save)
  def execute(state, :reload), do: BufferManagement.execute(state, :reload)
  def execute(state, :quit), do: BufferManagement.execute(state, :quit)
  def execute(state, :buffer_list), do: BufferManagement.execute(state, :buffer_list)
  def execute(state, :buffer_list_all), do: BufferManagement.execute(state, :buffer_list_all)
  def execute(state, :buffer_next), do: BufferManagement.execute(state, :buffer_next)
  def execute(state, :buffer_prev), do: BufferManagement.execute(state, :buffer_prev)
  def execute(state, :kill_buffer), do: BufferManagement.execute(state, :kill_buffer)

  def execute(state, :cycle_line_numbers),
    do: BufferManagement.execute(state, :cycle_line_numbers)

  def execute(state, :toggle_wrap),
    do: BufferManagement.execute(state, :toggle_wrap)

  def execute(state, :view_messages), do: BufferManagement.execute(state, :view_messages)
  def execute(state, :view_scratch), do: BufferManagement.execute(state, :view_scratch)
  def execute(state, :new_buffer), do: BufferManagement.execute(state, :new_buffer)
  def execute(state, :open_config), do: BufferManagement.execute(state, :open_config)

  # ── Config reload ────────────────────────────────────────────────────────

  def execute(state, :reload_config) do
    case ConfigLoader.reload() do
      :ok ->
        Minga.Editor.log_to_messages("Config reloaded")
        %{state | status_msg: "Config reloaded"}

      {:error, msg} ->
        Minga.Editor.log_to_messages("Config reload error: #{msg}")
        %{state | status_msg: "Config reload error: #{msg}"}
    end
  end

  # ── Format ────────────────────────────────────────────────────────────

  def execute(%{buffers: %{active: buf}} = state, :format_buffer) when is_pid(buf) do
    filetype = BufferServer.filetype(buf)
    file_path = BufferServer.file_path(buf)
    spec = Formatter.resolve_formatter(filetype, file_path)

    case spec do
      nil ->
        %{state | status_msg: "No formatter configured for #{filetype}"}

      _ ->
        format_and_replace(state, buf, spec)
    end
  end

  def execute(state, :format_buffer), do: %{state | status_msg: "No buffer to format"}

  # ── Diagnostics ──────────────────────────────────────────────────────────

  def execute(state, :diagnostics_list) do
    PickerUI.open(state, Minga.Diagnostics.PickerSource)
  end

  def execute(state, :next_diagnostic) do
    Diagnostics.execute(state, :next_diagnostic)
  end

  def execute(state, :prev_diagnostic) do
    Diagnostics.execute(state, :prev_diagnostic)
  end

  def execute(state, :lsp_info) do
    Diagnostics.execute(state, :lsp_info)
  end

  def execute(state, :goto_definition), do: LspActions.goto_definition(state)
  def execute(state, :hover), do: LspActions.hover(state)

  def execute(state, :next_git_hunk), do: GitCommands.execute(state, :next_git_hunk)
  def execute(state, :prev_git_hunk), do: GitCommands.execute(state, :prev_git_hunk)
  def execute(state, :git_stage_hunk), do: GitCommands.execute(state, :git_stage_hunk)
  def execute(state, :git_revert_hunk), do: GitCommands.execute(state, :git_revert_hunk)
  def execute(state, :git_preview_hunk), do: GitCommands.execute(state, :git_preview_hunk)
  def execute(state, :git_blame_line), do: GitCommands.execute(state, :git_blame_line)

  # ── Macro recording ──────────────────────────────────────────────────────

  def execute(state, :toggle_macro_recording) do
    alias Minga.Editor.MacroRecorder

    case MacroRecorder.recording?(state.macro_recorder) do
      {true, _reg} ->
        # Stop recording
        rec = MacroRecorder.stop_recording(state.macro_recorder)
        %{state | macro_recorder: rec, status_msg: "Recorded macro"}

      false ->
        # Enter pending state for register selection
        %{state | mode_state: %{state.mode_state | pending_macro_register: true}}
    end
  end

  def execute(state, {:start_macro_recording, register}) do
    alias Minga.Editor.MacroRecorder

    rec =
      state.macro_recorder
      |> MacroRecorder.start_recording(register)
      |> Map.put(:last_register, register)

    %{state | macro_recorder: rec}
  end

  def execute(state, {:replay_macro, register}) do
    alias Minga.Editor.MacroRecorder

    case MacroRecorder.get_macro(state.macro_recorder, register) do
      nil ->
        %{state | status_msg: "No macro in register @#{register}"}

      _keys ->
        rec = %{state.macro_recorder | last_register: register}
        {%{state | macro_recorder: rec}, {:replay_macro, register}}
    end
  end

  def execute(%{macro_recorder: %{last_register: nil}} = state, :replay_last_macro) do
    %{state | status_msg: "No previous macro"}
  end

  def execute(%{macro_recorder: %{last_register: reg}} = state, :replay_last_macro) do
    {state, {:replay_macro, reg}}
  end

  def execute(state, {:execute_ex_command, {:lsp_info, []}}),
    do: Diagnostics.execute(state, :lsp_info)

  def execute(state, {:execute_ex_command, {:extensions, []}}) do
    alias Minga.Extension.Supervisor, as: ExtSupervisor

    extensions = ExtSupervisor.list_extensions()

    msg =
      case extensions do
        [] ->
          "No extensions loaded"

        exts ->
          lines =
            Enum.map(exts, fn {name, version, status} ->
              "  #{name} v#{version} [#{status}]"
            end)

          ["Extensions:" | lines] |> Enum.join("\n")
      end

    %{state | status_msg: msg}
  end

  def execute(state, {:execute_ex_command, _} = cmd), do: BufferManagement.execute(state, cmd)

  # Tab bar click: tab_goto_N switches to tab with id N.
  # SPC 1..9 also routes here; N is treated as both a tab ID (for click
  # regions) and a 1-based position index (for keyboard shortcuts).
  # If no tab has that exact ID, we fall back to positional lookup.
  def execute(%{tab_bar: %TabBar{} = tb} = state, cmd) when is_atom(cmd) do
    case parse_tab_goto(cmd) do
      {:ok, n} -> switch_tab_by_id_or_index(state, tb, n)
      :error -> state
    end
  end

  # Unknown / unimplemented commands are silently ignored.
  def execute(state, _cmd), do: state

  @spec parse_tab_goto(atom()) :: {:ok, pos_integer()} | :error
  defp parse_tab_goto(cmd) do
    case Atom.to_string(cmd) do
      "tab_goto_" <> id_str ->
        case Integer.parse(id_str) do
          {n, ""} -> {:ok, n}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @spec switch_tab_by_id_or_index(EditorState.t(), TabBar.t(), pos_integer()) :: EditorState.t()
  defp switch_tab_by_id_or_index(state, tb, n) do
    if TabBar.has_tab?(tb, n) do
      EditorState.switch_tab(state, n)
    else
      case TabBar.tab_at(tb, n) do
        %{id: id} -> EditorState.switch_tab(state, id)
        nil -> state
      end
    end
  end

  # ── Private formatting helpers ─────────────────────────────────────────────

  @spec format_and_replace(state(), pid(), Formatter.formatter_spec()) :: state()
  defp format_and_replace(state, buf, spec) do
    content = BufferServer.content(buf)
    buf_name = BufferServer.file_path(buf) |> Path.basename()

    case Formatter.format(content, spec) do
      {:ok, formatted} ->
        {cursor_line, cursor_col} = BufferServer.cursor(buf)
        BufferServer.replace_content(buf, formatted)
        line_count = BufferServer.line_count(buf)
        safe_line = min(cursor_line, max(line_count - 1, 0))
        BufferServer.move_to(buf, {safe_line, cursor_col})
        Minga.Editor.log_to_messages("Formatted: #{buf_name}")
        %{state | status_msg: "Formatted"}

      {:error, msg} ->
        Minga.Editor.log_to_messages("Formatter failed: #{buf_name} (#{msg})")
        %{state | status_msg: "Format error: #{msg}"}
    end
  end

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
  def add_buffer(state, pid), do: EditorState.add_buffer(state, pid)

  # ── File tree helpers ───────────────────────────────────────────────────

  @spec toggle_file_tree(state()) :: state()
  defp toggle_file_tree(%{file_tree: %{tree: nil}} = state), do: open_file_tree(state)

  defp toggle_file_tree(%{file_tree: %{buffer: buf}} = state) when is_pid(buf) do
    GenServer.stop(buf, :normal)

    %{state | file_tree: FileTreeState.close(state.file_tree), keymap_scope: :editor}
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  defp toggle_file_tree(state) do
    %{state | file_tree: FileTreeState.close(state.file_tree), keymap_scope: :editor}
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec open_file_tree(state()) :: state()
  defp open_file_tree(state) do
    root = Minga.Project.root() || File.cwd!()
    tree = FileTree.new(root)
    tree = FileTree.refresh_git_status(tree)
    tree = reveal_active_in_tree(tree, state.buffers.active)
    buf = BufferSync.start_buffer(tree)

    %{state | file_tree: FileTreeState.open(state.file_tree, tree, buf), keymap_scope: :file_tree}
    |> Layout.invalidate()
    |> EditorState.invalidate_all_windows()
  end

  @spec reveal_active_in_tree(FileTree.t(), pid() | nil) :: FileTree.t()
  defp reveal_active_in_tree(tree, nil), do: tree

  defp reveal_active_in_tree(tree, buf) do
    case BufferServer.file_path(buf) do
      nil -> tree
      path -> FileTree.reveal(tree, path)
    end
  end

  # ── File tree scope commands ──────────────────────────────────────────────

  @spec tree_open_or_toggle(state()) :: state()
  defp tree_open_or_toggle(%{file_tree: %{tree: nil}} = state), do: state

  defp tree_open_or_toggle(%{file_tree: %{tree: tree}} = state) do
    case FileTree.selected_entry(tree) do
      %{dir?: true} ->
        new_tree = FileTree.toggle_expand(tree)
        tree_sync_and_update(state, new_tree)

      %{dir?: false, path: path} ->
        state = put_in(state.file_tree.focused, false)
        state = %{state | keymap_scope: :editor}

        case start_buffer(path) do
          {:ok, pid} -> Minga.Editor.do_file_tree_open(state, pid, path, tree)
          {:error, _} -> state
        end

      nil ->
        state
    end
  end

  @spec tree_toggle_directory(state()) :: state()
  defp tree_toggle_directory(%{file_tree: %{tree: nil}} = state), do: state

  defp tree_toggle_directory(%{file_tree: %{tree: tree}} = state) do
    tree_sync_and_update(state, FileTree.toggle_expand(tree))
  end

  @spec tree_expand(state()) :: state()
  defp tree_expand(%{file_tree: %{tree: nil}} = state), do: state

  defp tree_expand(%{file_tree: %{tree: tree}} = state),
    do: tree_sync_and_update(state, FileTree.expand(tree))

  @spec tree_collapse(state()) :: state()
  defp tree_collapse(%{file_tree: %{tree: nil}} = state), do: state

  defp tree_collapse(%{file_tree: %{tree: tree}} = state),
    do: tree_sync_and_update(state, FileTree.collapse(tree))

  @spec tree_toggle_hidden(state()) :: state()
  defp tree_toggle_hidden(%{file_tree: %{tree: nil}} = state), do: state

  defp tree_toggle_hidden(%{file_tree: %{tree: tree}} = state),
    do: tree_sync_and_update(state, FileTree.toggle_hidden(tree))

  @spec tree_refresh(state()) :: state()
  defp tree_refresh(%{file_tree: %{tree: nil}} = state), do: state

  defp tree_refresh(%{file_tree: %{tree: tree}} = state) do
    tree = tree |> FileTree.refresh() |> FileTree.refresh_git_status()
    tree_sync_and_update(state, tree)
  end

  @spec tree_close(state()) :: state()
  defp tree_close(%{file_tree: %{buffer: buf}} = state) when is_pid(buf) do
    GenServer.stop(buf, :normal)
    %{state | file_tree: FileTreeState.close(state.file_tree), keymap_scope: :editor}
  end

  defp tree_close(state),
    do: %{state | file_tree: FileTreeState.close(state.file_tree), keymap_scope: :editor}

  @spec tree_sync_and_update(state(), FileTree.t()) :: state()
  defp tree_sync_and_update(%{file_tree: %{buffer: buf}} = state, new_tree) when is_pid(buf) do
    BufferSync.sync(buf, new_tree)
    put_in(state.file_tree.tree, new_tree)
  end

  defp tree_sync_and_update(state, new_tree) do
    put_in(state.file_tree.tree, new_tree)
  end

  # ── Filetype trie substitution ────────────────────────────────────────────

  # When the leader sequence reaches SPC m, swap the which-key node with the
  # filetype-specific trie so the next key resolves filetype-scoped bindings.
  # Also updates mode_state.leader_node so the mode FSM uses the same trie.
  @spec maybe_substitute_filetype_trie(EditorState.t(), Bindings.node_t()) ::
          {Bindings.node_t(), EditorState.t()}
  defp maybe_substitute_filetype_trie(state, node) do
    # Check if we just arrived at SPC m (leader_keys is ["m", "SPC"])
    case state.mode_state do
      %{leader_keys: ["m", "SPC"]} ->
        filetype = current_filetype(state)
        ft_trie = filetype_trie_for(filetype)

        if ft_trie.children == %{} do
          # No filetype bindings registered; use the default (empty) m node
          {node, state}
        else
          # Substitute with the filetype trie and update mode_state
          state = put_in(state.mode_state.leader_node, ft_trie)
          {ft_trie, state}
        end

      _ ->
        {node, state}
    end
  end

  @spec current_filetype(EditorState.t()) :: atom()
  defp current_filetype(%{buffers: %{active: nil}}), do: :text

  defp current_filetype(%{buffers: %{active: buf}}) do
    BufferServer.filetype(buf)
  catch
    :exit, _ -> :text
  end

  @spec filetype_trie_for(atom()) :: Bindings.node_t()
  defp filetype_trie_for(filetype) do
    KeymapActive.filetype_trie(filetype)
  catch
    :exit, _ -> Bindings.new()
  end
end
