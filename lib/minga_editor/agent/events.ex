defmodule MingaEditor.Agent.Events do
  @moduledoc """
  Handles agent session events and owns their external actions.

  Live events and durable replay both enter `dispatch/2`; coalesced live
  streaming enters `dispatch_batch/2`. State transitions happen first and the
  resulting focused actions are interpreted in list order by the Editor
  process. Rendering, transcript synchronization, tab labels, styled caches,
  logging, and compaction therefore share one workflow.

  The caller correlates events to the active session before dispatch. Durable
  replay is already ordered and bounded; stale live sessions are routed to the
  background shell instead. Compaction is admitted to its session-keyed typed
  effect, whose scheduler-supervised outcome applies transcript/toast state
  only while that session remains current. Render and log failures retain their
  existing subsystem policy.
  """

  alias Minga.Distribution.ConnectionManager
  alias Minga.Project.FileRef
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.Compaction
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaAgent.Session
  alias Minga.Buffer
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Remote
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Workflow

  @type effect ::
          :render
          | {:render, pos_integer()}
          | {:log_message, String.t()}
          | {:log_warning, String.t()}
          | {:log, atom(), :debug | :info | :warning | :error, String.t()}
          | :sync_agent_transcript
          | {:update_tab_label, String.t()}
          | {:compact_session, pid()}

  @doc "Applies one agent event and its focused actions, returning final editor state."
  @spec dispatch(EditorState.t(), term()) :: EditorState.t()
  def dispatch(%EditorState{} = state, event) do
    {state, effects} = handle(state, event)
    apply_effects(state, effects)
  end

  @doc "Applies one coalesced agent stream batch and its focused actions."
  @spec dispatch_batch(EditorState.t(), [term()]) :: EditorState.t()
  def dispatch_batch(%EditorState{} = state, batch) when is_list(batch) do
    {state, effects} = handle_batch(state, batch)
    apply_effects(state, effects)
  end

  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [effect()]}

  def handle(state, {:status_changed, status}) do
    state = AgentAccess.update_agent(state, &AgentState.set_status(&1, status))

    {state, effects} =
      case status do
        :error ->
          {state, [{:log_message, "Agent: error"}]}

        :thinking ->
          {AgentAccess.update_agent_ui(state, &UIState.engage_auto_scroll/1), []}

        _ ->
          {state, []}
      end

    state =
      case status do
        s when s in [:thinking, :tool_executing] ->
          update_activity(state, &Activity.start_turn/1)

        s when s in [:idle, :error, :plan] ->
          update_activity(state, &Activity.finish_turn/1)

        _ ->
          state
      end

    state =
      case status do
        s when s in [:thinking, :tool_executing] ->
          AgentAccess.update_agent(state, &AgentState.start_spinner_timer/1)

        _ ->
          AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)
      end

    state =
      case status do
        :idle -> reset_compact_state(state)
        _ -> state
      end

    # Sync the tab's agent_status for tab bar rendering
    state = sync_tab_agent_status(state, status)

    # Let the active shell mirror foreground agent status if it owns an agent surface.
    state = sync_active_shell_agent_status(state, status)

    {state, effects} = maybe_apply_pending_auto_compact(state, status, effects)

    {state, [:render | effects]}
  end

  # Single-delta entry points. The live streaming path coalesces deltas through
  # `MingaEditor.Agent.Ingest` and applies them via `handle_batch/2`; these
  # clauses remain for the durable remote event-replay path
  # (`MingaEditor.Remote.EventReplay`), which feeds individual records and is a
  # bounded one-shot, not a hot streaming loop. They delegate to the batch path
  # so the state transitions stay in one place.
  def handle(state, {:text_delta, _delta} = delta), do: handle_batch(state, [delta])

  def handle(state, {:thinking_delta, _delta} = delta), do: handle_batch(state, [delta])

  def handle(state, :messages_changed) do
    state = AgentAccess.update_agent_ui(state, &UIState.maybe_auto_scroll/1)
    state = AgentAccess.update_panel(state, &Panel.bump_message_version/1)
    state = maybe_rename_workspace_from_assistant(state)
    {state, [{:render, 16}, :sync_agent_transcript, {:update_tab_label, ""}]}
  end

  def handle(state, {:tool_started, _tool_call_id, name, args}),
    do: handle(state, {:tool_started, name, args})

  def handle(state, {:tool_started, "shell", args}) do
    command = Map.get(args, "command", "")
    state = update_activity(state, &Activity.start_tool(&1, "shell"))
    state = sync_active_tool_name(state, "shell")
    state = update_preview(state, &Preview.set_shell(&1, command))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_update, _id, "shell", partial}) do
    state = AgentAccess.update_agent_ui(state, &UIState.maybe_auto_scroll/1)
    state = update_preview(state, &Preview.update_shell_output(&1, partial))
    {state, [{:render, 50}]}
  end

  def handle(state, {:tool_update, _id, _name, _partial}) do
    state = AgentAccess.update_agent_ui(state, &UIState.maybe_auto_scroll/1)
    {state, [{:render, 50}]}
  end

  def handle(state, {:tool_ended, _tool_call_id, name, result, status}),
    do: handle(state, {:tool_ended, name, result, status})

  def handle(state, {:tool_interrupted, _tool_call_id}) do
    state = update_activity(state, &Activity.finish_tool/1)
    state = sync_active_tool_name(state, nil)
    state = update_preview(state, &Preview.clear/1)
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_ended, "shell", result, status}) do
    shell_status = if status == :error, do: :error, else: :done
    state = update_activity(state, &Activity.finish_tool/1)
    state = sync_active_tool_name(state, nil)
    state = update_preview(state, &Preview.finish_shell(&1, result, shell_status))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_started, "read_file", args}) do
    path = Map.get(args, "path", "")
    state = update_activity(state, &Activity.start_tool(&1, "read_file"))
    state = sync_active_tool_name(state, "read_file")
    state = update_preview(state, &Preview.set_file(&1, path, ""))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_ended, "read_file", result, _status}) do
    state = update_activity(state, &Activity.finish_tool/1)
    state = sync_active_tool_name(state, nil)

    case AgentAccess.view(state).preview.content do
      {:file, path, _} ->
        state = update_preview(state, &Preview.set_file(&1, path, result))
        {state, [{:render, 16}]}

      _ ->
        {state, []}
    end
  end

  def handle(state, {:tool_started, "list_directory", args}) do
    path = Map.get(args, "path", ".")

    state =
      update_activity(state, &Activity.start_tool(&1, "list_directory"))

    state = sync_active_tool_name(state, "list_directory")
    state = update_preview(state, &Preview.set_directory(&1, path, []))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_ended, "list_directory", result, _status}) do
    entries = result |> String.split("\n") |> Enum.reject(&(&1 == ""))
    state = update_activity(state, &Activity.finish_tool/1)
    state = sync_active_tool_name(state, nil)

    case AgentAccess.view(state).preview.content do
      {:directory, path, _} ->
        state = update_preview(state, &Preview.set_directory(&1, path, entries))
        {state, [{:render, 16}]}

      _ ->
        {state, []}
    end
  end

  def handle(state, {:tool_started, name, _args}) do
    state = update_activity(state, &Activity.start_tool(&1, name))
    state = sync_active_tool_name(state, name)
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_ended, _name, _result, _status}) do
    state = update_activity(state, &Activity.finish_tool/1)
    state = sync_active_tool_name(state, nil)
    {state, [{:render, 16}]}
  end

  def handle(state, {:file_changed, path, before_content, after_content, tool_call_id, tool_name}) do
    {state, remote_effects} = reload_remote_buffer_if_open(state, path, after_content)

    state =
      AgentAccess.update_agent_ui(state, &UIState.record_baseline(&1, path, before_content))

    state =
      update_activity(state, &Activity.record_file(&1, path))

    state =
      AgentAccess.update_agent_ui(state, fn ui ->
        UIState.update_edit_timeline(ui, fn timeline ->
          EditTimeline.record_edit(
            timeline,
            path,
            tool_call_id,
            tool_name,
            before_content,
            after_content
          )
        end)
      end)

    # Let the active shell track touched files for any shell-owned agent surface.
    state = track_active_shell_agent_file(state, path)

    # Associate the file's tab with the agent's workspace
    state = associate_file_with_agent_workspace(state, path)

    # Add a chat-visible system message so the transcript records what was modified
    state = add_file_changed_message(state, path, tool_name)

    baseline = UIState.get_baseline(AgentAccess.agent_ui(state), path)
    existing_review = existing_diff_for_path(state, path)

    review =
      case existing_review do
        nil -> DiffReview.new(path, baseline, after_content)
        existing -> DiffReview.update_after(existing, after_content)
      end

    case review do
      nil ->
        {state, [{:render, 16} | remote_effects]}

      _ ->
        state = update_preview(state, &Preview.set_diff(&1, review))
        state = AgentAccess.update_agent_ui(state, &UIState.set_focus(&1, :file_viewer))
        {state, [:render | remote_effects]}
    end
  end

  def handle(state, {:approval_pending, approval}) do
    cached = Map.take(approval, [:tool_call_id, :name, :args, :preview])
    state = AgentAccess.update_agent(state, &AgentState.set_pending_approval(&1, cached))

    # Seed the visible activity timestamp once so approval-only agent context
    # remains stable across renders without falling back to "now" every frame.
    state = update_activity(state, &Activity.ensure_started_at/1)

    # Unfocus the prompt input so the ToolApproval input handler can
    # intercept y/n keys. The user needs to see and respond to the
    # approval prompt, not keep typing in the input field.
    state = AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, false))

    {state, [:render, :sync_agent_transcript]}
  end

  def handle(state, {:approval_resolved, _decision}) do
    state = AgentAccess.update_agent(state, &AgentState.clear_pending_approval/1)
    {state, [{:render, 16}, :sync_agent_transcript]}
  end

  def handle(state, {:error, message}) do
    # The session already surfaced this in the transcript and the provider
    # logged the raw detail to the Messages panel, so we only update status
    # here. Re-logging would double the Messages entry and force-open the panel.
    state = restore_queued_prompts_after_error(state)
    state = AgentAccess.update_agent(state, &AgentState.set_error(&1, message))
    {state, [:render]}
  end

  def handle(state, {:credentials_status, configured?}) do
    state = AgentAccess.update_panel(state, &Panel.set_credentials_configured(&1, configured?))
    {state, [:render]}
  end

  def handle(state, {:todo_plan_updated, todos}) do
    state = update_activity(state, &Activity.set_todos(&1, todos))
    {state, [{:render, 16}]}
  end

  def handle(state, :spinner_tick) do
    if AgentState.busy?(AgentAccess.agent(state)) do
      state = AgentAccess.update_agent_ui(state, &UIState.tick_spinner/1)
      {state, [{:render, 16}]}
    else
      state = AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)
      {state, []}
    end
  end

  def handle(state, :dismiss_toast) do
    state = AgentAccess.update_agent_ui(state, &UIState.dismiss_toast/1)
    {state, [{:render, 16}]}
  end

  def handle(state, {:context_usage, estimated_tokens, context_limit}) do
    state =
      AgentAccess.update_view(state, fn v -> %{v | context_estimate: estimated_tokens} end)

    {state, effects} = maybe_auto_compact(state, estimated_tokens, context_limit)
    {state, [{:render, 16} | effects]}
  end

  # A message was queued (steer or follow-up): trigger render so the pending
  # display can update. The queue contents live in Session, not EditorState,
  # so no state mutation is needed here.
  def handle(state, {:prompt_queued, content, _type}) do
    # Auto-name the workspace from the first prompt (if not custom-named)
    state = maybe_auto_name_workspace(state, content)
    {state, [{:render, 16}]}
  end

  # Both queues were recalled (dequeue or abort+restore). Trigger a render to
  # clear the pending display.
  def handle(state, :queues_recalled) do
    {state, [{:render, 16}]}
  end

  def handle(state, _unknown) do
    {state, []}
  end

  @doc """
  Applies one coalesced batch of stream deltas (#2289).

  `MingaEditor.Agent.Ingest` accumulates `{:text_delta, _}`, `{:thinking_delta, _}`
  and `{:tool_update, _, _, _}` events arriving within a coalescing window and
  forwards them here as a single batch. Applying the batch once means one
  `bump_message_version`, one `:sync_agent_transcript`, and one render request per
  window instead of per delta, which keeps the Editor mailbox shallow under
  streaming load. The per-delta state transitions (auto-scroll, shell preview
  updates) are folded in arrival order so the visible result matches the
  unbatched path.
  """
  @spec handle_batch(EditorState.t(), [term()]) :: {EditorState.t(), [effect()]}
  def handle_batch(state, []), do: {state, []}

  def handle_batch(state, batch) do
    state = AgentAccess.update_agent_ui(state, &UIState.maybe_auto_scroll/1)
    state = Enum.reduce(batch, state, &apply_batched_delta/2)

    if transcript_affecting_batch?(batch) do
      state = AgentAccess.update_panel(state, &Panel.bump_message_version/1)
      {state, [{:render, 16}, :sync_agent_transcript]}
    else
      {state, [{:render, 16}]}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec apply_effects(EditorState.t(), [effect()]) :: EditorState.t()
  defp apply_effects(state, []), do: state

  defp apply_effects(state, [effect | rest]) do
    state = apply_effect(state, effect)
    apply_effects(state, rest)
  end

  @spec apply_effect(EditorState.t(), effect()) :: EditorState.t()
  defp apply_effect(state, :render), do: MingaEditor.schedule_render(state, 16)

  defp apply_effect(state, {:render, delay_ms}),
    do: MingaEditor.schedule_render(state, delay_ms)

  defp apply_effect(state, {:log_message, message}) do
    Minga.Log.info(:editor, message)
    state
  end

  defp apply_effect(state, {:log_warning, message}) do
    Minga.Log.warning(:editor, message)
    state
  end

  defp apply_effect(state, {:log, subsystem, level, message}) do
    log(subsystem, level, message)
    state
  end

  defp apply_effect(state, :sync_agent_transcript), do: AgentLifecycle.sync_transcript(state)

  defp apply_effect(state, {:update_tab_label, _label}),
    do: AgentLifecycle.maybe_update_tab_label(state)

  defp apply_effect(state, {:compact_session, session_pid}),
    do: Compaction.schedule(state, session_pid)

  @spec log(atom(), :debug | :info | :warning | :error, String.t()) :: :ok
  defp log(subsystem, :debug, message), do: Minga.Log.debug(subsystem, message)
  defp log(subsystem, :info, message), do: Minga.Log.info(subsystem, message)
  defp log(subsystem, :warning, message), do: Minga.Log.warning(subsystem, message)
  defp log(subsystem, :error, message), do: Minga.Log.error(subsystem, message)

  @spec update_activity(EditorState.t(), (Activity.t() -> Activity.t())) :: EditorState.t()
  defp update_activity(state, fun) when is_function(fun, 1) do
    AgentAccess.update_agent_ui(state, fn ui ->
      UIState.update_activity(ui, fun)
    end)
  end

  # Folds a single delta's preview-side mutation into state. Text and thinking
  # deltas carry no per-delta state beyond the once-applied bump/sync; only
  # shell tool updates mutate the preview, and they replace (not append) the
  # partial output, so applying them in order matches the unbatched path.
  @spec apply_batched_delta(term(), EditorState.t()) :: EditorState.t()
  defp apply_batched_delta({:tool_update, _id, "shell", partial}, state) do
    update_preview(state, &Preview.update_shell_output(&1, partial))
  end

  defp apply_batched_delta(_delta, state), do: state

  # Only assistant text/thinking batches resync the transcript; tool updates render the preview only.
  @spec transcript_affecting_batch?([term()]) :: boolean()
  defp transcript_affecting_batch?(batch) do
    Enum.any?(batch, fn
      {:text_delta, _} -> true
      {:thinking_delta, _} -> true
      _ -> false
    end)
  end

  @spec sync_active_tool_name(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp sync_active_tool_name(state, fallback_name) do
    case AgentAccess.session(state) do
      pid when is_pid(pid) ->
        case session_active_tool_name(pid) do
          {:ok, active_tool_name} ->
            AgentAccess.update_agent(
              state,
              &AgentState.set_active_tool_name(&1, active_tool_name)
            )

          :error ->
            apply_active_tool_name_fallback(state, fallback_name)
        end

      _ ->
        apply_active_tool_name_fallback(state, fallback_name)
    end
  end

  @spec apply_active_tool_name_fallback(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp apply_active_tool_name_fallback(state, name) when is_binary(name) do
    AgentAccess.update_agent(state, &AgentState.set_active_tool_name(&1, name))
  end

  defp apply_active_tool_name_fallback(state, _name) do
    AgentAccess.update_agent(state, &AgentState.clear_active_tool_name/1)
  end

  @spec restore_queued_prompts_after_error(EditorState.t()) :: EditorState.t()
  defp restore_queued_prompts_after_error(state) do
    case AgentAccess.session(state) do
      session when is_pid(session) ->
        {steering, follow_up} = safe_recall_queues(session)
        restore_queued_to_prompt(state, steering ++ follow_up)

      _session ->
        state
    end
  end

  @spec safe_recall_queues(pid()) ::
          {[String.t() | [ReqLLM.Message.ContentPart.t()]],
           [String.t() | [ReqLLM.Message.ContentPart.t()]]}
  defp safe_recall_queues(session) do
    Session.recall_queues(session)
  catch
    :exit, _ -> {[], []}
  end

  @spec restore_queued_to_prompt(
          EditorState.t(),
          [String.t() | [ReqLLM.Message.ContentPart.t()]]
        ) :: EditorState.t()
  defp restore_queued_to_prompt(state, []), do: state

  defp restore_queued_to_prompt(state, all_queued) do
    current_text = UIState.prompt_text(AgentAccess.agent_ui(state))
    combined = Session.combine_queue_entries_to_text(all_queued)

    restored =
      if current_text != "",
        do: combined <> "\n\n" <> current_text,
        else: combined

    AgentAccess.update_agent_ui(state, &UIState.set_prompt_text(&1, restored))
  end

  @spec session_active_tool_name(pid()) :: {:ok, String.t() | nil} | :error
  defp session_active_tool_name(pid) do
    {:ok, Session.editor_snapshot(pid).active_tool_name}
  catch
    :exit, _ -> :error
  end

  @spec reload_remote_buffer_if_open(EditorState.t(), String.t(), String.t()) ::
          {EditorState.t(), [effect()]}
  defp reload_remote_buffer_if_open(state, path, after_content) do
    case current_remote_target(state) do
      {:ok, server_name, remote_node} ->
        reload_remote_buffer(
          state,
          server_name,
          normalize_remote_path(remote_node, path),
          after_content
        )

      :error ->
        reload_tracked_remote_buffers(state, path, after_content)
    end
  end

  @spec current_remote_target(EditorState.t()) :: {:ok, String.t(), node()} | :error
  defp current_remote_target(state) do
    case AgentAccess.session(state) do
      pid when is_pid(pid) and node(pid) != node() ->
        remote_node = node(pid)

        case Minga.Distribution.ConnectionManager.server_name_for_node(remote_node) do
          {:ok, server_name} -> {:ok, server_name, remote_node}
          {:error, :not_found} -> :error
        end

      _ ->
        :error
    end
  end

  @spec normalize_remote_path(node(), String.t()) :: String.t()
  defp normalize_remote_path(remote_node, path) do
    :erpc.call(remote_node, Path, :expand, [path], 5_000)
  catch
    :exit, _reason -> path
    :error, {:erpc, _reason} -> path
  end

  @spec reload_tracked_remote_buffers(EditorState.t(), String.t(), String.t()) ::
          {EditorState.t(), [effect()]}
  defp reload_tracked_remote_buffers(state, path, after_content) do
    state.remote
    |> matching_remote_buffers(path)
    |> Enum.reduce({state, []}, fn {_server_name, remote_path, pid}, {acc_state, acc_effects} ->
      {new_state, effects} =
        reload_remote_buffer_content(acc_state, pid, remote_path, after_content)

      {new_state, effects ++ acc_effects}
    end)
  end

  @spec matching_remote_buffers(Remote.t(), String.t()) :: [{String.t(), String.t(), pid()}]
  defp matching_remote_buffers(remote, path) do
    {direct_matches, fallback_candidates} =
      remote
      |> Remote.all_buffers()
      |> Enum.split_with(fn {_server_name, remote_path, _pid} -> remote_path == path end)

    fallback_matches =
      fallback_candidates
      |> Enum.group_by(fn {server_name, _remote_path, _pid} -> server_name end)
      |> Enum.flat_map(fn {server_name, buffers} ->
        normalized_path = normalize_remote_path_for_server(server_name, path, buffers)

        Enum.filter(buffers, fn {_server_name, remote_path, _pid} ->
          remote_path == normalized_path
        end)
      end)

    direct_matches ++ fallback_matches
  end

  @spec normalize_remote_path_for_server(String.t(), String.t(), [{String.t(), String.t(), pid()}]) ::
          String.t()
  defp normalize_remote_path_for_server(server_name, path, buffers) do
    case remote_node_for_server(server_name, buffers) do
      {:ok, remote_node} -> normalize_remote_path(remote_node, path)
      :error -> path
    end
  end

  @spec remote_node_for_server(String.t(), [{String.t(), String.t(), pid()}]) ::
          {:ok, node()} | :error
  defp remote_node_for_server(server_name, buffers) do
    case ConnectionManager.node_for_server(server_name) do
      {:ok, remote_node} -> {:ok, remote_node}
      {:error, _reason} -> remote_node_from_buffers(buffers)
    end
  catch
    :exit, _reason -> remote_node_from_buffers(buffers)
  end

  @spec remote_node_from_buffers([{String.t(), String.t(), pid()}]) :: {:ok, node()} | :error
  defp remote_node_from_buffers([{_server_name, _remote_path, pid} | _rest]) do
    case Buffer.storage(pid) do
      {:remote, remote_node, _base_path} -> {:ok, remote_node}
      _ -> :error
    end
  catch
    :exit, _reason -> :error
  end

  defp remote_node_from_buffers([]), do: :error

  @spec reload_remote_buffer(EditorState.t(), String.t(), String.t(), String.t()) ::
          {EditorState.t(), [effect()]}
  defp reload_remote_buffer(state, server_name, path, after_content) do
    case Remote.buffer(state.remote, server_name, path) do
      pid when is_pid(pid) ->
        reload_remote_buffer_content(state, pid, path, after_content)

      _ ->
        {state, []}
    end
  catch
    :exit, reason ->
      {state,
       [{:log, :agent, :error, "Failed to reload remote file #{path}: #{inspect(reason)}"}]}
  end

  @spec reload_remote_buffer_content(EditorState.t(), pid(), String.t(), String.t()) ::
          {EditorState.t(), [effect()]}
  defp reload_remote_buffer_content(state, pid, path, after_content) do
    if Buffer.dirty?(pid) do
      state =
        state
        |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          "Agent modified this file. Reload, keep editing, or show diff. Save will check for conflicts."
        )
        |> PickerUI.open(MingaEditor.UI.Picker.RemoteFileConflictSource, %{
          buffer: pid,
          path: path,
          content: after_content
        })

      {state, [{:log_warning, "Agent modified dirty remote file #{Path.basename(path)}"}]}
    else
      Buffer.accept_saved_content(pid, after_content)
      {state, [{:log_message, "Agent updated #{Path.basename(path)}"}]}
    end
  end

  @spec add_file_changed_message(EditorState.t(), String.t(), String.t()) :: EditorState.t()
  defp add_file_changed_message(state, path, tool_name) do
    case AgentAccess.session(state) do
      pid when is_pid(pid) ->
        short_path = shorten_to_relative(state, path)
        verb = file_change_verb(tool_name)
        Session.add_system_message(pid, "#{verb} #{short_path}")
        state

      _ ->
        state
    end
  catch
    :exit, _ -> state
  end

  @spec file_change_verb(String.t()) :: String.t()
  defp file_change_verb("write"), do: "Wrote"
  defp file_change_verb("edit"), do: "Edited"
  defp file_change_verb(_tool_name), do: "Modified"

  @spec shorten_to_relative(EditorState.t(), String.t()) :: String.t()
  defp shorten_to_relative(state, path) do
    case project_root(state) do
      root when is_binary(root) -> Path.relative_to(path, root)
      _ -> Path.basename(path)
    end
  end

  @spec update_preview(EditorState.t(), (Preview.t() -> Preview.t())) :: EditorState.t()
  defp update_preview(state, fun) do
    AgentAccess.update_agent_ui(state, &UIState.update_preview(&1, fun))
  end

  @spec existing_diff_for_path(EditorState.t(), String.t()) :: DiffReview.t() | nil
  defp existing_diff_for_path(state, path) do
    case Preview.diff_review(AgentAccess.view(state).preview) do
      %DiffReview{path: ^path} = review -> review
      _ -> nil
    end
  end

  @spec sync_active_shell_agent_status(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp sync_active_shell_agent_status(state, status),
    do: update_shell_for_active_session(state, :sync_agent_status, [status])

  @spec track_active_shell_agent_file(EditorState.t(), String.t()) :: EditorState.t()
  defp track_active_shell_agent_file(state, path),
    do: update_shell_for_active_session(state, :track_agent_file, [path])

  @spec update_shell_for_active_session(EditorState.t() | map(), atom(), [term()]) ::
          EditorState.t() | map()
  defp update_shell_for_active_session(%EditorState{} = state, callback, args) do
    state = Workflow.ensure_available(state)
    session = Runtime.active_session(state.shell_runtime)
    update_shell_for_session(state, callback, session, args)
  end

  defp update_shell_for_active_session(state, _callback, _args), do: state

  @spec update_shell_for_session(EditorState.t(), atom(), pid() | nil, [term()]) ::
          EditorState.t()
  defp update_shell_for_session(state, _callback, session, _args) when not is_pid(session),
    do: state

  defp update_shell_for_session(state, :sync_agent_status, session, [status]) do
    runtime =
      Runtime.sync_agent_status(
        state.shell_runtime,
        Workflow.resolved_entries(),
        session,
        status
      )

    EditorState.apply_shell_runtime_transition(state, runtime)
  end

  defp update_shell_for_session(state, :track_agent_file, session, [path]) do
    runtime =
      Runtime.track_agent_file(
        state.shell_runtime,
        Workflow.resolved_entries(),
        session,
        path
      )

    EditorState.apply_shell_runtime_transition(state, runtime)
  end

  # Syncs the agent_status field on the current agent tab so the tab bar
  # can render status indicators without querying the Session process.
  @spec sync_tab_agent_status(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp sync_tab_agent_status(%{shell_runtime: %{state: %{tab_bar: nil}}} = state, _status),
    do: state

  defp sync_tab_agent_status(state, status) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      tb = EditorState.tab_bar(state)

      tb =
        case TabBar.find_workspace_by_session(tb, session) do
          %Workspace{id: ws_id} ->
            TabBar.update_workspace(tb, ws_id, &Workspace.set_agent_status(&1, status))

          nil ->
            tb
        end

      tb =
        case TabBar.find_by_session(tb, session) do
          %Tab{id: id} -> TabBar.update_tab(tb, id, &Tab.set_agent_status(&1, status))
          nil -> tb
        end

      EditorState.set_tab_bar(state, tb)
    else
      state
    end
  end

  # Associates a file tab with the agent's workspace when the agent modifies the file.
  # Uses the tab's logical file ref so duplicate basenames route to the exact file.
  @spec associate_file_with_agent_workspace(EditorState.t(), String.t()) :: EditorState.t()
  defp associate_file_with_agent_workspace(
         %{shell_runtime: %{state: %{tab_bar: nil}}} = state,
         _path
       ),
       do: state

  defp associate_file_with_agent_workspace(state, path) do
    session = AgentAccess.session(state)
    tb = EditorState.tab_bar(state)

    with pid when is_pid(pid) <- session,
         {:ok, file_ref} <- file_ref_for_path(state, path),
         %Workspace{id: ws_id} <- TabBar.find_workspace_by_session(tb, pid),
         %Tab{id: tab_id} <- find_unassociated_file_tab(tb, file_ref, ws_id, state) do
      tb =
        tb
        |> TabBar.move_tab_to_workspace(tab_id, ws_id)
        |> TabBar.update_workspace(ws_id, fn workspace ->
          Workspace.retarget_file(workspace, nil, file_ref, tab_id == tb.active_id)
        end)

      EditorState.set_tab_bar(state, tb)
    else
      _ -> state
    end
  end

  # Auto-names the agent workspace from the prompt text (first line, 30 chars).
  # Skips if the workspace has a custom name set by the user.
  @spec maybe_auto_name_workspace(EditorState.t(), String.t()) :: EditorState.t()
  defp maybe_auto_name_workspace(%{shell_runtime: %{state: %{tab_bar: nil}}} = state, _),
    do: state

  defp maybe_auto_name_workspace(state, prompt) do
    session = AgentAccess.session(state)
    tb = EditorState.tab_bar(state)

    with pid when is_pid(pid) <- session,
         %Workspace{} = ws <- TabBar.find_workspace_by_session(tb, pid) do
      maybe_apply_auto_name(state, ws, prompt)
    else
      _ -> state
    end
  end

  @spec maybe_apply_auto_name(EditorState.t(), Workspace.t(), String.t()) :: EditorState.t()
  defp maybe_apply_auto_name(state, ws, prompt) do
    updated_ws = Workspace.auto_name(ws, prompt)

    if updated_ws.label != ws.label do
      tb = EditorState.tab_bar(state)
      EditorState.set_tab_bar(state, TabBar.update_workspace(tb, ws.id, fn _ -> updated_ws end))
    else
      state
    end
  end

  @spec file_ref_for_path(EditorState.t(), String.t()) :: {:ok, FileRef.t()} | {:error, term()}
  defp file_ref_for_path(state, path) do
    case project_root(state) do
      root when is_binary(root) -> FileRef.from_path(root, path)
      _ -> {:error, :missing_project_root}
    end
  end

  @spec project_root(EditorState.t()) :: String.t() | nil
  defp project_root(state), do: EditorState.file_tree_state(state).project_root

  @spec find_unassociated_file_tab(TabBar.t(), FileRef.t(), non_neg_integer(), EditorState.t()) ::
          Tab.t() | nil
  defp find_unassociated_file_tab(tb, %FileRef{} = file_ref, ws_id, state) do
    Enum.find(tb.tabs, fn tab ->
      tab.kind == :file and tab.group_id != ws_id and
        FileRef.equal?(tab_file_ref(tab, state), file_ref)
    end)
  end

  @spec tab_file_ref(Tab.t(), EditorState.t()) :: FileRef.t() | nil
  defp tab_file_ref(%Tab{file_ref: %FileRef{} = file_ref}, _state), do: file_ref

  defp tab_file_ref(%Tab{context: context}, state) do
    with %{buffers: %Buffers{active: buffer}} when is_pid(buffer) <-
           TabContext.to_workspace_map(context),
         path when is_binary(path) <- safe_buffer_path(buffer),
         root when is_binary(root) <- project_root(state),
         {:ok, file_ref} <- FileRef.from_path(root, path) do
      file_ref
    else
      _ -> nil
    end
  end

  @spec maybe_rename_workspace_from_assistant(EditorState.t()) :: EditorState.t()
  defp maybe_rename_workspace_from_assistant(state) do
    with pid when is_pid(pid) <- AgentAccess.session(state),
         %Workspace{custom_name: nil} = ws <-
           TabBar.find_workspace_by_session(EditorState.tab_bar(state), pid),
         text when is_binary(text) <- first_assistant_opening(safe_messages(pid)),
         candidate = String.slice(text, 0, 30) |> String.trim(),
         true <- candidate != "" and candidate != ws.label do
      maybe_apply_auto_name(state, ws, text)
    else
      _ -> state
    end
  rescue
    _ -> state
  end

  @spec first_assistant_opening([term()]) :: String.t() | nil
  defp first_assistant_opening(messages) do
    Enum.find_value(messages, fn
      {:assistant, text} when is_binary(text) and text != "" ->
        text |> String.split("\n") |> hd() |> String.trim()

      _ ->
        nil
    end)
  end

  @spec safe_messages(pid()) :: [term()]
  defp safe_messages(pid) do
    Session.messages(pid)
  catch
    :exit, _ -> []
  end

  @spec reset_compact_state(EditorState.t()) :: EditorState.t()
  defp reset_compact_state(state) do
    AgentAccess.update_view(state, fn v ->
      %{v | compact_warned: false, compact_triggered: false}
    end)
  rescue
    _ -> state
  end

  @spec maybe_auto_compact(EditorState.t(), non_neg_integer(), non_neg_integer() | nil) ::
          {EditorState.t(), [effect()]}
  defp maybe_auto_compact(state, _estimated_tokens, nil), do: {state, []}
  defp maybe_auto_compact(state, _estimated_tokens, 0), do: {state, []}

  defp maybe_auto_compact(state, estimated_tokens, context_limit) do
    fill_pct = min(round(estimated_tokens / context_limit * 100), 100)
    view = AgentAccess.view(state)
    agent_status = AgentAccess.agent(state).runtime.status
    compact_when_ready(state, view, agent_status, fill_pct)
  end

  @spec compact_when_ready(EditorState.t(), term(), AgentState.status(), non_neg_integer()) ::
          {EditorState.t(), [effect()]}
  defp compact_when_ready(state, _view, status, fill_pct)
       when status in [:thinking, :tool_executing] do
    state = AgentAccess.update_view(state, &%{&1 | compact_pending_fill_pct: fill_pct})
    {state, []}
  end

  defp compact_when_ready(state, %{compaction_in_progress: true}, _status, _fill_pct),
    do: {state, []}

  defp compact_when_ready(state, view, _status, fill_pct),
    do: apply_compact_threshold(state, view, fill_pct)

  @spec maybe_apply_pending_auto_compact(EditorState.t(), term(), [effect()]) ::
          {EditorState.t(), [effect()]}
  defp maybe_apply_pending_auto_compact(state, :idle, effects) do
    case AgentAccess.view(state).compact_pending_fill_pct do
      nil ->
        {state, effects}

      fill_pct ->
        state = AgentAccess.update_view(state, &%{&1 | compact_pending_fill_pct: nil})

        {state, compact_effects} =
          apply_compact_threshold(state, AgentAccess.view(state), fill_pct)

        {state, effects ++ compact_effects}
    end
  end

  defp maybe_apply_pending_auto_compact(state, _status, effects), do: {state, effects}

  @spec apply_compact_threshold(EditorState.t(), term(), non_neg_integer()) ::
          {EditorState.t(), [effect()]}
  defp apply_compact_threshold(state, view, fill_pct) do
    compact_threshold_result(
      state,
      view,
      fill_pct,
      compact_auto_threshold(),
      compact_warn_threshold()
    )
  end

  @spec compact_threshold_result(
          EditorState.t(),
          term(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {EditorState.t(), [effect()]}
  defp compact_threshold_result(state, %{compact_triggered: false}, fill_pct, auto_pct, _warn_pct)
       when auto_pct > 0 and fill_pct >= auto_pct,
       do: trigger_auto_compact(state)

  defp compact_threshold_result(state, %{compact_warned: false}, fill_pct, _auto_pct, warn_pct)
       when warn_pct > 0 and fill_pct >= warn_pct,
       do: warn_context_pressure(state, fill_pct)

  defp compact_threshold_result(state, _view, _fill_pct, _auto_pct, _warn_pct), do: {state, []}

  @spec trigger_auto_compact(EditorState.t()) :: {EditorState.t(), [effect()]}
  defp trigger_auto_compact(state) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      state =
        AgentAccess.update_view(state, fn v ->
          %{v | compact_triggered: true, compaction_in_progress: true}
        end)

      {state, [{:compact_session, session}]}
    else
      {state, []}
    end
  end

  @spec warn_context_pressure(EditorState.t(), non_neg_integer()) ::
          {EditorState.t(), [effect()]}
  defp warn_context_pressure(state, fill_pct) do
    state = AgentAccess.update_view(state, fn v -> %{v | compact_warned: true} end)

    state =
      AgentAccess.update_agent_ui(state, fn ui ->
        UIState.push_toast(ui, "Context at #{fill_pct}%. Run /compact to free space.", :warning)
      end)

    {state, []}
  end

  @spec compact_warn_threshold() :: non_neg_integer()
  defp compact_warn_threshold do
    case Minga.Config.Options.get(:agent_compaction_threshold) do
      nil -> 0
      threshold when is_number(threshold) -> round(threshold * 100)
      _ -> 80
    end
  end

  @spec compact_auto_threshold() :: non_neg_integer()
  defp compact_auto_threshold do
    warn = compact_warn_threshold()
    if warn > 0, do: min(warn + 10, 100), else: 0
  end

  @spec safe_buffer_path(pid()) :: String.t() | nil
  defp safe_buffer_path(buffer) when is_pid(buffer) do
    Buffer.file_path(buffer)
  catch
    :exit, _ -> nil
  end

  @doc false
  @spec replay_catchup(EditorState.t(), [MingaAgent.EventLog.EventRecord.t()]) :: EditorState.t()
  def replay_catchup(state, events) do
    events
    |> Enum.map(&event_record_to_editor_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(state, &replay_one_catchup_event/2)
  end

  @spec replay_one_catchup_event(term(), EditorState.t()) :: EditorState.t()
  defp replay_one_catchup_event({:file_changed, path, _, _, tool_call_id, _} = event, state) do
    if catchup_already_applied?(state, path, tool_call_id),
      do: state,
      else: elem(handle(state, event), 0)
  end

  defp replay_one_catchup_event(event, state), do: elem(handle(state, event), 0)

  @spec catchup_already_applied?(EditorState.t(), String.t(), String.t()) :: boolean()
  defp catchup_already_applied?(state, path, tool_call_id) do
    state
    |> AgentAccess.view()
    |> Map.get(:edit_timeline)
    |> EditTimeline.entries_for(path)
    |> Enum.any?(&(&1.tool_call_id == tool_call_id))
  end

  @spec event_record_to_editor_event(MingaAgent.EventLog.EventRecord.t()) :: term() | nil
  defp event_record_to_editor_event(%{event_type: :file_edit_proposed, payload: payload}) do
    {:file_changed, payload["path"], payload["before_content"], payload["after_content"],
     payload["tool_call_id"], payload["tool_name"]}
  end

  defp event_record_to_editor_event(%{event_type: :todo_plan_updated, payload: payload}) do
    {:todo_plan_updated, todo_items_from_payload(Map.get(payload, "todos", []))}
  end

  defp event_record_to_editor_event(%{event_type: :tool_call_started, payload: payload}) do
    {:tool_started, payload_string(payload, "tool_call_id"), payload_string(payload, "name"),
     payload_map(payload, "args")}
  end

  defp event_record_to_editor_event(%{event_type: :tool_call_finished, payload: payload}) do
    {:tool_ended, payload_string(payload, "tool_call_id"), payload_string(payload, "name"),
     payload_string(payload, "result"), payload_status(payload)}
  end

  defp event_record_to_editor_event(%{event_type: :tool_call_interrupted, payload: payload}) do
    {:tool_interrupted, payload_string(payload, "tool_call_id")}
  end

  defp event_record_to_editor_event(_event), do: nil

  @spec todo_items_from_payload(term()) :: [MingaAgent.TodoItem.t()]
  defp todo_items_from_payload(items) when is_list(items) do
    Enum.flat_map(items, fn
      %{} = item ->
        case todo_item_from_payload(item) do
          nil -> []
          todo -> [todo]
        end

      _ ->
        []
    end)
  end

  defp todo_items_from_payload(_items), do: []

  @spec todo_item_from_payload(map()) :: MingaAgent.TodoItem.t() | nil
  defp todo_item_from_payload(item) do
    id = payload_string(item, "id")
    description = payload_string(item, "description")

    if id != "" and description != "" do
      %MingaAgent.TodoItem{
        id: id,
        description: description,
        status: todo_status_payload(item)
      }
    end
  end

  @spec todo_status_payload(map()) :: MingaAgent.TodoItem.status()
  defp todo_status_payload(item) do
    case payload_string(item, "status") do
      "in_progress" -> :in_progress
      "done" -> :done
      _ -> :pending
    end
  end

  @spec payload_map(map(), String.t()) :: map()
  defp payload_map(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  @spec payload_string(map(), String.t()) :: String.t()
  defp payload_string(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      nil -> ""
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  @spec payload_status(map()) :: :done | :error
  defp payload_status(payload) do
    case payload_string(payload, "status") do
      "done" -> :done
      _ -> :error
    end
  end
end
