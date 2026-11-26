defmodule MingaEditor.Agent.QueueWorkflow do
  @moduledoc "Reads and changes the attached conversation's queue without blocking the Editor."
  @behaviour MingaEditor.Effect

  alias MingaAgent.Session
  alias MingaAgent.Session.{QueuedInputSummary, TurnExecution}

  alias Minga.RenderModel.UI.Queue

  alias MingaEditor.Agent.{
    DraftWorkflow,
    PromptInput,
    QuestionResponse,
    QueuedInputEdit,
    QueueSurface,
    UIState
  }

  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.FileTree, as: FileTreeCommands
  alias MingaEditor.Effect.{Outcome, Policy, Request}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowFocus

  @typep origin :: PromptInput.submission_owner()
  @typep mutation ::
           {:withdraw_queued_input, QueuedInputSummary.identity()}
           | {:place_queued_input, QueuedInputSummary.identity(), TurnExecution.queue_placement()}
  @typep operation :: :read_queue_contents | mutation()
  @typep authority :: :local | {pid(), binary()}
  @type key_action ::
          :queue_next
          | :queue_previous
          | :queue_remove
          | :queue_paste_after
          | :queue_paste_before
          | :queue_edit
          | :queue_close

  @type t :: %__MODULE__{origin: origin(), authority: authority(), operation: operation()}
  @enforce_keys [:origin, :authority, :operation]
  defstruct @enforce_keys

  @doc "Identifies the exact saved conversation from the active workspace and attached connection."
  @spec current_origin(State.t()) :: origin() | nil
  def current_origin(
        %State{workspace: %{agent_ui: %{connection: %{persistent_drafts?: true}}}} = state
      ) do
    PromptInput.submission_owner(
      Runtime.review_scope(state.shell_runtime),
      state.workspace.agent_ui
    )
  end

  def current_origin(%State{}), do: nil

  @doc "Focuses the in-conversation queue, including when it is empty."
  @spec open(State.t()) :: State.t()
  def open(state) do
    with {_, session, _} = origin <- current_origin(state),
         {:ok, _authority} <- authority(state, session),
         {:ok, focused} <- focus_conversation(state) do
      focused
      |> focus_queue(origin)
      |> load(origin)
    else
      {:error, reason} -> refuse(state, reason)
      nil -> refuse(state, :not_persistent)
    end
  end

  @spec focus_conversation(State.t()) :: {:ok, State.t()} | {:error, term()}
  defp focus_conversation(state) do
    state = FileTreeCommands.leave_focus(state)
    %{active: active, map: windows} = state.workspace.windows

    case Map.get(windows, active) do
      %{content: {:agent_chat, :semantic}} ->
        {:ok, state}

      _other ->
        case Enum.find(windows, fn {_id, window} -> Content.agent_chat?(window.content) end) do
          {id, _window} -> WindowFocus.focus_result(state, id)
          nil -> {:error, :queue_not_visible}
        end
    end
  end

  @spec focus_queue(State.t(), origin()) :: State.t()
  defp focus_queue(state, origin) do
    ui = state.workspace.agent_ui
    return = if ui.panel.input_focused, do: :composer, else: :transcript

    queue =
      ui.queue
      |> QueueSurface.bind(origin)
      |> QueueSurface.open(return)
      |> QueueSurface.cancel_removal()

    view = ui.view |> View.set_focus(:chat) |> View.clear_prefix()

    next_ui =
      ui
      |> UIState.set_input_focused(false)
      |> UIState.replace_view(view)
      |> UIState.install_queue(queue)

    workspace =
      state.workspace
      |> SessionState.set_agent_ui(next_ui)
      |> SessionState.transition_mode(:normal)

    %{state | workspace: workspace}
  end

  @doc "Runs a focused queue key against the current revision, never against a list position."
  @spec key(State.t(), key_action()) :: State.t()
  def key(state, :queue_close) do
    case QueueSurface.close(state.workspace.agent_ui.queue) do
      {:closed, :composer, surface} ->
        state |> install(surface) |> AgentCommands.scope_focus_input()

      {:closed, :transcript, surface} ->
        state |> install(surface) |> AgentCommands.scope_unfocus_input()

      :not_focused ->
        state
    end
  end

  def key(state, :queue_next), do: move(state, :next)
  def key(state, :queue_previous), do: move(state, :previous)

  def key(state, action) do
    surface = state.workspace.agent_ui.queue
    row_action(state, surface, action, QueueSurface.selected(surface))
  end

  @doc "Removes only the row whose revision was selected at the start of the key sequence."
  @spec remove_displayed(State.t(), QueuedInputSummary.identity() | nil) :: State.t()
  def remove_displayed(state, nil), do: state

  def remove_displayed(state, identity) do
    queue = state.workspace.agent_ui.queue

    case QueueSurface.selected(queue) do
      %QueuedInputSummary{identity: ^identity} = row ->
        row_action(state, queue, :queue_remove, row)

      _changed ->
        refuse(state, :stale_queue_revision)
    end
  end

  @doc "Applies a click only to the conversation and message revisions that were drawn."
  @spec click(
          State.t(),
          {non_neg_integer(), String.t()},
          Queue.action(),
          QueuedInputSummary.identity() | nil,
          QueuedInputSummary.identity() | nil
        ) :: State.t()
  def click(state, {workspace, record}, action, row, source) do
    with {^workspace, _session, ^record} = origin <- current_origin(state),
         %QueueSurface{origin: ^origin} = queue <- state.workspace.agent_ui.queue do
      apply_click(state, queue, action, row, source)
    else
      _stale -> state
    end
  end

  @spec apply_click(
          State.t(),
          QueueSurface.t(),
          Queue.action(),
          QueuedInputSummary.identity() | nil,
          QueuedInputSummary.identity() | nil
        ) :: State.t()
  defp apply_click(state, %{origin: {_, session, _} = origin} = queue, :select, identity, nil) do
    with {:ok, selected} <- QueueSurface.select(queue, identity),
         {:ok, _authority} <- authority(state, session),
         {:ok, focused} <- focus_conversation(state) do
      focused |> install(selected) |> focus_queue(origin)
    else
      _stale -> state
    end
  end

  defp apply_click(state, %{focus: {:focused, _}}, :close, nil, nil),
    do: key(state, :queue_close)

  defp apply_click(
         state,
         %{focus: {:focused, _}, contents: %{pending: [], removed: []}},
         :composer,
         nil,
         nil
       ),
       do: recalled(state)

  defp apply_click(state, %{focus: {:focused, _}} = queue, action, identity, source) do
    case QueueSurface.select(queue, identity) do
      {:ok, selected} ->
        click_row(state, selected, action, QueueSurface.selected(selected), source)

      :stale_row ->
        state
    end
  end

  defp apply_click(state, _queue, _action, _row, _source), do: state

  @spec click_row(
          State.t(),
          QueueSurface.t(),
          Queue.action(),
          QueuedInputSummary.t(),
          QueuedInputSummary.identity() | nil
        ) :: State.t()
  defp click_row(state, queue, :remove, row, nil),
    do: row_action(state, queue, :queue_remove, row)

  defp click_row(state, queue, :edit, row, nil), do: row_action(state, queue, :queue_edit, row)

  defp click_row(state, queue, action, row, source)
       when action in [:paste_after, :paste_before] do
    case Enum.find(queue.contents.removed, &(&1.identity == source)) do
      nil ->
        state

      entry ->
        side = if action == :paste_before, do: :before, else: :after
        paste_from(state, queue, side, row, entry)
    end
  end

  defp click_row(state, _queue, _action, _row, _source), do: state

  @doc "Leaves the queue without restoring its previous focus when another surface takes over."
  @spec blur(State.t()) :: State.t()
  def blur(%State{workspace: %{keymap_scope: :queue}} = state) do
    ui = UIState.blur_queue(state.workspace.agent_ui)
    %{state | workspace: SessionState.set_agent_ui(state.workspace, ui)}
  end

  def blur(%State{} = state), do: state

  @spec move(State.t(), :previous | :next) :: State.t()
  defp move(state, direction),
    do: install(state, QueueSurface.move(state.workspace.agent_ui.queue, direction))

  @spec row_action(State.t(), QueueSurface.t(), key_action(), QueuedInputSummary.t() | nil) ::
          State.t()
  defp row_action(state, %{origin: origin}, :queue_remove, %QueuedInputSummary{identity: identity}),
       do: change(state, origin, {:withdraw_queued_input, identity})

  defp row_action(state, surface, :queue_paste_after, row), do: paste(state, surface, :after, row)

  defp row_action(state, surface, :queue_paste_before, row),
    do: paste(state, surface, :before, row)

  defp row_action(state, %{origin: origin}, :queue_edit, %QueuedInputSummary{identity: identity}),
    do: edit_message(state, origin, identity)

  defp row_action(state, %{contents: %{pending: [], removed: []}}, :queue_edit, nil),
    do: recalled(state)

  defp row_action(state, _surface, _action, _row), do: state

  @spec paste(State.t(), QueueSurface.t(), :before | :after, QueuedInputSummary.t() | nil) ::
          State.t()
  defp paste(
         state,
         %{contents: %{removed: [entry | _]}} = queue,
         side,
         row
       ),
       do: paste_from(state, queue, side, row, entry)

  defp paste(state, _surface, _side, _row), do: state

  @spec paste_from(
          State.t(),
          QueueSurface.t(),
          :before | :after,
          QueuedInputSummary.t() | nil,
          QueuedInputSummary.t()
        ) :: State.t()
  defp paste_from(state, %{origin: origin, contents: %{pending: pending}}, side, row, entry) do
    case pasting_position(entry.kind, pending, side, row) do
      {:ok, position} ->
        change(state, origin, {:place_queued_input, entry.identity, {:removed, position}})

      {:error, reason} ->
        refuse(state, reason)
    end
  end

  @spec pasting_position(
          TurnExecution.prompt_kind(),
          [QueuedInputSummary.t()],
          :before | :after,
          QueuedInputSummary.t() | nil
        ) :: {:ok, TurnExecution.queue_position()} | {:error, :different_queue}
  defp pasting_position(kind, _pending, side, %QueuedInputSummary{kind: kind, identity: identity}),
       do: {:ok, {side, identity}}

  defp pasting_position(_kind, _pending, _side, nil), do: {:ok, :end}

  defp pasting_position(kind, pending, _side, _row) do
    if Enum.any?(pending, &(&1.kind == kind)), do: {:error, :different_queue}, else: {:ok, :end}
  end

  @spec edit_message(State.t(), origin(), QueuedInputSummary.identity()) :: State.t()
  defp edit_message(state, {_, session, _} = origin, identity) when node(session) == node(),
    do: DraftWorkflow.recall_one(state, origin, identity)

  defp edit_message(state, {_, session, record} = origin, identity) do
    case authority(state, session) do
      {:ok, authority} ->
        QueuedInputEdit.open(state, origin, identity, fn
          shown, :read ->
            SessionClient.composer({session, record}, authority, {:read_queued_input_text, shown})

          shown, {:save, text} ->
            SessionClient.composer(
              {session, record},
              authority,
              {:edit_queued_input, shown, text}
            )
        end)

      {:error, reason} ->
        refuse(state, reason)
    end
  end

  @doc "Refreshes the active queue when its Session arrives or reports a change."
  @spec refresh(State.t(), pid()) :: State.t()
  def refresh(state, session) do
    case current_origin(state) do
      {_, ^session, _} = origin -> load(state, origin)
      _other -> state
    end
  end

  @spec load(State.t(), origin()) :: State.t()
  defp load(state, origin) do
    bound = QueueSurface.bind(state.workspace.agent_ui.queue, origin)
    state = install(state, bound)

    case schedule(state, origin, :read_queue_contents) do
      :ok -> state
      {:error, reason} -> report_read_refusal(state, reason)
    end
  end

  @spec change(State.t(), origin(), mutation()) :: State.t()
  defp change(state, origin, operation) do
    case schedule(state, origin, operation) do
      :ok -> state
      {:error, reason} -> refuse(state, reason)
    end
  end

  @doc "After a confirmed single-row recall, return to the originating composer if the queue still owns focus."
  @spec recalled(State.t()) :: State.t()
  def recalled(state) do
    case QueueSurface.close(state.workspace.agent_ui.queue) do
      {:closed, _return, surface} ->
        state |> install(surface) |> AgentCommands.scope_focus_input()

      :not_focused ->
        state
    end
  end

  @doc "Installs the next queue projection without rebinding the draft."
  @spec install(State.t(), QueueSurface.t()) :: State.t()
  def install(%State{workspace: %{agent_ui: %{queue: queue}}} = state, queue), do: state

  def install(%State{} = state, %QueueSurface{} = queue) do
    ui = UIState.install_queue(state.workspace.agent_ui, queue)
    %{state | workspace: SessionState.set_agent_ui(state.workspace, ui)}
  end

  @doc "Explains why an exact action did not complete without claiming an uncertain operation was rolled back."
  @spec refuse(State.t(), term()) :: State.t()
  def refuse(state, reason), do: NoticeWorkflow.publish(state, refusal(reason))

  @impl true
  @spec run(t()) :: {:ok, term()} | {:error, term()}
  def run(%__MODULE__{origin: {_, session, record}, authority: authority, operation: operation}) do
    case call(session, record, authority, operation) do
      {:ok, _result} = ok -> ok
      :ok -> {:ok, :placed}
      {:error, _reason} = error -> error
    end
  catch
    :exit, {:noproc, _call} -> {:error, :disconnected}
    :exit, {:timeout, _call} -> {:error, :timeout}
  end

  @impl true
  @spec apply(State.t(), Outcome.t()) :: {State.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{
          request: %{effect: %{origin: {_, session, _} = origin, authority: captured} = effect},
          value: {status, result}
        } = outcome
      )
      when status in [:completed, :failed] do
    with ^origin <- current_origin(state),
         {:ok, ^captured} <- authority(state, session) do
      {apply_result(state, effect, status, result), outcome}
    else
      _changed -> {state, Outcome.stale(outcome, :stale_target)}
    end
  end

  def apply(state, %Outcome{} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{value: {status, _}}) when status in [:completed, :failed], do: true
  def render?(%Outcome{}), do: false

  @spec apply_result(State.t(), t(), :completed | :failed, term()) :: State.t()
  defp apply_result(
         state,
         %{origin: origin, operation: :read_queue_contents},
         :completed,
         contents
       ) do
    install(state, QueueSurface.refresh(state.workspace.agent_ui.queue, origin, contents))
  end

  defp apply_result(state, %{operation: :read_queue_contents}, :failed, reason),
    do: report_read_refusal(state, reason)

  defp apply_result(state, %{operation: {:withdraw_queued_input, _}}, :completed, expired) do
    case expired do
      0 ->
        NoticeWorkflow.publish(state, "Removed from the queue. It will not be sent.")

      1 ->
        NoticeWorkflow.publish(
          state,
          "Removed from the queue. One removed message is gone for good."
        )

      n ->
        NoticeWorkflow.publish(state, "Removed from the queue. #{n} removals are gone for good.")
    end
  end

  defp apply_result(state, %{operation: {:place_queued_input, _, _}}, :completed, :placed),
    do: NoticeWorkflow.publish(state, "Put the message back in the queue.")

  defp apply_result(state, _effect, :failed, reason), do: refuse(state, reason)

  @spec report_read_refusal(State.t(), term()) :: State.t()
  defp report_read_refusal(state, reason) do
    state = install(state, QueueSurface.read_failed(state.workspace.agent_ui.queue))

    if QueueSurface.focused?(state.workspace.agent_ui.queue),
      do: refuse(state, reason),
      else: state
  end

  @spec schedule(State.t(), origin(), operation()) :: :ok | {:error, term()}
  defp schedule(%State{effect_scheduler: scheduler} = state, {_, session, _} = origin, operation) do
    with :ok <- admit(state, origin),
         {:ok, authority} <- authority(state, session),
         {resource, policy} = scheduling(operation, origin),
         effect = %__MODULE__{origin: origin, authority: authority, operation: operation},
         request = Request.new(effect, resource, policy, timeout_ms: 35_000),
         {:ok, _id, _disposition} <- EffectScheduler.schedule(scheduler, request) do
      :ok
    end
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  @spec admit(State.t(), origin()) :: :ok | {:error, :stale_target | :scheduler_unavailable}
  defp admit(%State{effect_scheduler: nil}, _origin), do: {:error, :scheduler_unavailable}

  defp admit(state, origin) do
    if current_origin(state) == origin, do: :ok, else: {:error, :stale_target}
  end

  @spec scheduling(operation(), origin()) :: {term(), Policy.t()}
  defp scheduling(:read_queue_contents, origin), do: {{:queue_read, origin}, Policy.latest_wins()}
  defp scheduling(_operation, origin), do: {{:queue_change, origin}, Policy.fifo(0)}

  @spec authority(State.t(), pid()) :: {:ok, authority()} | {:error, :not_driver}
  defp authority(_state, session) when node(session) == node(), do: {:ok, :local}

  defp authority(state, session) do
    case QuestionResponse.remote_authority(state, session, self()) do
      {_, _} = authority -> {:ok, authority}
      _not_driver -> {:error, :not_driver}
    end
  end

  @spec call(pid(), String.t(), authority(), operation()) :: Session.composer_result()
  defp call(session, record, :local, :read_queue_contents),
    do: Session.queue_contents(session, record)

  defp call(session, record, :local, {:withdraw_queued_input, identity}),
    do: Session.change_queued_input(session, record, identity, :remove)

  defp call(session, record, :local, {:place_queued_input, identity, placement}),
    do: Session.place_queued_input(session, record, identity, placement)

  defp call(session, record, authority, operation),
    do: SessionClient.composer({session, record}, authority, operation)

  @spec refusal(term()) :: String.t()
  defp refusal(:not_persistent), do: "Open a saved Agent conversation to manage its queue."
  defp refusal(:queue_not_visible), do: "Open the conversation to manage its queue."
  defp refusal(:not_driver), do: "Only the attached driver can manage this queue."
  defp refusal(:stale_target), do: "The conversation changed. No queue action was taken."
  defp refusal(:already_consumed), do: "That message already left the queue."
  defp refusal(:not_removed), do: "That message is already back in the queue."
  defp refusal(:queued_input_not_found), do: "That queued message no longer exists."

  defp refusal(:stale_queue_revision),
    do: "That queued message changed. Review it before trying again."

  defp refusal(:anchor_gone), do: "The message at that position already left the queue."

  defp refusal(:different_queue),
    do: "Steering and next-turn messages cannot be moved between queues."

  defp refusal(:prompt_queue_full), do: "The queue is full. The removed message was not put back."
  defp refusal(:invalid_queue_edit), do: "That queue action is not available for this message."

  defp refusal(:recall_not_ready),
    do: "Wait for the composer draft to finish saving. The queued message was kept."

  defp refusal({:stale_draft_revision, _}),
    do: "The saved composer draft changed. Reload it before recalling the message."

  defp refusal(:draft_attachments_changed),
    do: "Draft attachments changed. Reload the saved attachments before recalling the message."

  defp refusal(:queue_content_not_recallable),
    do: "This message cannot be moved into the composer. It remains queued."

  defp refusal(:disconnected),
    do: "The original Agent conversation disconnected. Check the queue after reconnecting."

  defp refusal(:scheduler_unavailable), do: "The queue action could not start."
  defp refusal(:queue_full), do: "Wait for the current queue action to finish."

  defp refusal(_reason),
    do: "The queue action was not confirmed. Check the queue before retrying."
end
