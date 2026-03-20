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

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Command
  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.Commands.BufferManagement
  alias Minga.Editor.Commands.Editing
  alias Minga.Editor.Commands.Eval
  alias Minga.Editor.Commands.Extensions, as: ExtCommands
  alias Minga.Editor.Commands.Help
  alias Minga.Editor.Commands.Lsp, as: LspCommands
  alias Minga.Editor.Commands.Marks
  alias Minga.Editor.Commands.Movement
  alias Minga.Editor.Commands.Operators
  alias Minga.Editor.Commands.Tool
  alias Minga.Editor.Commands.Visual
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Keymap.Bindings
  alias Minga.Mode
  alias Minga.Parser.Manager, as: ParserManager
  alias Minga.WhichKey

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
    put_in(state.vim.reg.active, name)
  end

  # ── Leader / which-key (return action tuples) ─────────────────────────────

  def execute(state, {:leader_start, node}) do
    if state.whichkey.timer, do: WhichKey.cancel_timeout(state.whichkey.timer)
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
    if state.whichkey.timer, do: WhichKey.cancel_timeout(state.whichkey.timer)
    timer = WhichKey.start_timeout()
    prefix_keys = leader_keys_from_mode(state)

    {effective_node, state} = maybe_substitute_filetype_trie(state, node)

    whichkey = %EditorState.WhichKey{
      node: effective_node,
      timer: timer,
      show: state.whichkey.show,
      prefix_keys: prefix_keys
    }

    {state, {:whichkey_update, whichkey}}
  end

  def execute(state, :leader_cancel) do
    if state.whichkey.timer, do: WhichKey.cancel_timeout(state.whichkey.timer)

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
    whichkey = %{state.whichkey | page: state.whichkey.page + 1}
    {state, {:whichkey_update, whichkey}}
  end

  def execute(state, :whichkey_prev_page) do
    whichkey = %{state.whichkey | page: max(state.whichkey.page - 1, 0)}
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

  # ── Agent tuple commands ──────────────────────────────────────────────────

  def execute(state, {:agent_set_provider, [provider]}),
    do: AgentCommands.set_provider(state, provider)

  def execute(state, {:agent_set_model, [model]}), do: AgentCommands.set_model(state, model)

  def execute(state, {:agent_self_insert, char}),
    do: AgentCommands.scope_self_insert(state, char)

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
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:delete_chars_before, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:insert_char, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:replace_char, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:replace_overwrite, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:comment_motion, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:indent_lines, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:dedent_lines, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:indent_motion, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:dedent_motion, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:reindent_lines, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:reindent_motion, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
  end

  def execute(state, {:reindent_text_object, _, _} = cmd) do
    guard_buffer(state, fn -> Editing.execute(state, cmd) end)
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

  def execute(%{buffers: %{active: buf}} = state, {:goto_next_textobject, type})
      when is_pid(buf) do
    {row, col} = BufferServer.cursor(buf)

    case EditorState.active_window_struct(state) do
      nil ->
        state

      %Window{} = win ->
        case Window.next_textobject(win, type, {row, col}) do
          nil ->
            state

          {target_row, target_col} ->
            BufferServer.move_to(buf, {target_row, target_col})
            state
        end
    end
  end

  def execute(%{buffers: %{active: buf}} = state, {:goto_prev_textobject, type})
      when is_pid(buf) do
    {row, col} = BufferServer.cursor(buf)

    case EditorState.active_window_struct(state) do
      nil ->
        state

      %Window{} = win ->
        case Window.prev_textobject(win, type, {row, col}) do
          nil ->
            state

          {target_row, target_col} ->
            BufferServer.move_to(buf, {target_row, target_col})
            state
        end
    end
  end

  # ── Macro commands (return action tuples) ─────────────────────────────────

  def execute(state, {:start_macro_recording, register}) do
    alias Minga.Editor.MacroRecorder

    rec =
      state.vim.macro_recorder
      |> MacroRecorder.start_recording(register)
      |> Map.put(:last_register, register)

    %{state | vim: %{state.vim | macro_recorder: rec}}
  end

  def execute(state, {:replay_macro, register}) do
    alias Minga.Editor.MacroRecorder

    case MacroRecorder.get_macro(state.vim.macro_recorder, register) do
      nil ->
        %{state | status_msg: "No macro in register @#{register}"}

      _keys ->
        rec = %{state.vim.macro_recorder | last_register: register}
        {%{state | vim: %{state.vim | macro_recorder: rec}}, {:replay_macro, register}}
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
        %{state | status_msg: "Parser restarted"}

      {:error, :binary_not_found} ->
        %{state | status_msg: "Parser restart failed: binary not found"}
    end
  catch
    :exit, _ ->
      %{state | status_msg: "Parser restart failed: manager not available"}
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

  def execute(state, {:execute_ex_command, _} = cmd), do: BufferManagement.execute(state, cmd)

  # ── Registry dispatch for atom commands ───────────────────────────────────
  #
  # This is the main dispatch path. All atom commands are looked up in the
  # Command Registry. If the command requires a buffer and none is active,
  # we return state unchanged. Otherwise, call the registered execute function.

  def execute(state, cmd) when is_atom(cmd) do
    case CommandRegistry.lookup(CommandRegistry, cmd) do
      {:ok, %Command{requires_buffer: true}} when is_nil(state.buffers.active) ->
        state

      {:ok, %Command{execute: fun}} ->
        Minga.Telemetry.span([:minga, :command, :execute], %{command: cmd}, fn ->
          fun.(state)
        end)

      :error ->
        state
    end
  end

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
  def add_buffer(state, pid), do: EditorState.add_buffer(state, pid)

  # ── Private helpers ───────────────────────────────────────────────────────

  @spec guard_buffer(state(), (-> state() | {state(), action()})) ::
          state() | {state(), action()}
  defp guard_buffer(%{buffers: %{active: nil}} = state, _fun), do: state
  defp guard_buffer(_state, fun), do: fun.()

  # ── Filetype trie substitution ────────────────────────────────────────────

  @spec leader_keys_from_mode(EditorState.t()) :: [String.t()]
  defp leader_keys_from_mode(%{vim: %{mode_state: %{leader_keys: keys}}})
       when is_list(keys) do
    Enum.reverse(keys)
  end

  defp leader_keys_from_mode(_state), do: []

  @spec maybe_substitute_filetype_trie(EditorState.t(), Bindings.node_t()) ::
          {Bindings.node_t(), EditorState.t()}
  defp maybe_substitute_filetype_trie(state, node) do
    case state.vim.mode_state do
      %{leader_keys: ["m", "SPC"]} ->
        filetype = current_filetype(state)
        ft_trie = filetype_trie_for(filetype)

        if ft_trie.children == %{} do
          {node, state}
        else
          state = put_in(state.vim.mode_state.leader_node, ft_trie)
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
