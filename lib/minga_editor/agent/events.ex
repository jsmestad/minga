defmodule MingaEditor.Agent.Events do
  @moduledoc """
  Handles agent session events, updating EditorState directly.

  Agent events (status changes, deltas, tool activity, errors) arrive
  from the agent session process. Each handler reads and writes the
  `agent` and `agentic` fields on EditorState through AgentAccess,
  returning the updated state and a list of effects for the Editor
  GenServer to apply.
  """

  alias Minga.Distribution.ConnectionManager
  alias Minga.Project.FileRef
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.View.Preview
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

  @type effect ::
          :render
          | {:render, pos_integer()}
          | {:log_message, String.t()}
          | {:log_warning, String.t()}
          | :sync_agent_buffer
          | {:update_tab_label, String.t()}

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
          AgentAccess.update_agent(state, &AgentState.start_spinner_timer/1)

        _ ->
          AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)
      end

    # Sync the tab's agent_status for tab bar rendering
    state = sync_tab_agent_status(state, status)

    # Sync Board card status if Board shell is active
    state = sync_board_card_status(state, status)

    {state, [:render | effects]}
  end

  # Text deltas use a 1ms render delay so streaming text appears with
  # minimal latency. The throttle guard in schedule_render coalesces
  # multiple deltas arriving in the same millisecond into one render.
  def handle(state, {:text_delta, _delta}) do
    state = AgentAccess.update_agent_ui(state, &UIState.maybe_auto_scroll/1)
    state = AgentAccess.update_panel(state, &Panel.bump_message_version/1)
    {state, [{:render, 1}, :sync_agent_buffer]}
  end

  def handle(state, {:thinking_delta, _delta}) do
    state = AgentAccess.update_agent_ui(state, &UIState.maybe_auto_scroll/1)
    state = AgentAccess.update_panel(state, &Panel.bump_message_version/1)
    {state, [{:render, 50}, :sync_agent_buffer]}
  end

  def handle(state, :messages_changed) do
    state = AgentAccess.update_agent_ui(state, &UIState.maybe_auto_scroll/1)
    state = AgentAccess.update_panel(state, &Panel.bump_message_version/1)
    {state, [{:render, 16}, :sync_agent_buffer, {:update_tab_label, ""}]}
  end

  def handle(state, {:tool_started, "shell", args}) do
    command = Map.get(args, "command", "")
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

  def handle(state, {:tool_ended, "shell", result, status}) do
    shell_status = if status == :error, do: :error, else: :done
    state = sync_active_tool_name(state, nil)
    state = update_preview(state, &Preview.finish_shell(&1, result, shell_status))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_started, "read_file", args}) do
    path = Map.get(args, "path", "")
    state = sync_active_tool_name(state, "read_file")
    state = update_preview(state, &Preview.set_file(&1, path, ""))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_ended, "read_file", result, _status}) do
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

    state = sync_active_tool_name(state, "list_directory")
    state = update_preview(state, &Preview.set_directory(&1, path, []))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_ended, "list_directory", result, _status}) do
    entries = result |> String.split("\n") |> Enum.reject(&(&1 == ""))
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
    state = sync_active_tool_name(state, name)
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_ended, _name, _result, _status}) do
    state = sync_active_tool_name(state, nil)
    {state, [{:render, 16}]}
  end

  def handle(state, {:file_changed, path, before_content, after_content, tool_call_id, tool_name}) do
    {state, remote_effects} = reload_remote_buffer_if_open(state, path, after_content)

    state =
      AgentAccess.update_agent_ui(state, &UIState.record_baseline(&1, path, before_content))

    state =
      AgentAccess.update_view(state, fn view ->
        %{
          view
          | edit_timeline:
              EditTimeline.record_edit(
                view.edit_timeline,
                path,
                tool_call_id,
                tool_name,
                before_content,
                after_content
              )
        }
      end)

    # Track the file on the Board card for recent_files display
    state = track_board_card_file(state, path)

    # Associate the file's tab with the agent's workspace
    state = associate_file_with_agent_workspace(state, path)

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

    # Unfocus the prompt input so the ToolApproval input handler can
    # intercept y/n keys. The user needs to see and respond to the
    # approval prompt, not keep typing in the input field.
    state = AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, false))

    {state, [:render, :sync_agent_buffer]}
  end

  def handle(state, {:approval_resolved, _decision}) do
    state = AgentAccess.update_agent(state, &AgentState.clear_pending_approval/1)
    {state, [{:render, 16}, :sync_agent_buffer]}
  end

  def handle(state, {:error, message}) do
    state = AgentAccess.update_agent(state, &AgentState.set_error(&1, message))
    {state, [:render, {:log_warning, "Agent error: #{message}"}]}
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

  def handle(state, {:context_usage, estimated_tokens, _context_limit}) do
    state =
      AgentAccess.update_view(state, fn v -> %{v | context_estimate: estimated_tokens} end)

    {state, [{:render, 16}]}
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

  # ── Private ────────────────────────────────────────────────────────────────

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
      {state, [{:log_warning, "Failed to reload remote file #{path}: #{inspect(reason)}"}]}
  end

  @spec reload_remote_buffer_content(EditorState.t(), pid(), String.t(), String.t()) ::
          {EditorState.t(), [effect()]}
  defp reload_remote_buffer_content(state, pid, path, after_content) do
    if Buffer.dirty?(pid) do
      state =
        state
        |> EditorState.set_status(
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

  # Syncs Board card status when an agent status changes. Finds the card
  # by matching the agent session PID and updates the card's status badge.
  @spec sync_board_card_status(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp sync_board_card_status(%{shell: MingaEditor.Shell.Board} = state, status) do
    session = AgentAccess.session(state)

    if session do
      update_board_card_by_session(state, session, fn card ->
        MingaEditor.Shell.Board.Card.set_status(
          card,
          MingaEditor.Shell.Board.Card.from_agent_status(status)
        )
      end)
    else
      state
    end
  end

  defp sync_board_card_status(state, _status), do: state

  # Tracks a file path on the Board card associated with the current agent session.
  # Keeps the 5 most recently touched files for the card footer display.
  @spec track_board_card_file(EditorState.t(), String.t()) :: EditorState.t()
  defp track_board_card_file(%{shell: MingaEditor.Shell.Board} = state, path) do
    session = AgentAccess.session(state)

    if session do
      short_path = Path.basename(path)

      update_board_card_by_session(state, session, fn card ->
        files = [short_path | Enum.reject(card.recent_files, &(&1 == short_path))]
        MingaEditor.Shell.Board.Card.set_recent_files(card, Enum.take(files, 5))
      end)
    else
      state
    end
  end

  defp track_board_card_file(state, _path), do: state

  # Finds a Board card by agent session PID and applies an update function.
  @spec update_board_card_by_session(EditorState.t(), pid(), (MingaEditor.Shell.Board.Card.t() ->
                                                                MingaEditor.Shell.Board.Card.t())) ::
          EditorState.t()
  defp update_board_card_by_session(state, session, update_fn) do
    board = state.shell_state

    case Enum.find(board.cards, fn {_id, card} -> card.session == session end) do
      {card_id, _card} ->
        new_board = MingaEditor.Shell.Board.State.update_card(board, card_id, update_fn)
        %{state | shell_state: new_board}

      nil ->
        state
    end
  end

  # Syncs the agent_status field on the current agent tab so the tab bar
  # can render status indicators without querying the Session process.
  @spec sync_tab_agent_status(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp sync_tab_agent_status(%{shell_state: %{tab_bar: nil}} = state, _status), do: state

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
  defp associate_file_with_agent_workspace(%{shell_state: %{tab_bar: nil}} = state, _path),
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
  defp maybe_auto_name_workspace(%{shell_state: %{tab_bar: nil}} = state, _), do: state

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
  defp project_root(%{workspace: %{file_tree: %{project_root: root}}}), do: root

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

  @spec safe_buffer_path(pid()) :: String.t() | nil
  defp safe_buffer_path(buffer) when is_pid(buffer) do
    Buffer.file_path(buffer)
  catch
    :exit, _ -> nil
  end
end
