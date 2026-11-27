defmodule MingaEditor.Shell.Traditional.TaskReviewWorkflow do
  @moduledoc "Loads one task's review offers off the editor mailbox and mounts their tree beside the file."

  @behaviour MingaEditor.Effect

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.Session.ConnectionTarget
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.TaskReview
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.Agent.Tasks.Entry
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Effect.{Outcome, Policy, Request}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Layout
  alias MingaEditor.PromptUI
  alias MingaEditor.Quickfix
  alias MingaEditor.QuickfixWorkflow
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Workspace
  alias MingaEditor.{Window, WindowFocus, WindowTree}
  alias MingaEditor.UI.Prompt.KeepTaskReview

  @buffer_name "*minga-review*"

  @typep pane :: {Buffer.t(), Window.id(), Window.id(), ConnectionTarget.t()}
  @typep presentation :: {TaskReview.t(), pane()}
  @typep decision_job ::
           {Buffer.t(), BufferProcess.review_target()}
           | {:at, Buffer.t(), Minga.Buffer.UndoHistory.review_location()}
  @typep action ::
           :open
           | :open_with_quickfix
           | {:decide, pane() | nil, TaskReview.decision(), [decision_job()]}
           | {:refresh, pane() | nil}
           | {:diff, pane(), TaskReview.entry()}
  @typep result ::
           {:opened, TaskReview.t()}
           | {:decided, TaskReview.t(), [{Buffer.t(), term()}]}
           | {:diff, TaskReview.key(), BufferProcess.review_target(), [String.t()]}
  @type t :: %__MODULE__{
          tab: Tab.id(),
          editor: pid(),
          focus_origin: Window.id(),
          target: ConnectionTarget.t(),
          generation: non_neg_integer(),
          mount_epoch: reference() | nil,
          anchor: Window.id(),
          anchor_buffer: Buffer.t(),
          review: TaskReview.t(),
          buffers: [Buffer.t()],
          paths: [String.t()],
          file_options: keyword(),
          action: action()
        }
  @enforce_keys [
    :tab,
    :editor,
    :focus_origin,
    :target,
    :generation,
    :mount_epoch,
    :anchor,
    :anchor_buffer,
    :review,
    :buffers,
    :paths,
    :file_options
  ]
  defstruct [
    :tab,
    :editor,
    :focus_origin,
    :target,
    :generation,
    :mount_epoch,
    :anchor,
    :anchor_buffer,
    :review,
    :buffers,
    :paths,
    :file_options,
    action: :open
  ]

  @doc "Refreshes a retained review when returning to its originating tab."
  @spec resume(State.t()) :: State.t()
  def resume(state), do: refresh_for_source(state, :all)

  @doc "Reconciles a Keep or Reject published after the worker's reply deadline."
  @spec source_changed(State.t(), Buffer.t()) :: State.t()
  def source_changed(state, buffer), do: refresh_for_source(state, buffer)

  @doc "Retries the originating tab after the running effect releases its scheduler slot."
  @spec retry_refresh(State.t(), Tab.id()) :: State.t()
  def retry_refresh(state, tab_id) do
    if tab(state) == tab_id and refresh_needed?(state),
      do: refresh_for_source(state, :all),
      else: state
  end

  @spec refresh_for_source(State.t(), :all | Buffer.t()) :: State.t()
  defp refresh_for_source(%State{effect_scheduler: nil} = state, _source), do: state

  defp refresh_for_source(state, source) do
    with {review, pane} <- refresh_subject(state, source),
         %Window{content: {:buffer, _}} = window <- anchor(state) do
      effect = %{capture(state, window, review) | action: {:refresh, pane}}

      case EffectScheduler.schedule(state.effect_scheduler, request(effect)) do
        {:ok, _, _} -> mark_refresh(state, false)
        {:error, :queue_full} -> mark_refresh(state, true)
        {:error, reason} -> failure(mark_refresh(state, true), reason)
      end
    else
      _ -> if source == :all, do: mark_refresh(state, false), else: state
    end
  end

  @spec refresh_subject(State.t(), :all | Buffer.t()) :: {TaskReview.t(), pane() | nil} | nil
  defp refresh_subject(state, source) do
    task = UIState.task_id(state.workspace.agent_ui)
    target = connection_target(state)
    list = state.interaction.quickfix

    quickfix? =
      list.source == {:task_review, task, tab(state), target} and quickfix_source?(list, source)

    case presentation(state) do
      {%TaskReview{task: ^task} = review, {_, _, _, ^target} = pane} ->
        if pending_source?(review, source) or quickfix?, do: {review, pane}

      _ ->
        if quickfix?, do: {current_or_new(state, task), nil}
    end
  end

  @spec quickfix_source?(Quickfix.t(), :all | Buffer.t()) :: boolean()
  defp quickfix_source?(_list, :all), do: true

  defp quickfix_source?(%Quickfix{entries: entries}, buffer) do
    Enum.any?(0..(tuple_size(entries) - 1)//1, fn index ->
      match?({_, _, {:review_unit, ^buffer, _}}, elem(entries, index))
    end)
  end

  @spec refresh_needed?(State.t()) :: boolean()
  defp refresh_needed?(state),
    do: SessionState.get_feature_state(state.workspace, :builtin, :task_review_refresh) == true

  @spec mark_refresh(State.t(), boolean()) :: State.t()
  defp mark_refresh(state, needed?) do
    if refresh_needed?(state) == needed? do
      state
    else
      workspace =
        if needed?,
          do:
            SessionState.put_feature_state(state.workspace, :builtin, :task_review_refresh, true),
          else: SessionState.drop_feature_state(state.workspace, :builtin, :task_review_refresh)

      %{state | workspace: workspace}
    end
  end

  @spec pending_source?(TaskReview.t(), :all | Buffer.t()) :: boolean()
  defp pending_source?(_review, :all), do: true

  defp pending_source?(review, buffer),
    do: Enum.any?(review.pending, &match?({{^buffer, _}, _, _, _}, &1))

  @doc "Opens or refreshes the review for the task connected to this workspace."
  @spec open(State.t()) :: State.t()
  def open(%State{} = state), do: open(state, :open)

  @doc "Opens the task review and publishes its unreviewed locations to the editor's shared quickfix list."
  @spec open_quickfix(State.t()) :: State.t()
  def open_quickfix(%State{} = state), do: open(state, :open_with_quickfix)

  @spec open(State.t(), :open | :open_with_quickfix) :: State.t()
  defp open(state, intent) do
    case connection_target(state) do
      %ConnectionTarget{session_id: task} = target when is_binary(task) ->
        {state, source} = review_source(state, anchor(state))

        case source do
          %Window{content: {:buffer, _}} = parent
          when state.workspace.agent_ui.connection.target == target ->
            effect = capture(state, parent, current_or_new(state, task))
            schedule(state, %{effect | action: intent})

          _unavailable ->
            NoticeWorkflow.publish(
              state,
              "Open a file in this task's workspace to review its changes"
            )
        end

      _unconnected ->
        NoticeWorkflow.publish(state, "Open a task and a file to review its changes")
    end
  end

  @spec review_source(State.t(), Window.t() | nil) :: {State.t(), Window.t() | nil}
  defp review_source(state, %Window{} = window), do: {state, window}

  defp review_source(state, nil) do
    case UIState.View.return_target(state.workspace.agent_ui.view) do
      %{active_buffer: buffer} when is_pid(buffer) ->
        if BufferRegistry.buffer_tracked?(state, buffer) do
          state =
            state |> AgentCommands.scope_unfocus_input() |> BufferRegistry.add_buffer(buffer)

          {state, anchor(state)}
        else
          {state, nil}
        end

      _unavailable ->
        {state, nil}
    end
  end

  @doc "Returns the review only when its exact generated buffer has keyboard focus."
  @spec focused(State.t()) :: {TaskReview.t(), {Buffer.t(), Window.id(), Window.id()}} | nil
  def focused(state) do
    case focused_pane(state) do
      {review, {buffer, window, parent, _}} -> {review, {buffer, window, parent}}
      nil -> nil
    end
  end

  @spec focused_pane(State.t()) :: presentation() | nil
  defp focused_pane(state) do
    case presentation(state) do
      {_, {buffer, window, _, _}} = presentation ->
        case Windows.active_struct(state.workspace.windows) do
          %Window{id: ^window, content: {:buffer, ^buffer}} -> presentation
          _ -> nil
        end

      nil ->
        nil
    end
  end

  @spec focused_current(State.t()) :: presentation() | nil
  defp focused_current(state) do
    case focused_pane(state) do
      {review, {_, _, _, target}} = presentation ->
        if target == connection_target(state) and
             review.task == UIState.task_id(state.workspace.agent_ui),
           do: presentation

      nil ->
        nil
    end
  end

  @spec navigate(State.t(), :next | :previous) :: State.t()
  def navigate(state, direction) do
    case focused_pane(state) do
      {review, pane} -> display(state, pane, TaskReview.navigate(review, direction))
      nil -> state
    end
  end

  @spec decide(State.t(), TaskReview.decision()) :: State.t()
  def decide(state, decision) do
    with {review, pane} <- focused_current(state),
         {{buffer, _}, _, _, target} <- TaskReview.selected(review) do
      schedule_action(state, review, pane, {:decide, pane, decision, [{buffer, target}]})
    else
      nil -> state
    end
  end

  @doc "Decides the exact review units listed in quickfix, not the other changes on their lines."
  @spec decide_quickfix(State.t(), TaskReview.decision()) :: State.t()
  def decide_quickfix(state, decision) do
    list = state.interaction.quickfix
    tab_id = tab(state)
    task = UIState.task_id(state.workspace.agent_ui)
    target = connection_target(state)

    with {:task_review, ^task, ^tab_id, ^target} <- list.source,
         %Window{content: {:buffer, _}} = parent <- anchor(state),
         [_ | _] = entries <- Quickfix.entries(list) do
      jobs = for {_, _, {:review_unit, buffer, unit}} <- entries, do: {:at, buffer, unit}

      pane =
        case presentation(state) do
          {%TaskReview{task: ^task}, {_, _, _, ^target} = pane} -> pane
          _ -> nil
        end

      effect = capture(state, parent, current_or_new(state, task))
      schedule(state, %{effect | action: {:decide, pane, decision, jobs}})
    else
      [] -> NoticeWorkflow.publish(state, "The quickfix list is empty")
      _ -> NoticeWorkflow.publish(state, "The quickfix review belongs to a different task or tab")
    end
  end

  @spec confirm_keep_all(State.t()) :: State.t()
  def confirm_keep_all(state) do
    case focused_current(state) do
      {%TaskReview{pending: [_ | _], unavailable: []} = review, pane} ->
        count = length(review.pending)
        noun = if count == 1, do: "change", else: "changes"

        PromptUI.open(state, KeepTaskReview,
          kind: :confirm,
          label: "Keep all #{count} pending #{noun}?",
          context: %{tab: tab(state), review: review, pane: pane}
        )

      {%TaskReview{unavailable: [_ | _]}, _} ->
        NoticeWorkflow.publish(
          state,
          "Keep all is unavailable while some files lack review history"
        )

      _ ->
        state
    end
  end

  @spec keep_confirmed(State.t(), map()) :: State.t()
  def keep_confirmed(state, %{tab: tab_id, review: review, pane: pane}) do
    if tab_id == tab(state) and focused_current(state) == {review, pane} do
      schedule_action(state, review, pane, {:decide, pane, :keep, review.all})
    else
      NoticeWorkflow.publish(state, "The review changed. Confirm Keep all again.")
    end
  end

  @spec toggle_diff(State.t()) :: State.t()
  def toggle_diff(state) do
    case focused_current(state) do
      {%TaskReview{inline_diff: {_, _}} = review, pane} ->
        display(state, pane, TaskReview.hide_diff(review))

      {review, pane} ->
        case TaskReview.selected(review) do
          nil -> state
          entry -> schedule_action(state, review, pane, {:diff, pane, entry})
        end

      nil ->
        state
    end
  end

  @doc "Dismisses the inline preview first, otherwise closes the focused review."
  @spec escape(State.t()) :: State.t()
  def escape(state) do
    case focused_pane(state) do
      {%TaskReview{inline_diff: {_, _}} = review, pane} ->
        display(state, pane, TaskReview.hide_diff(review))

      {_, pane} ->
        remove_pane(state, pane)

      nil ->
        state
    end
  end

  @spec jump(State.t()) :: State.t()
  def jump(state) do
    case focused_current(state) do
      {%TaskReview{pending: [], unavailable: [], decisions: [_ | _]}, {_, _, _, target}} ->
        reply_to_task(state, target)

      {review, {_, _, parent, _}} ->
        case TaskReview.selected(review) do
          {{buffer, unit}, _, _, _} -> QuickfixWorkflow.jump_unit(state, parent, buffer, unit)
          nil -> NoticeWorkflow.publish(state, "The review location is unavailable")
        end

      nil ->
        NoticeWorkflow.publish(state, "The review location is unavailable")
    end
  end

  @spec reply_to_task(State.t(), ConnectionTarget.t()) :: State.t()
  defp reply_to_task(state, %ConnectionTarget{session: session}) do
    tabs = Runtime.state(state.shell_runtime).tab_bar

    with %Workspace{id: workspace} <- TabBar.find_workspace_by_session(tabs, session),
         %Tab{id: id} <-
           Enum.find(TabBar.tabs_in_workspace(tabs, workspace), &(&1.kind == :agent)) do
      state |> close() |> AgentCommands.reveal_agent_view(id) |> AgentCommands.scope_focus_input()
    else
      nil -> NoticeWorkflow.publish(state, "That task's conversation is no longer available")
    end
  end

  @spec close(State.t()) :: State.t()
  def close(state) do
    case focused_pane(state) do
      {_, pane} -> remove_pane(state, pane)
      nil -> state
    end
  end

  @doc "Closes the review pane before its parent split is removed."
  @spec close_for_parent(State.t(), Window.id()) :: State.t()
  def close_for_parent(state, parent) do
    case presentation(state) do
      {_, {_, _, ^parent, _} = pane} -> remove_pane(state, pane)
      _ -> state
    end
  end

  @spec remove_pane(State.t(), pane()) :: State.t()
  defp remove_pane(state, {buffer, window, parent, _}) do
    case Windows.remove_window(state.workspace.windows, window) do
      {:ok, windows} ->
        close_pane(state, buffer, parent, windows)

      :error ->
        state
    end
  end

  @spec close_pane(State.t(), Buffer.t(), Window.id(), Windows.t()) :: State.t()
  defp close_pane(state, buffer, parent, windows) do
    focused = WindowFocus.focus_surviving_window(state, windows, parent)

    workspace =
      focused.workspace
      |> SessionState.drop_feature_state(:builtin, :task_review)
      |> SessionState.drop_feature_state(:builtin, :task_review_prefix)
      |> SessionState.put_feature_state(:builtin, :task_review_mount_epoch, make_ref())

    DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, buffer)
    Layout.invalidate(%{focused | workspace: workspace})
  end

  @spec capture(State.t(), Window.t(), TaskReview.t()) :: t()
  defp capture(state, %Window{id: anchor, content: {:buffer, buffer}}, review) do
    timeline = state.workspace.agent_ui.view.edit_timeline
    root = SessionState.project_root(state.workspace)

    %__MODULE__{
      tab: tab(state),
      editor: self(),
      target: connection_target(state),
      generation: timeline.generation,
      mount_epoch: mount_epoch(state),
      focus_origin: state.workspace.windows.active,
      anchor: anchor,
      anchor_buffer: buffer,
      review: review,
      buffers: [buffer | state.workspace.buffers.list],
      paths: Enum.map(EditTimeline.file_summaries(timeline), &Path.expand(&1.path, root || ".")),
      file_options: [
        history_attribution: :caller_managed,
        options_server: state.interaction.options_server,
        events_registry: state.extension_surfaces.events_registry
      ]
    }
  end

  @spec schedule_action(State.t(), TaskReview.t(), pane(), action()) :: State.t()
  defp schedule_action(state, review, {_, _, parent, _}, action) do
    case Windows.fetch(state.workspace.windows, parent) do
      {:ok, %Window{content: {:buffer, _}} = window} ->
        schedule(state, %{capture(state, window, review) | action: action})

      _ ->
        failure(state, :file_split_unavailable)
    end
  end

  @spec schedule(State.t(), t()) :: State.t()
  defp schedule(%State{effect_scheduler: nil} = state, _effect),
    do: failure(state, :scheduler_unavailable)

  defp schedule(%State{effect_scheduler: scheduler} = state, effect) do
    request = request(effect)

    case EffectScheduler.schedule(scheduler, request) do
      {:ok, _, _} -> state
      {:error, reason} -> failure(state, reason)
    end
  end

  @spec request(t()) :: Request.t()
  defp request(effect),
    do: Request.new(effect, {:task_review, effect.tab}, Policy.fifo(0), timeout_ms: 30_000)

  @impl true
  @spec run(t()) :: {:ok, result()} | {:error, term()}
  def run(%__MODULE__{action: action} = effect) when action in [:open, :open_with_quickfix],
    do: {:ok, {:opened, inventory(effect)}}

  def run(%__MODULE__{action: {:refresh, _}} = effect),
    do: {:ok, {:opened, inventory(effect)}}

  def run(%__MODULE__{action: {:diff, _, {{buffer, _} = key, path, _, target}}}) do
    case Buffer.preview_review(buffer, target) do
      {:ok, before, after_text} ->
        {:ok, {:diff, key, target, diff_lines(DiffReview.new(path, before, after_text))}}

      refusal ->
        {:error, refusal}
    end
  end

  def run(%__MODULE__{action: {:decide, _, decision, jobs}} = effect) do
    failures =
      for job <- jobs,
          {buffer, refusal} = decide_job(job, decision),
          refusal != :ok,
          do: {buffer, refusal}

    {:ok, {:decided, inventory(effect), failures}}
  end

  @spec decide_job(decision_job(), TaskReview.decision()) :: {Buffer.t(), term()}
  defp decide_job({:at, buffer, unit}, decision) do
    result =
      case Buffer.prepare_review(buffer, {:review_unit, unit}) do
        {:ok, target, _, _} -> decide_buffer(buffer, target, decision)
        _ -> :stale_review
      end

    {buffer, result}
  catch
    :exit, reason -> {buffer, {:buffer_unavailable, reason}}
  end

  defp decide_job({buffer, target}, decision),
    do: {buffer, decide_buffer(buffer, target, decision)}

  @spec decide_buffer(Buffer.t(), BufferProcess.review_target(), TaskReview.decision()) :: term()
  defp decide_buffer(buffer, target, decision) do
    mode = if decision == :reject, do: :reject_preserving_cursor, else: :keep

    case Buffer.decide_review(buffer, target, mode) do
      {:ok, _rejected} -> :ok
      result -> result
    end
  catch
    :exit, {:timeout, _details} -> :decision_unresolved
    :exit, reason -> {:buffer_unavailable, reason}
  end

  @spec diff_lines(DiffReview.t() | nil) :: [String.t()]
  defp diff_lines(nil), do: ["No visible text differences."]

  defp diff_lines(%DiffReview{hunks: hunks, after_lines: lines}) do
    Enum.flat_map(hunks, fn hunk ->
      old = Enum.map(hunk.old_lines, &("- " <> &1))
      new = Enum.map(Enum.slice(lines, hunk.start_line, hunk.count), &("+ " <> &1))
      ["@@ #{hunk.start_line + 1}" | old ++ new]
    end)
  end

  @spec inventory(t()) :: TaskReview.t()
  defp inventory(%__MODULE__{buffers: buffers, paths: paths, review: review} = effect) do
    {path_buffers, unavailable} =
      Enum.reduce(paths, {%{}, []}, fn path, {found, unavailable} ->
        case find_file_buffer(path, effect.file_options) do
          {:ok, buffer} ->
            send(effect.editor, {:task_review_source_opened, effect.tab, buffer})
            {Map.put_new(found, buffer, path), unavailable}

          {:error, _reason} ->
            {found, [path | unavailable]}
        end
      end)

    files = Enum.reduce(Map.keys(path_buffers) ++ buffers, MapSet.new(), &MapSet.put(&2, &1))

    {offers, unavailable} =
      Enum.reduce(files, {[], unavailable}, fn buffer, {offers, unavailable} ->
        case observe_buffer(buffer, path_buffers[buffer], review) do
          {:ok, offer} -> {[offer | offers], unavailable}
          {:unavailable, path} -> {offers, [path | unavailable]}
          :skip -> {offers, unavailable}
        end
      end)

    TaskReview.refresh(review, offers, unavailable)
  end

  @spec find_file_buffer(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  defp find_file_buffer(path, opts) do
    case Buffer.pid_for_file(path) do
      {:ok, buffer} ->
        {:ok, buffer}

      :not_found ->
        MingaEditor.Commands.start_buffer(path, Keyword.fetch!(opts, :options_server), opts)
    end
  end

  @impl true
  @spec apply(State.t(), Outcome.t()) :: {State.t(), Outcome.t()}
  def apply(state, %Outcome{request: %Request{effect: effect}} = outcome) do
    if Outcome.terminal?(outcome) and effect.tab == tab(state) and refresh_needed?(state) do
      send(self(), {:retry_task_review_refresh, effect.tab})
    end

    if current?(state, effect) do
      case outcome.value do
        {:completed, result} -> apply_completed(state, outcome, effect, result)
        {:failed, :timeout} -> timeout(state, outcome, effect)
        {:failed, reason} -> {failure(state, reason), outcome}
        _ -> {state, outcome}
      end
    else
      state = reconcile_hidden_decision(state, effect, outcome.value)
      {state, Outcome.stale(outcome, :review_context_changed)}
    end
  end

  @spec reconcile_hidden_decision(State.t(), t(), Outcome.value()) :: State.t()
  defp reconcile_hidden_decision(state, effect, {:completed, {:decided, review, _}}) do
    source = {:task_review, review.task, effect.tab, effect.target}

    if state.interaction.quickfix.source == source do
      State.put_quickfix(state, Quickfix.replace(source, TaskReview.locations(review)))
    else
      state
    end
  end

  defp reconcile_hidden_decision(state, _effect, _done), do: state

  @spec timeout(State.t(), Outcome.t(), t()) :: {State.t(), Outcome.t()}
  defp timeout(state, outcome, %{action: {:decide, pane, _, _}} = effect) do
    state =
      NoticeWorkflow.publish(
        state,
        "Some review decisions are unresolved. Refreshing confirmed results."
      )

    followup(state, outcome, effect, {:refresh, pane})
  end

  defp timeout(state, outcome, _effect), do: {failure(state, :timeout), outcome}

  @spec apply_completed(State.t(), Outcome.t(), t(), result()) :: {State.t(), Outcome.t()}
  defp apply_completed(state, outcome, effect, result) do
    generation = state.workspace.agent_ui.view.edit_timeline.generation

    if elem(result, 0) != :diff and generation != effect.generation do
      {state, action} =
        case {result, effect.action} do
          {{:decided, _, failures}, {:decide, pane, _, _}} ->
            {decision_feedback(state, failures), {:refresh, pane}}

          _ ->
            {state, effect.action}
        end

      followup(state, outcome, effect, action)
    else
      {install_result(state, effect, result), outcome}
    end
  end

  @spec followup(State.t(), Outcome.t(), t(), action()) :: {State.t(), Outcome.t()}
  defp followup(state, outcome, effect, action) do
    {:ok, anchor} = Windows.fetch(state.workspace.windows, effect.anchor)
    next = %{capture(state, anchor, effect.review) | action: action}

    case EffectScheduler.finalize_and_schedule(state.effect_scheduler, outcome, request(next)) do
      {:ok, _, _} -> {state, outcome}
      {:error, reason} -> {failure(state, reason), Outcome.failed(outcome.request, reason)}
    end
  end

  @spec install_result(State.t(), t(), result()) :: State.t()
  defp install_result(state, %{action: {:refresh, pane}}, {:opened, review}),
    do: publish_inventory(state, review, pane)

  defp install_result(state, effect, {:opened, review}) do
    state = mount(state, effect.anchor, review, effect.target)
    publish_quickfix(state, review, effect.action == :open_with_quickfix)
  end

  defp install_result(state, %{action: {:decide, pane, _, _}}, {:decided, review, failures}) do
    state |> publish_inventory(review, pane) |> decision_feedback(failures)
  end

  defp install_result(state, %{action: {:diff, pane, _}}, {:diff, key, target, lines}) do
    case presentation(state) do
      {review, ^pane} ->
        case TaskReview.selected(review) do
          {^key, _, _, ^target} ->
            display(state, pane, TaskReview.show_diff(review, key, lines), false)

          _ ->
            state
        end

      _ ->
        state
    end
  end

  @spec publish_inventory(State.t(), TaskReview.t(), pane() | nil) :: State.t()
  defp publish_inventory(state, review, pane) do
    state = if pane_present?(state, pane), do: display(state, pane, review, false), else: state
    publish_quickfix(state, review, false)
  end

  @spec decision_feedback(State.t(), [{Buffer.t(), term()}]) :: State.t()
  defp decision_feedback(state, failures) do
    case failures do
      [] ->
        state

      [{_buffer, reason} | _] ->
        NoticeWorkflow.publish(
          state,
          "#{length(failures)} file decisions not confirmed: #{inspect(reason)}"
        )
    end
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {tag, _}}) when tag in [:completed, :failed], do: true
  def render?(%Outcome{}), do: false

  @spec publish_quickfix(State.t(), TaskReview.t(), boolean()) :: State.t()
  defp publish_quickfix(state, review, replace?) do
    source = {:task_review, review.task, tab(state), connection_target(state)}

    if replace? or state.interaction.quickfix.source == source do
      State.put_quickfix(state, Quickfix.replace(source, TaskReview.locations(review)))
    else
      state
    end
  end

  @spec observe_buffer(Buffer.t(), String.t() | nil, TaskReview.t()) ::
          {:ok, TaskReview.file_offer()} | {:unavailable, String.t()} | :skip
  defp observe_buffer(buffer, path, review) do
    file = Buffer.file_path(buffer) || path

    if is_binary(file) do
      case Buffer.task_review_entries(buffer, review.task) do
        {[], nil, {0, 0}} when is_binary(path) ->
          {:unavailable, path}

        offer ->
          {:ok, {buffer, file, offer}}
      end
    else
      :skip
    end
  catch
    :exit, _reason -> if is_binary(path), do: {:unavailable, path}, else: :skip
  end

  @spec current_or_new(State.t(), String.t()) :: TaskReview.t()
  defp current_or_new(state, task) do
    review =
      case presentation(state) do
        {%TaskReview{task: ^task} = review, {_, _, _, target}}
        when target == state.workspace.agent_ui.connection.target ->
          review

        _ ->
          TaskReview.new(task, "Minga task")
      end

    root = SessionState.project_root(state.workspace)
    session = state.workspace.agent_ui.connection.target.session

    case Tasks.fetch(state.agent_connection.tasks, session, task) do
      {:ok, entry} ->
        TaskReview.describe(
          review,
          Entry.title(entry),
          Entry.words(entry, System.system_time(:millisecond)),
          root
        )

      _ ->
        TaskReview.describe(review, review.title, review.status, root)
    end
  end

  @spec connection_target(State.t()) :: ConnectionTarget.t() | nil
  defp connection_target(%State{workspace: %{agent_ui: %{connection: %{target: target}}}}),
    do: target

  defp connection_target(%State{}), do: nil

  @spec current?(State.t(), t()) :: boolean()
  defp current?(state, effect) do
    tab(state) == effect.tab and connection_target(state) == effect.target and
      UIState.task_id(state.workspace.agent_ui) == effect.review.task and
      action_current?(state, effect)
  end

  @spec action_current?(State.t(), t()) :: boolean()
  defp action_current?(state, %{action: action} = effect)
       when action in [:open, :open_with_quickfix] do
    state.workspace.windows.active == effect.focus_origin and
      mount_epoch(state) == effect.mount_epoch and
      match?(
        {:ok, %Window{content: {:buffer, buffer}}} when buffer == effect.anchor_buffer,
        Windows.fetch(state.workspace.windows, effect.anchor)
      )
  end

  defp action_current?(state, %{action: action} = effect)
       when elem(action, 0) in [:decide, :refresh] do
    file_anchor? =
      match?(
        {:ok, %Window{content: {:buffer, _}}},
        Windows.fetch(state.workspace.windows, effect.anchor)
      )

    file_anchor? and
      (pane_present?(state, elem(action, 1)) or
         state.interaction.quickfix.source ==
           {:task_review, effect.review.task, effect.tab, effect.target})
  end

  defp action_current?(state, %{action: {:diff, pane, _}}), do: pane_present?(state, pane)

  @spec mount_epoch(State.t()) :: reference() | nil
  defp mount_epoch(state),
    do: SessionState.get_feature_state(state.workspace, :builtin, :task_review_mount_epoch)

  @spec pane_present?(State.t(), pane() | nil) :: boolean()
  defp pane_present?(_state, nil), do: false

  defp pane_present?(state, {buffer, window, _, _} = pane) do
    match?({_, ^pane}, presentation(state)) and
      match?(
        {:ok, %Window{content: {:buffer, ^buffer}}},
        Windows.fetch(state.workspace.windows, window)
      )
  end

  @spec anchor(State.t()) :: Window.t() | nil
  defp anchor(state) do
    case presentation(state) do
      {_, {_buffer, _review, parent, _}} ->
        case Windows.fetch(state.workspace.windows, parent) do
          {:ok, window} -> window
          :error -> file_window(state)
        end

      _ ->
        file_window(state)
    end
  end

  @spec file_window(State.t()) :: Window.t() | nil
  defp file_window(%{workspace: %{windows: windows}}) do
    case Windows.active_struct(windows) do
      %Window{content: {:buffer, _}} = window -> window
      _ -> Enum.find(Map.values(windows.map), &match?(%Window{content: {:buffer, _}}, &1))
    end
  end

  @spec mount(State.t(), Window.id(), TaskReview.t(), ConnectionTarget.t()) :: State.t()
  defp mount(state, anchor, review, target) do
    case presentation(state) do
      {_, {buffer, window, _, _}} ->
        if match?(
             {:ok, %Window{content: {:buffer, ^buffer}}},
             Windows.fetch(state.workspace.windows, window)
           ) do
          display(state, {buffer, window, anchor, target}, review)
        else
          mount_new(state, anchor, review, target)
        end

      nil ->
        mount_new(state, anchor, review, target)
    end
  end

  @spec mount_new(State.t(), Window.id(), TaskReview.t(), ConnectionTarget.t()) :: State.t()
  defp mount_new(state, anchor, review, target) do
    {id, windows} = Windows.allocate_id(state.workspace.windows)
    viewport = state.frontend.terminal_viewport

    with {:ok, tree} <- WindowTree.split(windows.tree, anchor, :vertical, id, :before),
         {:ok, buffer} <- start_buffer(state) do
      windows =
        windows
        |> Windows.set_tree(tree)
        |> Windows.add_window(Window.new(id, buffer, viewport.rows, viewport.cols))

      state = %{state | workspace: SessionState.set_windows(state.workspace, windows)}

      state
      |> BufferRegistry.monitor_buffer(buffer)
      |> display({buffer, id, anchor, target}, review)
      |> Layout.invalidate()
    else
      error -> failure(state, error)
    end
  end

  @spec start_buffer(State.t()) :: {:ok, Buffer.t()} | {:error, term()}
  defp start_buffer(state) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {Buffer,
       buffer_name: @buffer_name,
       buffer_type: :nofile,
       content: "",
       read_only: true,
       unlisted: true,
       options_server: state.interaction.options_server}
    )
  end

  @spec display(State.t(), pane(), TaskReview.t(), boolean()) :: State.t()
  defp display(state, {buffer, window, _, _} = pane, review, focus? \\ true) do
    {text, row} = TaskReview.text(review)
    :ok = Buffer.replace_generated_content(buffer, text)
    {:ok, view} = Windows.fetch(state.workspace.windows, window)
    position = {row, 0}

    workspace =
      state.workspace
      |> SessionState.replace_window(window, Window.set_cursor(view, position))
      |> SessionState.put_feature_state(:builtin, :task_review, {review, pane})

    :ok = Buffer.move_to(buffer, position)
    state = %{state | workspace: workspace}
    state = if focus?, do: WindowFocus.focus(state, window), else: state
    state
  end

  @spec presentation(State.t()) :: presentation() | nil
  defp presentation(state),
    do: SessionState.get_feature_state(state.workspace, :builtin, :task_review)

  @spec tab(State.t()) :: Tab.id()
  defp tab(state), do: Runtime.state(state.shell_runtime).tab_bar.active_id

  @spec failure(State.t(), term()) :: State.t()
  defp failure(state, reason),
    do: NoticeWorkflow.publish(state, "Task review failed: #{inspect(reason)}")
end
