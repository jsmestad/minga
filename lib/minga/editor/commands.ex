defmodule Minga.Editor.Commands do
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
  alias Minga.Command
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.Commands.BufferManagement
  alias Minga.Editor.Commands.Editing, as: EditingCommands
  alias Minga.Editor.Commands.Eval
  alias Minga.Editor.Commands.Extensions, as: ExtCommands
  alias Minga.Editor.Commands.Help
  alias Minga.Editor.Commands.Lsp, as: LspCommands
  alias Minga.Editor.Commands.Marks
  alias Minga.Editor.Commands.Movement
  alias Minga.Editor.Commands.Operators
  alias Minga.Editor.Commands.Tool
  alias Minga.Editor.Commands.Visual
  alias Minga.Editor.Editing
  alias Minga.Editor.LspActions
  alias Minga.Editor.MinibufferData
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window
  alias Minga.Keymap
  alias Minga.Keymap.Bindings
  alias Minga.Mode
  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.UI.WhichKey

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @typedoc "Action the GenServer must dispatch after execute/2."
  @type action ::
          {:dot_repeat, non_neg_integer() | nil}
          | {:replay_macro, String.t()}
          | {:whichkey_update, EditorState.WhichKey.t()}

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

  # ── Leader / which-key (return action tuples) ─────────────────────────────

  def execute(state, {:leader_start, node}) do
    if EditorState.whichkey(state).timer,
      do: WhichKey.cancel_timeout(EditorState.whichkey(state).timer)

    timer = WhichKey.start_timeout()
    prefix_keys = leader_keys_from_mode(state)

    whichkey = %EditorState.WhichKey{
      node: node,
      timer: timer,
      show: false,
      prefix_keys: prefix_keys
    }

    {state, {:whichkey_update, whichkey}}
  end

  def execute(state, {:leader_progress, node}) do
    if EditorState.whichkey(state).timer,
      do: WhichKey.cancel_timeout(EditorState.whichkey(state).timer)

    timer = WhichKey.start_timeout()
    prefix_keys = leader_keys_from_mode(state)

    {effective_node, state} = maybe_substitute_filetype_trie(state, node)

    whichkey = %EditorState.WhichKey{
      node: effective_node,
      timer: timer,
      show: EditorState.whichkey(state).show,
      prefix_keys: prefix_keys
    }

    {state, {:whichkey_update, whichkey}}
  end

  def execute(state, :leader_cancel) do
    if EditorState.whichkey(state).timer,
      do: WhichKey.cancel_timeout(EditorState.whichkey(state).timer)

    whichkey = %EditorState.WhichKey{
      node: nil,
      timer: nil,
      show: false,
      prefix_keys: [],
      page: 0
    }

    {state, {:whichkey_update, whichkey}}
  end

  def execute(state, :whichkey_next_page) do
    whichkey = %{EditorState.whichkey(state) | page: EditorState.whichkey(state).page + 1}
    {state, {:whichkey_update, whichkey}}
  end

  def execute(state, :whichkey_prev_page) do
    whichkey = %{EditorState.whichkey(state) | page: max(EditorState.whichkey(state).page - 1, 0)}
    {state, {:whichkey_update, whichkey}}
  end

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
        state = EditorState.set_status(state, "Installing #{name}...")
        drain_tool_prompt_queue(state)

      {:error, reason} ->
        EditorState.set_status(state, "Cannot install #{name}: #{reason}")
    end
  end

  def execute(state, {:tool_confirm_decline, name}) do
    state =
      EditorState.update_shell_state(
        state,
        &%{&1 | tool_declined: MapSet.put(state.shell_state.tool_declined, name)}
      )

    drain_tool_prompt_queue(state)
  end

  def execute(state, {:tool_confirm_dismiss, declined_set}) do
    declined = MapSet.union(state.shell_state.tool_declined, declined_set)
    EditorState.update_shell_state(state, &%{&1 | tool_declined: declined, tool_prompt_queue: []})
  end

  # ── File tree delete confirmation commands ─────────────────────────────────

  def execute(state, {:delete_confirm_trash, path}) do
    case Minga.Platform.trash(path) do
      :ok ->
        name = Path.basename(path)
        Minga.Editor.log_to_messages("[file-tree] Moved to trash: #{name}")

        state
        |> restore_file_tree_scope()
        |> Minga.Editor.Commands.FileTree.refresh()

      {:error, reason} ->
        # Trash failed, offer permanent delete as fallback
        Minga.Editor.log_to_messages("[file-tree] Trash failed: #{reason}")
        ms = state.workspace.editing.mode_state

        EditorState.transition_mode(
          state,
          :delete_confirm,
          Minga.Mode.DeleteConfirmState.to_permanent(ms)
        )
    end
  end

  def execute(state, {:delete_confirm_permanent, path}) do
    case Minga.Platform.permanent_delete(path) do
      :ok ->
        name = Path.basename(path)
        Minga.Editor.log_to_messages("[file-tree] Permanently deleted: #{name}")

        state
        |> restore_file_tree_scope()
        |> Minga.Editor.Commands.FileTree.refresh()

      {:error, reason} ->
        Minga.Editor.log_to_messages("[file-tree] Delete failed: #{reason}")
        restore_file_tree_scope(state)
    end
  end

  def execute(state, :delete_confirm_cancel) do
    restore_file_tree_scope(state)
  end

  # ── Agent tuple commands ──────────────────────────────────────────────────

  def execute(state, {:agent_set_provider, [provider]}),
    do: AgentCommands.set_provider(state, provider)

  def execute(state, {:agent_set_model, [model]}), do: AgentCommands.set_model(state, model)

  def execute(state, {:agent_self_insert, char}) do
    if state.workspace.keymap_scope == :agent do
      AgentCommands.scope_self_insert(state, char)
    else
      state
    end
  end

  # ── Parameterized movement ────────────────────────────────────────────────

  def execute(state, {:goto_line, _} = cmd) do
    guard_buffer(state, fn -> Movement.execute(state, cmd) end)
  end

  def execute(state, {:find_char, _, _} = cmd) do
    guard_buffer(state, fn -> Movement.execute(state, cmd) end)
  end

  def execute(state, {:move_to_screen, _} = cmd) do
    guard_buffer(state, fn -> Movement.execute(state, cmd) end)
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

    case EditorState.active_window_struct(state) do
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

    case EditorState.active_window_struct(state) do
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
    alias Minga.Editor.MacroRecorder

    rec =
      Editing.macro_recorder(state)
      |> MacroRecorder.start_recording(register)
      |> Map.put(:last_register, register)

    Editing.set_macro_recorder(state, rec)
  end

  def execute(state, {:replay_macro, register}) do
    alias Minga.Editor.MacroRecorder

    case MacroRecorder.get_macro(Editing.macro_recorder(state), register) do
      nil ->
        EditorState.set_status(state, "No macro in register @#{register}")

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
        EditorState.set_status(state, "Parser restarted")

      {:error, :binary_not_found} ->
        EditorState.set_status(state, "Parser restart failed: binary not found")
    end
  catch
    :exit, _ ->
      EditorState.set_status(state, "Parser restart failed: manager not available")
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

  def execute(state, {:execute_ex_command, {:rename, new_name}}) do
    LspActions.rename(state, new_name)
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
    Minga.Telemetry.span([:minga, :command, :execute], %{command: cmd}, fn ->
      fun.(state)
    end)
  end

  # ── Public buffer helpers (called directly from Editor) ───────────────────

  @doc "Starts a new buffer process for the given file path."
  @spec start_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_buffer(file_path) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {Minga.Buffer, file_path: file_path}
    )
  end

  @doc "Adds a new buffer to the list and makes it active."
  @spec add_buffer(state(), pid()) :: state()
  def add_buffer(state, pid), do: EditorState.add_buffer(state, pid)

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec guard_buffer(state(), (-> state() | {state(), action()})) ::
          state() | {state(), action()}
  defp guard_buffer(%{workspace: %{buffers: %{active: nil}}} = state, _fun), do: state
  defp guard_buffer(_state, fun), do: fun.()

  # Remove the current tool from the prompt queue after accept/decline.
  @spec drain_tool_prompt_queue(state()) :: state()
  # After delete confirmation, restore the file tree keymap scope so the user
  # is back in the file tree, not stuck in editor scope.
  @spec restore_file_tree_scope(EditorState.t()) :: EditorState.t()
  defp restore_file_tree_scope(state) do
    if state.workspace.file_tree.tree != nil do
      EditorState.update_workspace(state, &Minga.Workspace.State.set_keymap_scope(&1, :file_tree))
    else
      state
    end
  end

  defp drain_tool_prompt_queue(state) do
    case state.shell_state.tool_prompt_queue do
      [_current | rest] -> EditorState.update_shell_state(state, &%{&1 | tool_prompt_queue: rest})
      [] -> state
    end
  end

  @spec accept_command_candidate(state()) :: state()
  defp accept_command_candidate(state) do
    ms = Editing.mode_state(state)
    {candidates, _total} = MinibufferData.complete_ex_command(ms.input)
    idx = MinibufferData.clamp_index(ms.candidate_index, length(candidates))

    case Enum.at(candidates, idx) do
      nil ->
        state

      %{label: label} ->
        new_ms = %{ms | input: label, candidate_index: 0}
        Editing.update_mode_state(state, fn _ -> new_ms end)
    end
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
        ft_trie = filetype_trie_for(filetype)

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

  @spec filetype_trie_for(atom()) :: Bindings.node_t()
  defp filetype_trie_for(filetype) do
    Keymap.filetype_trie(filetype)
  catch
    :exit, _ -> Bindings.new()
  end
end
