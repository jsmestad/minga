defmodule MingaEditor.Commands do
  @moduledoc """
  Command execution for the editor.

  Atom commands are dispatched through `Minga.Command.Registry`, which maps
  command names to execute functions pointing at the appropriate sub-module.
  Tuple commands (parameterized commands like `{:insert_char, c}`) still use
  pattern matching since they carry runtime arguments.

  ## Sub-modules

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

  alias Minga.Buffer
  alias Minga.Extension.CallbackInvoker
  alias MingaEditor.Extension.EventWorkflow, as: ExtensionEventWorkflow
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.ToolPrompts
  alias MingaEditor.Shell.Traditional.ToolPromptWorkflow
  alias Minga.Command
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Commands.Editing, as: EditingCommands
  alias MingaEditor.Commands.Eval
  alias MingaEditor.Commands.Extensions, as: ExtCommands
  alias MingaEditor.Commands.Help
  alias MingaEditor.Commands.Lsp, as: LspCommands
  alias MingaEditor.Commands.Tutor
  alias MingaEditor.Commands.Marks
  alias MingaEditor.Commands.Movement
  alias MingaEditor.Commands.Operators
  alias MingaEditor.Commands.Tool
  alias MingaEditor.Commands.Visual
  alias MingaEditor.Commands.Workspace, as: WorkspaceCommands
  alias MingaEditor.Editing
  alias MingaEditor.LspActions
  alias MingaEditor.MinibufferData
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Window
  alias Minga.Keymap
  alias Minga.Keymap.Bindings
  alias Minga.Mode
  alias Minga.Parser.Manager, as: ParserManager

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Action the GenServer must dispatch after execute/2."
  @type action ::
          {:dot_repeat, non_neg_integer() | nil}
          | {:replay_macro, String.t()}

  # These ex commands stay on the direct BufferManagement path so shutdown, save, and tab behavior stay as-is.
  @buffer_management_ex_commands [
    :abort_quit,
    :buffer_next,
    :buffer_prev,
    :buffers,
    :checktime,
    :force_edit,
    :force_quit,
    :force_quit_all,
    :force_save,
    :new_buffer,
    :quit,
    :quit_all,
    :reload_highlights,
    :save,
    :save_quit,
    :save_quit_all,
    :split_horizontal,
    :split_vertical,
    :terminal,
    :view_warnings,
    :window_close
  ]

  @ex_tuple_dispatch_commands [
    :agent_set_model,
    :tool_install_named,
    :tool_uninstall_named,
    :tool_update_named
  ]

  # Authoritative viewport-jump commands (#2652): a frontend holding a local
  # free-scroll offset must always discard it after one of these runs, even when
  # the committed top lands on exactly the previous/echoed top (a `zz` while
  # already centered). Marking the active window here (the dispatch choke point
  # for atom commands) bumps `scroll_seq` at settle regardless of whether the top
  # also moved; the settle-time top comparison covers the top-moved case, and the
  # OR keeps it to one bump.
  #
  # Only commands that unconditionally re-anchor belong here — a command that can
  # no-op (a failed search, `%` with no bracket, a jump to an unset mark, the
  # async LSP goto family) must instead mark in its handler's success branch, so
  # a no-op never discards the user's local scroll: see
  # `MingaEditor.Commands.Search`, `MingaEditor.Commands.Movement`
  # (`:match_bracket`), `MingaEditor.Commands.Marks`, and
  # `MingaEditor.LspActions.jump_to_location/4`. The parameterized
  # `{:goto_line, _}` jump (clamped, never fails) is marked in its own dispatch
  # clause below. Pure cursor motion (h/j/k/l, word, H/M/L) is deliberately
  # absent everywhere: it re-anchors via cursor-must-stay-visible, which bumps
  # through the top comparison only when it actually moves the top.
  #
  # This MapSet plus the success-branch marks above are the single source of
  # truth for which commands force a discard; docs reference this location
  # rather than re-listing commands.
  @authoritative_scroll_commands MapSet.new([
                                   :scroll_center,
                                   :scroll_cursor_top,
                                   :scroll_cursor_bottom,
                                   :scroll_down_line,
                                   :scroll_up_line,
                                   :half_page_down,
                                   :half_page_up,
                                   :page_down,
                                   :page_up,
                                   :move_to_document_start,
                                   :move_to_document_end,
                                   :cancel_search
                                 ])

  @doc """
  Executes a single command against the editor state.

  Atom commands are resolved through the Command Registry. Tuple commands
  (parameterized commands) are dispatched via pattern matching.

  Returns `state()` for the common case, or `{state(), action()}` when the
  GenServer must dispatch a follow-up action (dot-repeat, macro replay).
  """
  @spec execute(state(), Mode.command()) :: state() | {state(), action()}

  # ── Tuple commands (parameterized, not registry-dispatched) ───────────────

  # Dot-repeat: return a tagged tuple so the GenServer can call replay_last_change/2.
  def execute(state, {:dot_repeat, count}) do
    {state, {:dot_repeat, count}}
  end

  # Register selection: stores the chosen register name for the next op.
  def execute(state, {:select_register, char}) when is_binary(char) do
    name = if char == "\"", do: "", else: char
    Editing.set_active_register(state, name)
  end

  # Tab bar mouse selection uses id-scoped tuple commands so click targets stay
  # stable even when visible positions are reordered by pinning.
  def execute(state, {:tab_goto_id, tab_id}) when is_integer(tab_id) and tab_id > 0 do
    MingaEditor.TabWorkflow.switch(state, tab_id)
  end

  # ── Leader / which-key (return action tuples) ─────────────────────────────

  def execute(state, {:leader_start, node}) do
    MingaEditor.Shell.Traditional.WhichKeyWorkflow.begin(
      state,
      node,
      leader_keys_from_mode(state)
    )
  end

  def execute(state, {:leader_progress, node}) do
    prefix_keys = leader_keys_from_mode(state)
    {effective_node, state} = maybe_substitute_filetype_trie(state, node)

    MingaEditor.Shell.Traditional.WhichKeyWorkflow.progress(
      state,
      effective_node,
      prefix_keys
    )
  end

  def execute(state, :leader_cancel),
    do: MingaEditor.Shell.Traditional.WhichKeyWorkflow.dismiss(state)

  def execute(state, :whichkey_next_page),
    do: MingaEditor.Shell.Traditional.WhichKeyWorkflow.next_page(state)

  def execute(state, :whichkey_prev_page),
    do: MingaEditor.Shell.Traditional.WhichKeyWorkflow.previous_page(state)

  # ── Eval ───────────────────────────────────────────────────────────────────

  def execute(state, {:eval_expression, _} = cmd), do: Eval.execute(state, cmd)

  # ── Help ───────────────────────────────────────────────────────────────────

  def execute(state, {:describe_key_result, _, _, _} = cmd), do: Help.execute(state, cmd)
  def execute(state, {:describe_key_not_found, _} = cmd), do: Help.execute(state, cmd)

  # ── Tool manager commands (with name argument) ──────────────────────────

  def execute(state, {:tool_install_named, [name]}),
    do: Tool.execute_named(state, :install, name)

  def execute(state, {:tool_uninstall_named, [name]}),
    do: Tool.execute_named(state, :uninstall, name)

  def execute(state, {:tool_update_named, [name]}),
    do: Tool.execute_named(state, :update, name)

  # ── Tool install prompt commands ──────────────────────────────────────────

  def execute(state, {:tool_confirm_accept, name}) do
    case Minga.Tool.Manager.install(name) do
      :ok ->
        state =
          NoticeWorkflow.publish(state, "Installing #{name}...")

        drain_tool_prompt_queue(state)

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Cannot install #{name}: #{reason}"
        )
    end
  end

  def execute(state, {:tool_confirm_decline, name}) do
    prompts = ToolPromptWorkflow.prompts(state)
    declined = MapSet.put(ToolPrompts.declined(prompts), name)
    state = ToolPromptWorkflow.replace(state, ToolPrompts.queue(prompts), declined)
    drain_tool_prompt_queue(state)
  end

  def execute(state, {:tool_confirm_dismiss, declined_set}) do
    prompts = ToolPromptWorkflow.prompts(state)
    declined = MapSet.union(ToolPrompts.declined(prompts), declined_set)
    ToolPromptWorkflow.replace(state, [], declined)
  end

  # ── File tree delete confirmation commands ─────────────────────────────────

  def execute(state, {:delete_confirm_trash, path}) do
    case Minga.Platform.trash(path) do
      :ok ->
        name = Path.basename(path)
        Minga.Log.info(:editor, "[file-tree] Moved to trash: #{name}")

        state
        |> restore_file_tree_scope()
        |> MingaEditor.Commands.FileTree.refresh()

      {:error, reason} ->
        # Trash failed, offer permanent delete as fallback
        Minga.Log.warning(:editor, "[file-tree] Trash failed: #{reason}")
        ms = state.workspace.editing.mode_state

        %{
          state
          | workspace:
              MingaEditor.Session.State.transition_mode(
                state.workspace,
                :delete_confirm,
                Minga.Mode.DeleteConfirmState.to_permanent(ms)
              )
        }
    end
  end

  def execute(state, {:delete_confirm_permanent, path}) do
    case Minga.Platform.permanent_delete(path) do
      :ok ->
        name = Path.basename(path)
        Minga.Log.info(:editor, "[file-tree] Permanently deleted: #{name}")

        state
        |> restore_file_tree_scope()
        |> MingaEditor.Commands.FileTree.refresh()

      {:error, reason} ->
        Minga.Log.warning(:editor, "[file-tree] Delete failed: #{reason}")
        restore_file_tree_scope(state)
    end
  end

  def execute(state, :delete_confirm_cancel) do
    restore_file_tree_scope(state)
  end

  # ── Source-owned parameterized actions ─────────────────────────────────────

  def execute(state, {:branch_delete_confirm, git_root, name, force}) do
    dispatch_editor_action(state, :branch_delete_confirm, {git_root, name, force})
  end

  def execute(state, :branch_delete_cancel) do
    dispatch_editor_action(state, :branch_delete_cancel, nil)
  end

  # ── Agent tuple commands ──────────────────────────────────────────────────

  def execute(state, {:agent_set_model, [model]}), do: AgentCommands.set_model(state, model)

  def execute(state, {:agent_self_insert, char}) do
    if state.workspace.keymap_scope == :agent do
      AgentCommands.scope_self_insert(state, char)
    else
      state
    end
  end

  # ── Parameterized git commands ────────────────────────────────────────────

  def execute(state, {:git_accept_conflict, choice, start_line}) do
    guard_buffer(state, fn ->
      dispatch_editor_action(state, :git_accept_conflict, {choice, start_line})
    end)
  end

  # ── Parameterized movement ────────────────────────────────────────────────

  def execute(state, {:goto_line, _} = cmd) do
    # goto-line is an authoritative jump (#2652): mark before delegating so a jump
    # to a line already on screen still discards a frontend-held local offset.
    guard_buffer(state, fn ->
      workspace = MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)
      state = %{state | workspace: workspace}
      Movement.execute(state, cmd)
    end)
  end

  def execute(state, {:find_char, _, _} = cmd) do
    guard_buffer(state, fn -> Movement.execute(state, cmd) end)
  end

  def execute(state, {:move_to_screen, _} = cmd) do
    guard_buffer(state, fn -> Movement.execute(state, cmd) end)
  end

  def execute(state, {:workspace_goto, workspace_id})
      when is_integer(workspace_id) and workspace_id >= 0 do
    WorkspaceCommands.workspace_goto_by_id(state, workspace_id)
  end

  # ── Parameterized editing ─────────────────────────────────────────────────

  def execute(state, {:delete_chars_at, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:delete_chars_before, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:insert_char, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:replace_char, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:replace_overwrite, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:comment_motion, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:indent_lines, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:dedent_lines, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:indent_motion, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:dedent_motion, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:reindent_lines, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:reindent_motion, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  def execute(state, {:reindent_text_object, _, _} = cmd) do
    guard_buffer(state, fn -> EditingCommands.execute(state, cmd) end)
  end

  # ── Parameterized operators ───────────────────────────────────────────────

  def execute(state, {:delete_motion, _} = cmd) do
    guard_buffer(state, fn -> Operators.execute(state, cmd) end)
  end

  def execute(state, {:change_motion, _} = cmd) do
    guard_buffer(state, fn -> Operators.execute(state, cmd) end)
  end

  def execute(state, {:yank_motion, _} = cmd) do
    guard_buffer(state, fn -> Operators.execute(state, cmd) end)
  end

  def execute(state, {:delete_text_object, _, _} = cmd) do
    guard_buffer(state, fn -> Operators.execute(state, cmd) end)
  end

  def execute(state, {:change_text_object, _, _} = cmd) do
    guard_buffer(state, fn -> Operators.execute(state, cmd) end)
  end

  def execute(state, {:yank_text_object, _, _} = cmd) do
    guard_buffer(state, fn -> Operators.execute(state, cmd) end)
  end

  def execute(state, {:delete_lines_counted, _} = cmd) do
    guard_buffer(state, fn -> Operators.execute(state, cmd) end)
  end

  def execute(state, {:change_lines_counted, _} = cmd) do
    guard_buffer(state, fn -> Operators.execute(state, cmd) end)
  end

  def execute(state, {:yank_lines_counted, _} = cmd) do
    guard_buffer(state, fn -> Operators.execute(state, cmd) end)
  end

  # ── Parameterized visual ──────────────────────────────────────────────────

  def execute(state, {:wrap_visual_selection, _, _} = cmd) do
    guard_buffer(state, fn -> Visual.execute(state, cmd) end)
  end

  def execute(state, {:visual_text_object, _, _} = cmd) do
    guard_buffer(state, fn -> Visual.execute(state, cmd) end)
  end

  # ── Parameterized search ──────────────────────────────────────────────────

  # (none currently, all search commands are atoms)

  # ── Parameterized marks ───────────────────────────────────────────────────

  def execute(state, {:set_mark, _} = cmd) do
    guard_buffer(state, fn -> Marks.execute(state, cmd) end)
  end

  def execute(state, {:jump_to_mark_line, _} = cmd) do
    guard_buffer(state, fn -> Marks.execute(state, cmd) end)
  end

  def execute(state, {:jump_to_mark_exact, _} = cmd) do
    guard_buffer(state, fn -> Marks.execute(state, cmd) end)
  end

  # ── Textobject navigation ─────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:goto_next_textobject, type})
      when is_pid(buf) do
    {row, col} = Buffer.cursor(buf)

    case MingaEditor.Session.State.active_window_struct(state.workspace) do
      nil ->
        state

      %Window{} = win ->
        case Window.next_textobject(win, type, {row, col}) do
          nil ->
            state

          {target_row, target_col} ->
            Buffer.move_to(buf, {target_row, target_col})
            state
        end
    end
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:goto_prev_textobject, type})
      when is_pid(buf) do
    {row, col} = Buffer.cursor(buf)

    case MingaEditor.Session.State.active_window_struct(state.workspace) do
      nil ->
        state

      %Window{} = win ->
        case Window.prev_textobject(win, type, {row, col}) do
          nil ->
            state

          {target_row, target_col} ->
            Buffer.move_to(buf, {target_row, target_col})
            state
        end
    end
  end

  # ── Macro commands (return action tuples) ─────────────────────────────────

  def execute(state, {:start_macro_recording, register}) do
    alias MingaEditor.MacroRecorder

    rec =
      Editing.macro_recorder(state)
      |> MacroRecorder.start_recording(register)
      |> Map.put(:last_register, register)

    Editing.set_macro_recorder(state, rec)
  end

  def execute(state, {:replay_macro, register}) do
    alias MingaEditor.MacroRecorder

    case MacroRecorder.get_macro(Editing.macro_recorder(state), register) do
      nil ->
        NoticeWorkflow.publish(
          state,
          "No macro in register @#{register}"
        )

      _keys ->
        rec = %{Editing.macro_recorder(state) | last_register: register}
        {Editing.set_macro_recorder(state, rec), {:replay_macro, register}}
    end
  end

  # ── Minibuffer candidate acceptance ───────────────────────────────────────

  def execute(state, {:accept_command_candidate}) do
    if Minga.Editing.mode(state) == :command do
      accept_command_candidate(state)
    else
      state
    end
  end

  def execute(state, :detach_remote_session) do
    MingaEditor.Commands.AgentSession.detach_current_remote_session(state)
  end

  def execute(
        state,
        {:connect_remote_session,
         %{server_name: server_name, session_id: session_id, pid: remote_pid, token: token}}
      ) do
    MingaEditor.Commands.Agent.connect_remote_session(
      state,
      server_name,
      session_id,
      remote_pid,
      token
    )
  end

  def execute(state, {:execute_command_candidate, input, candidate_index}) do
    execute_command_candidate(state, input, candidate_index)
  end

  # ── Ex commands (tuple dispatch) ──────────────────────────────────────────

  def execute(state, {:execute_ex_command, {:lsp_info, []}}),
    do: LspCommands.execute(state, :lsp_info)

  def execute(state, {:execute_ex_command, {:lsp_restart, []}}),
    do: LspCommands.execute(state, :lsp_restart)

  def execute(state, {:execute_ex_command, {:lsp_stop, []}}),
    do: LspCommands.execute(state, :lsp_stop)

  def execute(state, {:execute_ex_command, {:lsp_start, []}}),
    do: LspCommands.execute(state, :lsp_start)

  def execute(state, {:execute_ex_command, {:parser_restart, []}}) do
    case ParserManager.restart() do
      :ok ->
        NoticeWorkflow.publish(state, "Parser restarted")

      {:error, :binary_not_found} ->
        NoticeWorkflow.publish(
          state,
          "Parser restart failed: binary not found"
        )
    end
  catch
    :exit, _ ->
      NoticeWorkflow.publish(
        state,
        "Parser restart failed: manager not available"
      )
  end

  def execute(state, {:execute_ex_command, {:safe_mode_status, []}}) do
    NoticeWorkflow.publish(state, safe_mode_status_message())
  end

  def execute(state, {:execute_ex_command, {:extensions, []}}) do
    ExtCommands.list(state)
  end

  def execute(state, {:execute_ex_command, {:extension_update_all, []}}) do
    ExtCommands.update_all(state)
  end

  def execute(state, {:execute_ex_command, {:extension_update, []}}) do
    ExtCommands.update(state)
  end

  def execute(state, {:execute_ex_command, {:describe_command, []}}) do
    Help.execute(state, :describe_command)
  end

  def execute(state, {:execute_ex_command, {:describe_command_named, [name]}}) do
    Help.execute(state, {:describe_command_named, name})
  end

  def execute(state, {:execute_ex_command, {:tutor, []}}) do
    Tutor.execute(state, :tutor)
  end

  def execute(state, {:execute_ex_command, {:describe_option, []}}) do
    Help.execute(state, :describe_option)
  end

  def execute(state, {:execute_ex_command, {:describe_option_named, [name]}}) do
    Help.execute(state, {:describe_option_named, name})
  end

  def execute(state, {:execute_ex_command, {:rename, new_name}}) do
    LspActions.rename(state, new_name)
  end

  def execute(state, {:execute_ex_command, {name, []} = parsed})
      when is_atom(name) and name in @buffer_management_ex_commands do
    BufferManagement.execute(state, {:execute_ex_command, parsed})
  end

  def execute(state, {:execute_ex_command, {name, []} = parsed}) when is_atom(name) do
    case Command.lookup(name) do
      {:ok, %Command{}} -> execute(state, name)
      :error -> BufferManagement.execute(state, {:execute_ex_command, parsed})
    end
  end

  def execute(state, {:execute_ex_command, {name, _args} = parsed})
      when is_atom(name) and name in @ex_tuple_dispatch_commands do
    execute(state, parsed)
  end

  def execute(state, {:execute_ex_command, _} = cmd), do: BufferManagement.execute(state, cmd)

  # ── Registry dispatch for atom commands ───────────────────────────────────
  #
  # This is the main dispatch path. All atom commands are looked up in the
  # Command Registry. If the command requires a buffer and none is active,
  # we return state unchanged. Otherwise, call the registered execute function.

  def execute(state, cmd) when is_atom(cmd) do
    case Command.lookup(cmd) do
      {:ok, %Command{} = command} ->
        execute_checked(state, cmd, command)

      :error ->
        state
    end
  end

  # Unknown / unimplemented commands are silently ignored.
  def execute(state, _cmd), do: state

  # Checks scope and buffer requirements before executing a registry command.
  # Scope is checked first: a command with `scope: :agent` is a silent
  # no-op when the current keymap scope is not `:agent`. Buffer requirement is
  # checked second.
  @spec execute_checked(state(), atom(), Command.t()) :: state() | {state(), action()}
  defp execute_checked(state, _cmd, %Command{scope: scope})
       when is_atom(scope) and scope != nil and scope != state.workspace.keymap_scope do
    state
  end

  defp execute_checked(state, _cmd, %Command{requires_buffer: true})
       when is_nil(state.workspace.buffers.active) do
    state
  end

  defp execute_checked(state, cmd, %Command{execute: fun}) do
    state = maybe_mark_authoritative_scroll(state, cmd)

    result =
      Minga.Telemetry.span([:minga, :command, :execute], %{command: cmd}, fn ->
        fun.(state)
      end)

    normalize_registered_command_result(result, state)
  end

  @spec normalize_registered_command_result(term(), state()) :: state() | {state(), action()}
  defp normalize_registered_command_result(
         {:extension_callback, _source, _module, _function,
          {:ok, %EditorState{} = updated_state}},
         _original_state
       ),
       do: updated_state

  defp normalize_registered_command_result(
         {:extension_callback, source, module, function, {:ok, returned}},
         original_state
       ) do
    _failure = CallbackInvoker.invalid_return(source, module, function, returned)
    original_state
  end

  defp normalize_registered_command_result(
         {:extension_callback, _source, _module, _function, {:error, _failure}},
         original_state
       ),
       do: original_state

  defp normalize_registered_command_result(%EditorState{} = state, _original_state), do: state

  defp normalize_registered_command_result(
         {%EditorState{} = state, action},
         _original_state
       ),
       do: {state, action}

  defp normalize_registered_command_result(returned, _original_state) do
    raise ArgumentError,
          "registered core command returned invalid state: #{inspect(returned, limit: 20)}"
  end

  # Bumps the active window's authoritative-scroll marker before an
  # authoritative viewport-jump command runs (#2652). Marking the input state is
  # safe: the command's own window mutations (viewport commit or async cursor
  # move) preserve the marker field, and the mark is consumed once at the next
  # settle.
  @spec maybe_mark_authoritative_scroll(state(), atom()) :: state()
  defp maybe_mark_authoritative_scroll(state, cmd) do
    if MapSet.member?(@authoritative_scroll_commands, cmd) do
      %{state | workspace: MingaEditor.Session.State.mark_authoritative_scroll(state.workspace)}
    else
      state
    end
  end

  # ── Public buffer helpers (called directly from Editor) ───────────────────

  @doc "Returns the existing buffer for a file path, or starts one if needed."
  @spec start_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_buffer(file_path), do: start_buffer(file_path, nil, [])

  @spec start_buffer(String.t(), Minga.Config.Options.server() | nil) ::
          {:ok, pid()} | {:error, term()}
  def start_buffer(file_path, options_server), do: start_buffer(file_path, options_server, [])

  @spec start_buffer(String.t(), Minga.Config.Options.server() | nil, keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_buffer(file_path, options_server, opts) do
    options_server = normalize_options_server(options_server)
    history_attribution = Keyword.get(opts, :history_attribution, :active_workspace)

    MingaEditor.HugeFile.guard(file_path, options_server, fn ->
      Buffer.ensure_for_path(file_path, Minga.Events.default_registry(),
        options_server: options_server,
        history_attribution: history_attribution
      )
    end)
  end

  @doc "Adds a new buffer to the list and makes it active."
  @spec add_buffer(state(), pid(), keyword()) :: state()
  def add_buffer(state, pid, opts \\ []),
    do: MingaEditor.Handlers.BufferRegistry.add_buffer(state, pid, opts)

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec guard_buffer(state(), (-> state() | {state(), action()})) ::
          state() | {state(), action()}
  defp guard_buffer(%{workspace: %{buffers: %{active: nil}}} = state, _fun), do: state
  defp guard_buffer(_state, fun), do: fun.()

  @spec normalize_options_server(term() | nil) :: Minga.Config.Options.server()
  defp normalize_options_server(nil), do: Minga.Config.Options.default_server()
  defp normalize_options_server(server), do: Minga.Config.Options.validate_server!(server)

  @spec safe_mode_status_message() :: String.t()
  defp safe_mode_status_message do
    if Minga.SafeMode.active?() do
      "Safe mode is active: user config was not loaded at startup"
    else
      "Safe mode is inactive"
    end
  end

  @spec dispatch_editor_action(state(), atom(), term()) :: state()
  defp dispatch_editor_action(state, action, arguments) do
    ExtensionEventWorkflow.dispatch(state, {:editor_action, action, arguments})
  end

  # Remove the current tool from the prompt queue after accept/decline.
  @spec drain_tool_prompt_queue(state()) :: state()
  # After delete confirmation, restore the file tree keymap scope so the user
  # is back in the file tree, not stuck in editor scope.
  @spec restore_file_tree_scope(EditorState.t()) :: EditorState.t()
  defp restore_file_tree_scope(state) do
    if state.workspace.file_tree.tree != nil do
      %{
        state
        | workspace: MingaEditor.Session.State.set_keymap_scope(state.workspace, :file_tree)
      }
    else
      state
    end
  end

  defp drain_tool_prompt_queue(state), do: ToolPromptWorkflow.advance(state)

  @spec accept_command_candidate(state()) :: state()
  defp accept_command_candidate(state) do
    ms = Editing.mode_state(state)

    case resolve_command_candidate(ms.input, ms.candidate_index) do
      nil ->
        state

      %{label: label} ->
        new_ms = %{ms | input: label, candidate_index: 0}
        Editing.update_mode_state(state, fn _ -> new_ms end)
    end
  end

  @spec execute_command_candidate(state(), String.t(), integer()) :: state()
  defp execute_command_candidate(state, input, candidate_index) do
    case resolve_command_candidate(input, candidate_index) do
      nil ->
        NoticeWorkflow.publish(state, "No matching command")

      %{label: label} ->
        parsed = Minga.Command.Parser.parse(label)
        BufferManagement.execute(state, {:execute_ex_command, parsed})
    end
  end

  @spec resolve_command_candidate(String.t(), integer()) :: map() | nil
  defp resolve_command_candidate(input, candidate_index) do
    {candidates, _total} = MinibufferData.complete_ex_command(input)
    idx = MinibufferData.clamp_index(candidate_index, Enum.count(candidates))
    Enum.at(candidates, idx)
  end

  # ── Filetype trie substitution ────────────────────────────────────────────

  @spec leader_keys_from_mode(EditorState.t()) :: [String.t()]
  defp leader_keys_from_mode(state) do
    case Editing.mode_state(state) do
      %{leader_keys: keys} when is_list(keys) -> Enum.reverse(keys)
      _ -> []
    end
  end

  @spec maybe_substitute_filetype_trie(EditorState.t(), Bindings.node_t()) ::
          {Bindings.node_t(), EditorState.t()}
  defp maybe_substitute_filetype_trie(state, node) do
    case Editing.mode_state(state) do
      %{leader_keys: ["m", "SPC"]} ->
        filetype = current_filetype(state)
        ft_trie = filetype_trie_for(state, filetype)

        if ft_trie.children == %{} do
          {node, state}
        else
          state = Editing.set_leader_node(state, ft_trie)
          {ft_trie, state}
        end

      _ ->
        {node, state}
    end
  end

  @spec current_filetype(EditorState.t()) :: atom()
  defp current_filetype(%{workspace: %{buffers: %{active: nil}}}), do: :text

  defp current_filetype(%{workspace: %{buffers: %{active: buf}}}) do
    Buffer.filetype(buf)
  catch
    :exit, _ -> :text
  end

  @spec filetype_trie_for(EditorState.t(), atom()) :: Bindings.node_t()
  defp filetype_trie_for(state, filetype) do
    Keymap.filetype_trie(state.interaction.keymap_server, filetype)
  catch
    :exit, _ ->
      Minga.Log.warning(
        :config,
        "filetype_trie unavailable for #{inspect(filetype)}; using empty trie"
      )

      Bindings.new()
  end
end
