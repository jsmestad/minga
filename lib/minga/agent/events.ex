defmodule Minga.Agent.Events do
  @moduledoc """
  Handles agent session events, updating EditorState directly.

  Agent events (status changes, deltas, tool activity, errors) arrive
  from the agent session process. Each handler reads and writes the
  `agent` and `agentic` fields on EditorState through AgentAccess,
  returning the updated state and a list of effects for the Editor
  GenServer to apply.
  """

  alias Minga.Agent.DiffReview
  alias Minga.Agent.UIState
  alias Minga.Agent.UIState.Panel
  alias Minga.Agent.View.Preview
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.AgentGroup
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar

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
    {state, [{:render, 1}, :sync_agent_buffer]}
  end

  def handle(state, {:thinking_delta, _delta}) do
    state = AgentAccess.update_agent_ui(state, &UIState.maybe_auto_scroll/1)
    {state, [{:render, 50}, :sync_agent_buffer]}
  end

  def handle(state, :messages_changed) do
    state = AgentAccess.update_agent_ui(state, &UIState.maybe_auto_scroll/1)
    state = AgentAccess.update_panel(state, &Panel.bump_message_version/1)
    {state, [{:render, 16}, :sync_agent_buffer, {:update_tab_label, ""}]}
  end

  def handle(state, {:tool_started, "shell", args}) do
    command = Map.get(args, "command", "")
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
    state = update_preview(state, &Preview.finish_shell(&1, result, shell_status))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_started, "read_file", args}) do
    path = Map.get(args, "path", "")
    state = update_preview(state, &Preview.set_file(&1, path, ""))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_ended, "read_file", result, _status}) do
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
    state = update_preview(state, &Preview.set_directory(&1, path, []))
    {state, [{:render, 16}]}
  end

  def handle(state, {:tool_ended, "list_directory", result, _status}) do
    entries = result |> String.split("\n") |> Enum.reject(&(&1 == ""))

    case AgentAccess.view(state).preview.content do
      {:directory, path, _} ->
        state = update_preview(state, &Preview.set_directory(&1, path, entries))
        {state, [{:render, 16}]}

      _ ->
        {state, []}
    end
  end

  def handle(state, {:tool_started, _name, _args}) do
    {state, []}
  end

  def handle(state, {:tool_ended, _name, _result, _status}) do
    {state, []}
  end

  def handle(state, {:file_changed, path, before_content, after_content}) do
    state =
      AgentAccess.update_agent_ui(state, &UIState.record_baseline(&1, path, before_content))

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
        {state, [{:render, 16}]}

      _ ->
        state = update_preview(state, &Preview.set_diff(&1, review))
        state = AgentAccess.update_agent_ui(state, &UIState.set_focus(&1, :file_viewer))
        {state, [:render]}
    end
  end

  def handle(state, {:approval_pending, approval}) do
    cached = Map.take(approval, [:tool_call_id, :name, :args])
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
  defp sync_board_card_status(%{shell: Minga.Shell.Board} = state, status) do
    session = AgentAccess.session(state)
    board = state.shell_state

    if session do
      card_status = agent_status_to_card_status(status)

      # Find the card with this session PID
      case Enum.find(board.cards, fn {_id, card} -> card.session == session end) do
        {card_id, _card} ->
          new_board =
            Minga.Shell.Board.State.update_card(board, card_id, fn card ->
              Minga.Shell.Board.Card.set_status(card, card_status)
            end)

          %{state | shell_state: new_board}

        nil ->
          state
      end
    else
      state
    end
  end

  defp sync_board_card_status(state, _status), do: state

  # Tracks a file path on the Board card associated with the current agent session.
  # Keeps the 5 most recently touched files for the card footer display.
  @spec track_board_card_file(EditorState.t(), String.t()) :: EditorState.t()
  defp track_board_card_file(%{shell: Minga.Shell.Board} = state, path) do
    session = AgentAccess.session(state)
    board = state.shell_state

    if session do
      case Enum.find(board.cards, fn {_id, card} -> card.session == session end) do
        {card_id, _card} ->
          short_path = Path.basename(path)

          new_board =
            Minga.Shell.Board.State.update_card(board, card_id, fn card ->
              files = [short_path | Enum.reject(card.recent_files, &(&1 == short_path))]
              Minga.Shell.Board.Card.set_recent_files(card, Enum.take(files, 5))
            end)

          %{state | shell_state: new_board}

        nil ->
          state
      end
    else
      state
    end
  end

  defp track_board_card_file(state, _path), do: state

  @spec agent_status_to_card_status(Tab.agent_status()) :: Minga.Shell.Board.Card.status()
  defp agent_status_to_card_status(:thinking), do: :working
  defp agent_status_to_card_status(:tool_executing), do: :iterating
  defp agent_status_to_card_status(:error), do: :errored
  defp agent_status_to_card_status(:idle), do: :done
  defp agent_status_to_card_status(_), do: :idle

  # Syncs the agent_status field on the current agent tab so the tab bar
  # can render status indicators without querying the Session process.
  @spec sync_tab_agent_status(EditorState.t(), Tab.agent_status()) :: EditorState.t()
  defp sync_tab_agent_status(%{shell_state: %{tab_bar: nil}} = state, _status), do: state

  defp sync_tab_agent_status(state, status) do
    session = AgentAccess.session(state)

    case session && TabBar.find_by_session(EditorState.tab_bar(state), session) do
      %Tab{id: id} ->
        tb = TabBar.update_tab(EditorState.tab_bar(state), id, &Tab.set_agent_status(&1, status))
        # Also sync workspace agent status
        tb =
          case TabBar.find_group_by_session(tb, session) do
            %AgentGroup{id: ws_id} ->
              TabBar.update_group(tb, ws_id, &AgentGroup.set_agent_status(&1, status))

            nil ->
              tb
          end

        EditorState.set_tab_bar(state, tb)

      _ ->
        state
    end
  end

  # Associates a file tab with the agent's workspace when the agent
  # modifies the file. Finds the file tab by label match, then moves
  # it to the agent session's workspace group.
  @spec associate_file_with_agent_workspace(EditorState.t(), String.t()) :: EditorState.t()
  defp associate_file_with_agent_workspace(%{shell_state: %{tab_bar: nil}} = state, _path),
    do: state

  defp associate_file_with_agent_workspace(state, path) do
    session = AgentAccess.session(state)
    tb = EditorState.tab_bar(state)

    with pid when is_pid(pid) <- session,
         %AgentGroup{id: ws_id} <- TabBar.find_group_by_session(tb, pid),
         %Tab{id: tab_id} <- find_unassociated_file_tab(tb, path, ws_id) do
      EditorState.set_tab_bar(state, TabBar.move_tab_to_group(tb, tab_id, ws_id))
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
         %AgentGroup{} = ws <- TabBar.find_group_by_session(tb, pid) do
      maybe_apply_auto_name(state, ws, prompt)
    else
      _ -> state
    end
  end

  @spec maybe_apply_auto_name(EditorState.t(), AgentGroup.t(), String.t()) :: EditorState.t()
  defp maybe_apply_auto_name(state, ws, prompt) do
    updated_ws = AgentGroup.auto_name(ws, prompt)

    if updated_ws.label != ws.label do
      tb = EditorState.tab_bar(state)
      EditorState.set_tab_bar(state, TabBar.update_group(tb, ws.id, fn _ -> updated_ws end))
    else
      state
    end
  end

  @spec find_unassociated_file_tab(TabBar.t(), String.t(), non_neg_integer()) :: Tab.t() | nil
  defp find_unassociated_file_tab(tb, path, ws_id) do
    filename = Path.basename(path)

    Enum.find(tb.tabs, fn tab ->
      tab.kind == :file and tab.group_id != ws_id and tab.label == filename
    end)
  end
end
