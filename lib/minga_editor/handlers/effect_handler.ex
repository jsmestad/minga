defmodule MingaEditor.Handlers.EffectHandler do
  @moduledoc """
  Interprets side-effect instructions returned by event handlers.

  Agent event handlers return `{new_state, [effect()]}` from their callbacks.
  This module walks the effect list and applies each one, keeping handlers
  testable as pure `state -> {state, effects}` functions.
  """

  alias Minga.Session

  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands
  alias MingaEditor.Handlers.SessionRestore
  alias MingaEditor.HighlightEvents
  alias MingaEditor.HighlightSync
  alias MingaEditor.LspActions

  alias MingaEditor.Renderer
  alias MingaEditor.SemanticTokenSync

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Session, as: EditorSessionState

  @typedoc """
  Side effects returned by event handlers and pure state functions.

  * `:render` — schedule a debounced render
  * `{:render, delay_ms}` — schedule render with custom delay
  * `{:open_file, path}` — open a file in a new or existing buffer
  * `{:switch_buffer, pid}` — make this buffer active
  * `{:set_status, msg}` — show a status message in the minibuffer
  * `:clear_status` — clear the status message
  * `{:push_overlay, module}` — push an overlay handler onto the focus stack
  * `{:pop_overlay, module}` — pop an overlay handler from the focus stack
  * `{:log_message, msg}` — log to *Messages* buffer
  * `{:log_warning, msg}` — log to both *Messages* and *Warnings* (warning level)
  * `{:log, subsystem, level, msg}` — log via Minga.Log
  * `:sync_agent_buffer` — sync agent buffer with session output
  * `{:update_tab_label, label}` — update active tab label
  * `{:monitor, pid}` — monitor a buffer process
  * `{:stop_spinner}` — cancel outgoing agent spinner timer
  * `{:start_spinner}` — start incoming agent spinner timer
  * `{:rebuild_agent_session, tab}` — rebuild agent state from session process
  * `{:request_semantic_tokens}` — request semantic tokens from LSP
  * `{:send_after, msg, delay}` — schedule a self-send after delay
  * `{:conceal_spans, pid, spans}` — apply conceal spans to a buffer
  * `{:prettify_symbols, pid}` — run prettify symbols on a buffer
  * `{:update_agent_styled_cache}` — re-cache GUI styled messages
  * `{:evict_parser_trees_timer}` — schedule next eviction check
  * `{:refresh_tool_picker}` — refresh tool picker if open
  * `{:save_session_async, snapshot, opts}` — persist session in background
  * `{:restart_session_timer}` — restart the periodic session timer
  * `{:cancel_session_timer}` — cancel the periodic session timer
  * `{:recover_swap_entries, entries}` — recover swap file entries
  * `{:restore_session, opts}` — restore session from disk
  * `{:request_code_lens}` — request fresh code lenses from LSP
  * `{:request_inlay_hints}` — request fresh inlay hints from LSP
  * `:render_now` — render immediately after a handler updates state
  * `{:save_session_deferred}` — send :save_session to self
  * `{:schedule_file_tree_refresh, delay}` — debounce one filesystem tree refresh
  * `{:handle_git_remote_result, ref, result}` — process git remote result
  """
  @type effect ::
          :render
          | :render_now
          | {:render, delay_ms :: pos_integer()}
          | {:open_file, String.t()}
          | {:switch_buffer, pid()}
          | {:set_status, String.t()}
          | :clear_status
          | {:push_overlay, module()}
          | {:pop_overlay, module()}
          | {:log_message, String.t()}
          | {:log_warning, String.t()}
          | {:log, atom(), atom(), String.t()}
          | :sync_agent_buffer
          | {:update_tab_label, String.t()}
          | {:monitor, pid()}
          | :stop_spinner
          | :start_spinner
          | {:rebuild_agent_session, MingaEditor.State.Tab.t()}
          | {:request_semantic_tokens}
          | {:send_after, term(), non_neg_integer()}
          | {:conceal_spans, pid(), [map()]}
          | {:prettify_symbols, pid()}
          | {:update_agent_styled_cache}
          | {:evict_parser_trees_timer}
          | {:refresh_tool_picker}
          | {:save_session_async, term(), keyword()}
          | {:compact_session, pid()}
          | {:restart_session_timer}
          | {:cancel_session_timer}
          | {:recover_swap_entries, [Session.swap_entry()]}
          | {:restore_session, keyword()}
          | {:request_code_lens}
          | {:request_inlay_hints}
          | {:save_session_deferred}
          | {:schedule_file_tree_refresh, non_neg_integer()}
          | {:handle_git_remote_result, reference(), term()}

  @doc """
  Applies a list of effects to the editor state.

  Agent event handlers return `{new_state, [effect()]}` from their callbacks.
  The Editor interprets each effect. This keeps handlers testable as
  pure `state -> {state, effects}` functions.
  """
  @spec apply_effects(EditorState.t(), [effect()]) :: EditorState.t()
  def apply_effects(state, []), do: state

  def apply_effects(state, [effect | rest]) do
    state = apply_effect(state, effect)
    apply_effects(state, rest)
  end

  @spec compact_session_safely(pid()) :: {:ok, String.t()} | {:error, term()}
  defp compact_session_safely(session_pid) do
    MingaAgent.Session.compact(session_pid)
  catch
    :exit, reason -> {:error, {:compact_exit, reason}}
  end

  @spec apply_effect(EditorState.t(), effect()) :: EditorState.t()
  defp apply_effect(state, :render), do: MingaEditor.schedule_render(state, 16)

  defp apply_effect(state, :render_now), do: Renderer.render_or_async(state)

  defp apply_effect(state, {:set_status, msg}) when is_binary(msg),
    do: EditorState.set_status(state, msg)

  defp apply_effect(state, {:open_file, path}) when is_binary(path),
    do: Commands.execute(state, {:edit_file, path})

  defp apply_effect(state, {:switch_buffer, pid}) when is_pid(pid) do
    case Enum.find_index(state.workspace.buffers.list, &(&1 == pid)) do
      nil -> state
      idx -> EditorState.switch_buffer(state, idx) |> MingaEditor.reset_nav_flash_tracking()
    end
  end

  defp apply_effect(state, {:push_overlay, mod}) when is_atom(mod),
    do: %{state | focus_stack: [mod | state.focus_stack]}

  defp apply_effect(state, {:pop_overlay, mod}) when is_atom(mod),
    do: %{state | focus_stack: List.delete(state.focus_stack, mod)}

  defp apply_effect(state, {:render, delay_ms}) when is_integer(delay_ms),
    do: MingaEditor.schedule_render(state, delay_ms)

  defp apply_effect(state, {:log_message, msg}) when is_binary(msg) do
    Minga.Log.info(:editor, msg)
    state
  end

  defp apply_effect(state, {:log_warning, msg}) when is_binary(msg) do
    Minga.Log.warning(:editor, msg)
    MingaEditor.maybe_schedule_warning_popup(state)
  end

  defp apply_effect(state, :sync_agent_buffer), do: AgentLifecycle.sync_buffer(state)

  defp apply_effect(state, {:update_tab_label, _label}),
    do: AgentLifecycle.maybe_update_tab_label(state)

  defp apply_effect(state, {:monitor, pid}) when is_pid(pid),
    do: EditorState.monitor_buffer(state, pid)

  defp apply_effect(state, :stop_spinner),
    do: AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)

  defp apply_effect(state, :start_spinner) do
    agent = AgentAccess.agent(state)

    if AgentState.busy?(agent) and agent.spinner_timer == nil do
      AgentAccess.update_agent(state, &AgentState.start_spinner_timer/1)
    else
      state
    end
  end

  defp apply_effect(state, {:rebuild_agent_session, %MingaEditor.State.Tab{kind: :agent} = tab}) do
    state
    |> EditorState.rebuild_agent_from_session(tab)
    |> AgentLifecycle.sync_buffer()
  end

  defp apply_effect(state, {:rebuild_agent_session, tab}),
    do: EditorState.rebuild_agent_from_session(state, tab)

  defp apply_effect(state, :clear_status), do: EditorState.clear_status(state)

  defp apply_effect(state, {:log, subsystem, level, msg})
       when is_atom(subsystem) and is_atom(level) and is_binary(msg) do
    apply_log_effect(subsystem, level, msg)
    state
  end

  defp apply_effect(state, {:request_semantic_tokens}),
    do: SemanticTokenSync.request_tokens(state)

  defp apply_effect(state, {:send_after, msg, delay}) when is_integer(delay) do
    if state.backend != :headless do
      Process.send_after(self(), msg, delay)
    end

    state
  end

  defp apply_effect(state, {:schedule_file_tree_refresh, delay}) when is_integer(delay) do
    if MingaEditor.FileTree.Freshness.refresh_scheduled?(state) do
      state
    else
      ref = Process.send_after(self(), :file_tree_refresh_timer, delay)
      MingaEditor.FileTree.Freshness.schedule_refresh(state, ref)
    end
  end

  defp apply_effect(state, {:conceal_spans, pid, spans}) when is_pid(pid) do
    HighlightEvents.handle_conceal_spans(state, pid, spans)
    state
  end

  defp apply_effect(state, {:prettify_symbols, pid}) when is_pid(pid) do
    maybe_spawn_prettify(state)
    state
  end

  defp apply_effect(state, {:update_agent_styled_cache}),
    do: AgentLifecycle.update_styled_cache(state)

  defp apply_effect(state, {:evict_parser_trees_timer}) do
    if state.backend != :headless do
      Process.send_after(
        self(),
        :evict_parser_trees,
        HighlightSync.eviction_check_interval_ms()
      )
    end

    state
  end

  defp apply_effect(state, {:refresh_tool_picker}),
    do: MingaEditor.maybe_refresh_tool_picker(state)

  defp apply_effect(state, {:save_session_async, snapshot, opts}) do
    Task.start(fn ->
      case Session.save(snapshot, opts) do
        :ok -> :ok
        {:error, reason} -> Minga.Log.warning(:editor, "Session save failed: #{inspect(reason)}")
      end
    end)

    state
  end

  defp apply_effect(state, {:compact_session, session_pid}) do
    editor = self()

    Task.start(fn ->
      result = compact_session_safely(session_pid)
      send(editor, {:compact_result, result})
    end)

    state
  end

  defp apply_effect(state, {:restart_session_timer}),
    do: %{state | session: EditorSessionState.restart_timer(state.session)}

  defp apply_effect(state, {:cancel_session_timer}),
    do: %{state | session: EditorSessionState.cancel_timer(state.session)}

  defp apply_effect(state, {:recover_swap_entries, entries}),
    do: SessionRestore.recover_swap_entries(state, entries)

  defp apply_effect(state, {:restore_session, _opts}),
    do: SessionRestore.restore_session(state)

  defp apply_effect(state, {:request_code_lens}),
    do: LspActions.code_lens(state)

  defp apply_effect(state, {:request_inlay_hints}),
    do: LspActions.inlay_hints(state)

  defp apply_effect(state, {:save_session_deferred}) do
    if state.backend != :headless, do: send(self(), :save_session)
    state
  end

  defp apply_effect(state, {:handle_git_remote_result, ref, result}),
    do: Renderer.render_or_async(handle_git_remote_result(state, ref, result))

  @spec handle_git_remote_result(EditorState.t(), reference(), term()) :: EditorState.t()
  defp handle_git_remote_result(state, ref, result) do
    module = :"Elixir.MingaGitPorcelain.Commands"

    if git_porcelain_running?() and Code.ensure_loaded?(module) and
         function_exported?(module, :handle_remote_result, 3) do
      :erlang.apply(module, :handle_remote_result, [state, ref, result])
    else
      state
    end
  end

  @spec git_porcelain_running?() :: boolean()
  defp git_porcelain_running? do
    case Process.whereis(Minga.Extension.Registry) do
      nil -> false
      _pid -> git_porcelain_running_in_registry?()
    end
  catch
    :exit, _reason -> false
  end

  @spec git_porcelain_running_in_registry?() :: boolean()
  defp git_porcelain_running_in_registry? do
    case Minga.Extension.Registry.get(:minga_git_porcelain) do
      {:ok, %{status: :running}} -> true
      _ -> false
    end
  end

  # Dispatches a log effect to the appropriate Minga.Log function.
  @spec apply_log_effect(atom(), atom(), String.t()) :: :ok
  defp apply_log_effect(subsystem, :debug, msg), do: Minga.Log.debug(subsystem, msg)
  defp apply_log_effect(subsystem, :info, msg), do: Minga.Log.info(subsystem, msg)
  defp apply_log_effect(subsystem, :warning, msg), do: Minga.Log.warning(subsystem, msg)
  defp apply_log_effect(subsystem, :error, msg), do: Minga.Log.error(subsystem, msg)

  # Spawns a prettify-symbols Task if enabled and the active buffer has highlights.
  @spec maybe_spawn_prettify(EditorState.t()) :: :ok
  defp maybe_spawn_prettify(%{workspace: %{buffers: %{active: nil}}}), do: :ok

  defp maybe_spawn_prettify(state) do
    if MingaEditor.UI.PrettifySymbols.enabled?() do
      spawn_prettify_task(state)
    end

    :ok
  end

  @spec spawn_prettify_task(EditorState.t()) :: :ok
  defp spawn_prettify_task(state) do
    hl = HighlightSync.get_active_highlight(state)

    if hl.capture_names != {} and tuple_size(hl.spans) > 0 do
      buf = state.workspace.buffers.active
      file_path = Minga.Buffer.file_path(buf)
      filetype = Minga.Language.detect_filetype(file_path)
      Task.start(fn -> MingaEditor.UI.PrettifySymbols.apply(buf, hl, filetype) end)
    end

    :ok
  end
end
