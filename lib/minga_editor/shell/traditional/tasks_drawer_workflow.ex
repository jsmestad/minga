defmodule MingaEditor.Shell.Traditional.TasksDrawerWorkflow do
  @moduledoc """
  Opens, closes and drives the tasks drawer (`*minga-tasks*`).

  The drawer acts on rows by identity: a key acts on the selected row, a click on the row it hit, wherever that row has moved since. Approvals go through `MingaEditor.Agent.TaskWorkflow.answer/3`, so the session decides and a request answered elsewhere says "Already answered in Minga".

  The drawer shows its list, or one task's request diff (`=`) or output (`o`); `q` and `esc` step back from a view to the list, and from the list close the drawer. Stopping a task (`x`) asks first. Opening the drawer from a notification arms it: single-letter actions are ignored for 300 ms, so a letter typed in a file cannot answer an approval.

  Two actions have a home of their own coming: `inspect_task/2` opens the task's conversation until the subagent peek (#4046) gives it a split, and `review/2` opens today's pending reviews until the review buffer (#4051) replaces it.
  """

  alias MingaAgent.Session
  alias MingaEditor.Agent.ErrorWords
  alias MingaEditor.Agent.TaskWorkflow
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Agent.Tasks.Entry
  alias MingaEditor.RenderModel.UI.TasksDrawerBuilder
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Drawers
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace

  @typedoc "How an approval is answered."
  @type decision :: TaskWorkflow.decision()

  @typedoc "A drawer command, as the `:tasks` keymap scope names it."
  @type command ::
          :tasks_next
          | :tasks_prev
          | :tasks_approve
          | :tasks_approve_session
          | :tasks_approve_turn
          | :tasks_deny
          | :tasks_show_diff
          | :tasks_new
          | :tasks_retry
          | :tasks_output
          | :tasks_inspect
          | :tasks_stop
          | :tasks_open
          | :tasks_next_change
          | :tasks_prev_change
          | :tasks_back

  @arming_ms 300

  @decisions %{
    tasks_approve: :approve,
    tasks_approve_session: :approve_session,
    tasks_approve_turn: :approve_turn,
    tasks_deny: :reject
  }

  # A click names the key its control shows.
  @click_commands %{
    "y" => :tasks_approve,
    "a" => :tasks_approve_session,
    "t" => :tasks_approve_turn,
    "n" => :tasks_deny,
    "=" => :tasks_show_diff,
    "r" => :tasks_retry,
    "o" => :tasks_output,
    "i" => :tasks_inspect,
    "x" => :tasks_stop,
    "↩" => :tasks_open,
    "c" => :tasks_new,
    "q" => :tasks_back
  }

  # Single letters that act; arming ignores them, never movement or esc.
  @letters [
    :tasks_approve,
    :tasks_approve_session,
    :tasks_approve_turn,
    :tasks_deny,
    :tasks_show_diff,
    :tasks_new,
    :tasks_retry,
    :tasks_output,
    :tasks_inspect,
    :tasks_stop,
    :tasks_open
  ]

  @doc "True while the tasks drawer is on screen and has the keyboard."
  @spec focused?(EditorState.t()) :: boolean()
  def focused?(%EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell}}),
    do: shell |> TraditionalState.drawers() |> Drawers.focused?(:tasks)

  def focused?(%EditorState{}), do: false

  @doc """
  `SPC a a`: opens the drawer with the keyboard, or closes it when it already has the keyboard.

  A drawer on screen without the keyboard takes it back instead of closing.
  """
  @spec toggle(EditorState.t()) :: EditorState.t()
  def toggle(%EditorState{} = state) do
    if focused?(state), do: close(state), else: open(state)
  end

  @doc """
  Opens the drawer with the keyboard. A drawer that was not on screen opens on the first task that needs you, so its keys answer it at once; a drawer already on screen keeps its selection.
  """
  @spec open(EditorState.t()) :: EditorState.t()
  def open(%EditorState{} = state) do
    needs_you = if Drawers.showing?(drawers(state), :tasks), do: nil, else: first_needs_you(state)

    state
    |> leave_text_entry()
    |> update(fn shell ->
      shell = TraditionalState.open_tasks_drawer(shell)
      if needs_you, do: TraditionalState.select_task_row(shell, needs_you), else: shell
    end)
  end

  @doc """
  Opens the drawer on the task `session`, for a notification. Single-letter actions are ignored for the first 300 ms.
  """
  @spec open_on(EditorState.t(), pid()) :: EditorState.t()
  def open_on(%EditorState{} = state, session) when is_pid(session),
    do: open_armed(state, row_for(state.agent_connection.tasks, session))

  @doc """
  Opens the drawer for a click on the "needs you" alert `alert`, on the task it was posted for, as `open_on/2` does.

  The click acts on nothing: the row shows the task as it is now, answered or not. An alert for a task Minga no longer follows opens the drawer on the first task that needs you.
  """
  @spec open_alert(EditorState.t(), <<_::128>>) :: EditorState.t()
  def open_alert(%EditorState{} = state, <<_::128>> = alert) do
    case Tasks.alerted_session(state.agent_connection.tasks, alert) do
      {:ok, session} -> open_on(state, session)
      :error -> open_armed(state, first_needs_you(state))
    end
  end

  @spec open_armed(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp open_armed(state, row) do
    state
    |> leave_text_entry()
    |> update(fn shell ->
      shell
      |> TraditionalState.open_tasks_drawer()
      |> TraditionalState.select_task_row(row)
      |> TraditionalState.arm_drawer(now() + @arming_ms)
    end)
  end

  @doc "Closes the drawer; the drawer it replaced comes back, or the keyboard returns to the window."
  @spec close(EditorState.t()) :: EditorState.t()
  def close(%EditorState{} = state), do: update(state, &TraditionalState.close_tasks_drawer/1)

  @doc "Remembers the start of a two-key binding (`]h`), or clears it with nil."
  @spec await_key(EditorState.t(), Minga.Keymap.Bindings.node_t() | nil) :: EditorState.t()
  def await_key(%EditorState{} = state, prefix),
    do: update(state, &TraditionalState.await_drawer_key(&1, prefix))

  @doc "The start of a two-key binding the drawer is waiting to finish, or nil."
  @spec awaited_key(EditorState.t()) :: Minga.Keymap.Bindings.node_t() | nil
  def awaited_key(%EditorState{} = state), do: drawers(state).prefix

  @doc "Selects a row by its identity without moving the keyboard."
  @spec select_row(EditorState.t(), String.t()) :: EditorState.t()
  def select_row(%EditorState{} = state, row_id) when is_binary(row_id),
    do: update(state, &TraditionalState.select_task_row(&1, row_id))

  @doc "Selects the task of `session`, for a task the drawer just started."
  @spec select_session(EditorState.t(), pid()) :: EditorState.t()
  def select_session(%EditorState{} = state, session) when is_pid(session) do
    case row_for(state.agent_connection.tasks, session) do
      nil -> state
      row -> update(state, &TraditionalState.select_task_row(&1, row))
    end
  end

  @doc """
  Runs one drawer command from a key, on the selected row.

  What a command does depends on what the drawer shows: a pending stop takes only its answer, a diff answers its own request and scrolls, an output retries and scrolls, and the list does everything. While the drawer is arming, single letters are ignored.
  """
  @spec run(EditorState.t(), command()) :: EditorState.t()
  def run(%EditorState{} = state, command) do
    if command in @letters and arming?(state) do
      state
    else
      state = forget_vanished_stop(state)
      dispatch(state, drawers(state), command, target_row(state, command))
    end
  end

  @doc """
  Applies a click from the drawer: `focus` (a click on empty space) gives the drawer the keyboard, `select` selects the row, a key the row shows runs its command on that row, and `q` steps back or closes. A click names the row it was on, so it acts on that task even if rows moved since the frame it saw.
  """
  @spec click(EditorState.t(), String.t(), String.t()) :: EditorState.t()
  def click(%EditorState{} = state, "", "focus"), do: focus(state)
  def click(%EditorState{} = state, row_id, "select"), do: select(state, row_id)

  def click(%EditorState{} = state, "", key) when is_map_key(@click_commands, key) do
    state = forget_vanished_stop(state)
    dispatch(state, drawers(state), Map.fetch!(@click_commands, key), nil)
  end

  def click(%EditorState{} = state, row_id, key) when is_map_key(@click_commands, key) do
    if row_id in row_ids(state) do
      state = state |> forget_vanished_stop() |> leave_other_stop(row_id) |> select(row_id)
      dispatch(state, drawers(state), Map.fetch!(@click_commands, key), row_id)
    else
      state
    end
  end

  def click(%EditorState{} = state, _row_id, _action), do: state

  @spec dispatch(EditorState.t(), Drawers.t(), command(), String.t() | nil) :: EditorState.t()
  defp dispatch(state, %Drawers{pending: {:stop, row, target}}, :tasks_approve, _selected),
    do: state |> confirm_stop(nil) |> stop(row, target)

  defp dispatch(state, %Drawers{pending: {:stop, _row, _target}}, command, _selected)
       when command in [:tasks_deny, :tasks_back],
       do: confirm_stop(state, nil)

  defp dispatch(state, %Drawers{pending: {:stop, _row, _target}}, _command, _selected), do: state

  defp dispatch(state, %Drawers{view: {kind, row}} = drawers, command, _selected)
       when command in [:tasks_next, :tasks_prev],
       do:
         scroll(
           state,
           drawers,
           view_lines(state, kind, row),
           if(command == :tasks_next, do: 1, else: -1)
         )

  defp dispatch(state, %Drawers{view: {_kind, _row}}, :tasks_back, _selected),
    do: show(state, :list)

  defp dispatch(state, %Drawers{view: {:diff, row}} = drawers, command, _selected)
       when command in [:tasks_next_change, :tasks_prev_change],
       do: jump_change(state, drawers, row, command)

  defp dispatch(state, %Drawers{view: {:diff, row}}, command, _selected)
       when is_map_key(@decisions, command),
       do: state |> show(:list) |> answer(row, Map.fetch!(@decisions, command))

  defp dispatch(state, %Drawers{view: {:output, row}}, :tasks_retry, _selected),
    do: state |> show(:list) |> retry(row)

  defp dispatch(state, %Drawers{view: {:output, row}, offset: offset}, :tasks_open, _selected),
    do: open_reference(state, row, offset)

  defp dispatch(state, %Drawers{view: {_kind, _row}}, _command, _selected), do: state

  defp dispatch(state, %Drawers{} = drawers, command, _selected)
       when command in [:tasks_next, :tasks_prev, :tasks_open] do
    if row_ids(state) == [],
      do: empty_step(state, drawers, command),
      else: list_step(state, command)
  end

  defp dispatch(state, %Drawers{}, :tasks_back, _selected), do: close(state)
  defp dispatch(state, %Drawers{}, :tasks_new, _selected), do: new_task(state)

  defp dispatch(state, %Drawers{}, command, row) when is_map_key(@decisions, command),
    do: answer(state, row, Map.fetch!(@decisions, command))

  defp dispatch(state, %Drawers{}, :tasks_show_diff, row),
    do: show_for(state, row, :needs_you, {:diff, row}, "This task is not asking anything")

  defp dispatch(state, %Drawers{}, :tasks_output, row),
    do: show_if_task(state, row, {:output, row})

  defp dispatch(state, %Drawers{}, :tasks_retry, row), do: retry(state, row)
  defp dispatch(state, %Drawers{}, :tasks_stop, row), do: ask_stop(state, row)
  defp dispatch(state, %Drawers{}, :tasks_inspect, row), do: inspect_row(state, row)
  defp dispatch(state, %Drawers{}, _change, _row), do: state

  @spec list_step(EditorState.t(), :tasks_next | :tasks_prev | :tasks_open) :: EditorState.t()
  defp list_step(state, :tasks_next), do: move(state, 1)
  defp list_step(state, :tasks_prev), do: move(state, -1)
  defp list_step(state, :tasks_open), do: open_row(state, selected(state))

  # A drawer with no tasks shows its empty state: j/k move between its next steps and ↩ runs the selected one.
  @spec empty_step(EditorState.t(), Drawers.t(), :tasks_next | :tasks_prev | :tasks_open) ::
          EditorState.t()
  defp empty_step(state, %Drawers{empty_selected: index}, :tasks_open) do
    case Enum.at(TasksDrawerBuilder.empty_commands(), index) do
      nil -> state
      :agent_new_task -> new_task(state)
      command -> state |> MingaEditor.Commands.execute(command) |> command_state()
    end
  end

  defp empty_step(state, %Drawers{empty_selected: index}, command) do
    delta = if command == :tasks_next, do: 1, else: -1
    target = clamp(index + delta, length(TasksDrawerBuilder.empty_commands()))
    update(state, &TraditionalState.select_drawer_empty_action(&1, target))
  end

  @spec command_state(EditorState.t() | {EditorState.t(), term()}) :: EditorState.t()
  defp command_state({%EditorState{} = state, _follow_up}), do: state
  defp command_state(%EditorState{} = state), do: state

  @doc "Moves the selection `delta` rows down (positive) or up (negative), stopping at the ends."
  @spec move(EditorState.t(), integer()) :: EditorState.t()
  def move(%EditorState{} = state, delta) when is_integer(delta) do
    ids = TasksDrawerBuilder.row_ids(state.agent_connection.tasks)
    current = selected(state)
    index = Enum.find_index(ids, &(&1 == current)) || 0
    target = Enum.at(ids, clamp(index + delta, length(ids)))
    update(state, &TraditionalState.select_task_row(&1, target))
  end

  @doc "Gives the keyboard back to the window in front; the drawer stays on screen. For a conversation another surface brought forward."
  @spec release(EditorState.t()) :: EditorState.t()
  def release(%EditorState{} = state), do: update(state, &TraditionalState.blur_drawer/1)

  @doc "Gives the drawer the keyboard without changing its selection, for a click on its empty space."
  @spec focus(EditorState.t()) :: EditorState.t()
  def focus(%EditorState{} = state) do
    if Drawers.showing?(drawers(state), :tasks),
      do: state |> leave_text_entry() |> update(&TraditionalState.focus_drawer/1),
      else: state
  end

  @doc "Selects a row by its identity and gives the drawer the keyboard, for a click."
  @spec select(EditorState.t(), String.t()) :: EditorState.t()
  def select(%EditorState{} = state, row_id) when is_binary(row_id) do
    state
    |> leave_text_entry()
    |> update(fn shell ->
      shell |> TraditionalState.focus_drawer() |> TraditionalState.select_task_row(row_id)
    end)
  end

  @doc "Answers the approval of the task on row `row_id`. A row that is not asking anything says so."
  @spec answer(EditorState.t(), String.t() | nil, decision()) :: EditorState.t()
  def answer(%EditorState{} = state, row_id, decision) do
    case entry(state, row_id) do
      %Entry{pid: pid} = entry ->
        if Entry.state(entry) == :needs_you,
          do: TaskWorkflow.answer(state, pid, decision),
          else: NoticeWorkflow.publish(state, "Nothing to answer on this task")

      nil ->
        state
    end
  end

  # ── Views ────────────────────────────────────────────────────────────────

  @spec show_for(EditorState.t(), String.t() | nil, Entry.state(), Drawers.view(), String.t()) ::
          EditorState.t()
  defp show_for(state, row, wanted, view, refusal) do
    case entry(state, row) do
      %Entry{} = entry ->
        if Entry.state(entry) == wanted,
          do: show(state, view),
          else: NoticeWorkflow.publish(state, refusal)

      nil ->
        state
    end
  end

  @spec show_if_task(EditorState.t(), String.t() | nil, Drawers.view()) :: EditorState.t()
  defp show_if_task(state, row, view) do
    case entry(state, row) do
      %Entry{} -> show(state, view)
      nil -> state
    end
  end

  @spec show(EditorState.t(), Drawers.view()) :: EditorState.t()
  defp show(state, view), do: update(state, &TraditionalState.show_drawer_view(&1, view))

  # The offset stays on a line of the view, so moving back answers at once and ↩ reads the lines on screen.
  @spec scroll(EditorState.t(), Drawers.t(), [String.t()], integer()) :: EditorState.t()
  defp scroll(state, %Drawers{offset: offset}, lines, delta) do
    target = (offset + delta) |> min(max(length(lines) - 1, 0)) |> max(0)
    update(state, &TraditionalState.scroll_drawer(&1, target))
  end

  @spec view_lines(EditorState.t(), :diff | :output, String.t()) :: [String.t()]
  defp view_lines(state, kind, row) do
    case entry(state, row) do
      %Entry{} = entry when kind == :diff -> TasksDrawerBuilder.diff_lines(entry)
      %Entry{} = entry -> TasksDrawerBuilder.output_lines(entry)
      nil -> []
    end
  end

  # ]h and [h step between the request's changes: where a run of added or removed lines begins.
  @spec jump_change(EditorState.t(), Drawers.t(), String.t(), command()) :: EditorState.t()
  defp jump_change(state, %Drawers{offset: offset}, row, command) do
    starts =
      case entry(state, row) do
        %Entry{} = entry ->
          entry |> TasksDrawerBuilder.diff_lines() |> change_starts()

        nil ->
          []
      end

    target =
      case command do
        :tasks_next_change -> Enum.find(starts, &(&1 > offset))
        :tasks_prev_change -> starts |> Enum.filter(&(&1 < offset)) |> List.last()
      end

    if target, do: update(state, &TraditionalState.scroll_drawer(&1, target)), else: state
  end

  # ↩ in the output opens the first file:line at or below the top of the view, so a failure's location is one key away.
  @file_line ~r/([\w.\/-]+\.\w+):(\d+)/

  @spec open_reference(EditorState.t(), String.t(), non_neg_integer()) :: EditorState.t()
  defp open_reference(state, row, offset) do
    reference =
      case entry(state, row) do
        %Entry{} = entry ->
          entry
          |> TasksDrawerBuilder.output_lines()
          |> Enum.drop(offset)
          |> Enum.find_value(&Regex.run(@file_line, &1, capture: :all_but_first))

        nil ->
          nil
      end

    case reference do
      [path, line] ->
        root = MingaEditor.Input.InlineOverlay.project_root(state)
        uri = "file://" <> Path.expand(path, root)

        state
        |> close()
        |> MingaEditor.LspActions.open_location(uri, max(String.to_integer(line) - 1, 0), 0)

      nil ->
        NoticeWorkflow.publish(state, "No file:line in this output")
    end
  end

  # ── Task actions ─────────────────────────────────────────────────────────

  @doc "Opens the \"New task ›\" prompt over the drawer, so the new task appears selected when it starts."
  @spec new_task(EditorState.t()) :: EditorState.t()
  def new_task(%EditorState{} = state) do
    state = if focused?(state), do: state, else: open(state)
    MingaEditor.PromptUI.open(state, MingaEditor.UI.Prompt.NewTask)
  end

  # Retry asks the session again: a waiting retry runs now, and a failed or stopped turn continues.
  @spec retry(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp retry(state, row) do
    case entry(state, row) do
      %Entry{pid: pid} = entry when node(pid) == node() ->
        retry_entry(state, entry)

      %Entry{} ->
        NoticeWorkflow.publish(state, "Retry a remote task from its own conversation")

      nil ->
        state
    end
  end

  @spec retry_entry(EditorState.t(), Entry.t()) :: EditorState.t()
  defp retry_entry(state, %Entry{pid: pid} = entry) do
    case Entry.state(entry) do
      :waiting ->
        :ok = Session.abort(pid)
        continued(state, Session.continue(pid))

      retryable when retryable in [:failed, :stopped] ->
        continued(state, Session.continue(pid))

      _other ->
        NoticeWorkflow.publish(state, "Only a waiting, failed or stopped task can be retried")
    end
  catch
    :exit, _reason -> NoticeWorkflow.publish(state, "That task's session is not running")
  end

  @spec continued(EditorState.t(), :ok | {:error, term()}) :: EditorState.t()
  defp continued(state, :ok), do: state

  defp continued(state, {:error, reason}),
    do: NoticeWorkflow.publish(state, "Could not retry the task: #{ErrorWords.describe(reason)}")

  @spec ask_stop(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp ask_stop(state, row) do
    case entry(state, row) do
      %Entry{stop_target: {_session_id, _request_id} = target} ->
        confirm_stop(state, {row, target})

      %Entry{} ->
        NoticeWorkflow.publish(state, "This task is not running")

      nil ->
        state
    end
  end

  @spec confirm_stop(EditorState.t(), {String.t(), {String.t(), String.t()}} | nil) ::
          EditorState.t()
  defp confirm_stop(state, row), do: update(state, &TraditionalState.confirm_drawer_stop(&1, row))

  # The stop names the exact turn the task showed when you pressed x, so a turn that ended since is left alone. The
  # conversation in front stops through its own path, which keeps the draft; another task's queued input goes back
  # into that task's draft.
  @spec stop(EditorState.t(), String.t(), {String.t(), String.t()}) :: EditorState.t()
  defp stop(state, row, target) do
    case entry(state, row) do
      %Entry{pid: pid} when node(pid) == node() ->
        if Runtime.active_session(state.shell_runtime) == pid,
          do: MingaEditor.Commands.Agent.stop_displayed_turn(state, target),
          else: stopped(state, Session.stop_turn(pid, target))

      %Entry{} ->
        NoticeWorkflow.publish(state, "Stop a remote task from its own conversation")

      nil ->
        state
    end
  catch
    :exit, _reason -> NoticeWorkflow.publish(state, "That task's session is not running")
  end

  # The session keeps queued input across a stop and sends it after the next turn.
  @spec stopped(EditorState.t(), :ok | {:error, :stale_turn}) :: EditorState.t()
  defp stopped(state, :ok),
    do: NoticeWorkflow.publish(state, "Stopped. Queued messages stay queued.")

  defp stopped(state, {:error, :stale_turn}),
    do: NoticeWorkflow.publish(state, "That task is no longer running")

  @spec open_row(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp open_row(state, row) do
    case TasksDrawerBuilder.owner_for(state.agent_connection.tasks, row) do
      %Entry{} = entry ->
        if Entry.state(entry) == :done and entry == entry(state, row),
          do: review(state, entry),
          else: open_conversation(state, entry)

      nil ->
        state
    end
  end

  @spec inspect_row(EditorState.t(), String.t() | nil) :: EditorState.t()
  defp inspect_row(state, row) do
    case TasksDrawerBuilder.owner_for(state.agent_connection.tasks, row) do
      %Entry{} = entry -> inspect_task(state, entry)
      nil -> state
    end
  end

  @doc "Inspects a task: its conversation, until the subagent peek (#4046) opens it in a split."
  @spec inspect_task(EditorState.t(), Entry.t()) :: EditorState.t()
  def inspect_task(%EditorState{} = state, %Entry{} = entry), do: open_conversation(state, entry)

  @doc "Reviews a done task's changes: today's pending reviews, until the review buffer (#4051) replaces it."
  @spec review(EditorState.t(), Entry.t()) :: EditorState.t()
  def review(%EditorState{} = state, %Entry{} = entry) do
    state
    |> open_conversation(entry)
    |> MingaEditor.Commands.Workspace.workspace_pending_reviews()
  end

  @doc "Opens a task's conversation: the drawer closes and its workspace comes to the front."
  @spec open_conversation(EditorState.t(), Entry.t()) :: EditorState.t()
  def open_conversation(%EditorState{} = state, %Entry{pid: pid}) do
    case workspace_for(state, pid) do
      # The drawer this one hid comes back on screen without the keyboard: you went to the conversation.
      %Workspace{id: id} ->
        state
        |> close()
        |> update(&TraditionalState.blur_bottom_panel/1)
        |> MingaEditor.Commands.Workspace.workspace_goto_by_id(id)

      nil ->
        NoticeWorkflow.publish(state, "That task has no conversation in this window")
    end
  end

  @spec workspace_for(EditorState.t(), pid()) :: Workspace.t() | nil
  defp workspace_for(
         %EditorState{
           shell_runtime: %Runtime{state: %TraditionalState{tab_bar: %TabBar{} = tabs}}
         },
         pid
       ),
       do: TabBar.find_workspace_by_session(tabs, pid)

  defp workspace_for(%EditorState{}, _pid), do: nil

  # ── Helpers ──────────────────────────────────────────────────────────────

  @doc "Where each run of added or removed lines begins in a diff, for `]h` and `[h`."
  @spec change_starts([String.t()]) :: [non_neg_integer()]
  def change_starts(lines) do
    lines
    |> Enum.with_index()
    |> Enum.chunk_by(fn {line, _index} -> changed?(line) end)
    |> Enum.flat_map(fn
      [{line, index} | _run] -> if changed?(line), do: [index], else: []
    end)
  end

  @spec changed?(String.t()) :: boolean()
  defp changed?(line), do: String.starts_with?(line, ["+", "-"])

  # An action acts on the row you selected; when that row is gone it does nothing rather than act on another task.
  # Movement, closing and starting a task need no row.
  @spec target_row(EditorState.t(), command()) :: String.t() | nil
  defp target_row(state, command)
       when command in [:tasks_next, :tasks_prev, :tasks_back, :tasks_new],
       do: selected(state)

  defp target_row(state, _command) do
    ids = row_ids(state)

    case drawers(state).selected do
      nil -> List.first(ids)
      row -> if row in ids, do: row, else: nil
    end
  end

  # A stop question about a row that is gone is dropped, so the drawer never waits on a question it no longer shows.
  @spec forget_vanished_stop(EditorState.t()) :: EditorState.t()
  defp forget_vanished_stop(state) do
    case drawers(state).pending do
      {:stop, row, _target} -> if row in row_ids(state), do: state, else: confirm_stop(state, nil)
      nil -> state
    end
  end

  # A click on another row leaves the stop question unanswered; it never confirms it.
  @spec leave_other_stop(EditorState.t(), String.t()) :: EditorState.t()
  defp leave_other_stop(state, row_id) do
    case drawers(state).pending do
      {:stop, ^row_id, _target} -> state
      {:stop, _other, _target} -> confirm_stop(state, nil)
      nil -> state
    end
  end

  # The drawer takes keys only in Normal state, so it leaves the composer, Insert and Visual first.
  @spec leave_text_entry(EditorState.t()) :: EditorState.t()
  defp leave_text_entry(
         %EditorState{workspace: %{agent_ui: %{panel: %{input_focused: true}}}} = state
       ),
       do: MingaEditor.Commands.Agent.scope_unfocus_input(state)

  defp leave_text_entry(%EditorState{workspace: %{editing: %{mode: mode}}} = state)
       when mode in [:insert, :replace, :visual],
       do: %{
         state
         | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :normal)
       }

  defp leave_text_entry(state), do: state

  @spec row_ids(EditorState.t()) :: [String.t()]
  defp row_ids(state), do: TasksDrawerBuilder.row_ids(state.agent_connection.tasks)

  @spec first_needs_you(EditorState.t()) :: String.t() | nil
  defp first_needs_you(state) do
    Enum.find(row_ids(state), fn row ->
      case entry(state, row) do
        %Entry{} = entry -> Entry.state(entry) == :needs_you
        nil -> false
      end
    end)
  end

  @spec entry(EditorState.t(), String.t() | nil) :: Entry.t() | nil
  defp entry(state, row), do: TasksDrawerBuilder.entry_for(state.agent_connection.tasks, row)

  @spec row_for(Tasks.t(), pid()) :: String.t() | nil
  defp row_for(tasks, session) do
    case Tasks.fetch(tasks, session) do
      {:ok, %Entry{seq: seq}} -> "t#{seq}"
      :error -> nil
    end
  end

  @spec selected(EditorState.t()) :: String.t() | nil
  defp selected(state) do
    ids = TasksDrawerBuilder.row_ids(state.agent_connection.tasks)
    remembered = drawers(state).selected
    if remembered in ids, do: remembered, else: List.first(ids)
  end

  @spec arming?(EditorState.t()) :: boolean()
  defp arming?(state), do: state |> drawers() |> Drawers.arming?(now())

  @spec drawers(EditorState.t()) :: Drawers.t()
  defp drawers(%EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell}}),
    do: TraditionalState.drawers(shell)

  defp drawers(%EditorState{}), do: %Drawers{}

  @spec clamp(integer(), non_neg_integer()) :: non_neg_integer()
  defp clamp(_index, 0), do: 0
  defp clamp(index, count), do: index |> max(0) |> min(count - 1)

  # The terminal reserves the drawer's rows, so a change in what is on screen changes the layout.
  @spec update(EditorState.t(), (TraditionalState.t() -> TraditionalState.t())) ::
          EditorState.t()
  defp update(
         %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell}} = state,
         fun
       ) do
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, fun.(shell))}
    |> MingaEditor.Layout.invalidate()
  end

  defp update(%EditorState{} = state, _fun), do: state

  @spec now() :: integer()
  defp now, do: System.os_time(:millisecond)
end
