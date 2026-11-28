defmodule MingaEditor.Shell.Traditional.InFileReview do
  @moduledoc "Applies exact file review decisions and orders dependent Vim input across asynchronous Keep."

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Plural
  alias MingaEditor.Input.Router
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.VimState
  alias MingaEditor.VimState.PendingKeep

  @type decision :: :keep | :reject
  @typep selection_command ::
           {:decide_review_selection, Buffer.t(), BufferProcess.review_selection(),
            {decision(), PendingKeep.continuation()}}
  @typep result ::
           :ok
           | {:ok, [Minga.Buffer.UndoHistory.rejected_unit()]}
           | Minga.Buffer.UndoHistory.blocked()
           | {:error, BufferProcess.review_error() | :buffer_unavailable}

  @spec decide(
          State.t(),
          Buffer.t(),
          BufferProcess.review_selection(),
          decision(),
          PendingKeep.continuation()
        ) :: State.t()
  def decide(state, buffer, selection, decision, continuation \\ :notice) do
    sequence(
      state,
      {:decide_review_selection, buffer, selection, {decision, continuation}},
      &decide_selection/2
    )
  end

  @doc "Acts on the submitted selection, not transient mode state at replay."
  @spec decide_selection(State.t(), selection_command()) :: State.t()
  def decide_selection(
        %{workspace: %{buffers: %{active: buffer}}} = state,
        {:decide_review_selection, buffer, selection, {decision, continuation}}
      ) do
    case Buffer.prepare_review(buffer, selection) do
      {:ok, target, _scope, count} ->
        decide_prepared(state, buffer, target, decision, count, continuation)

      :empty ->
        message =
          case selection do
            {:cursor, _} -> "No pending Minga change at the cursor"
            _ -> "No pending Minga changes in this range"
          end

        NoticeWorkflow.publish(state, message)

      {:error, :invalid_range} ->
        NoticeWorkflow.publish(state, "Invalid review range")

      {:error, :stale_selection} when elem(selection, 0) == :lines ->
        NoticeWorkflow.publish(state, "The selection changed. Select the lines again.")

      {:error, :stale_selection} ->
        NoticeWorkflow.publish(state, "The selection changed. Select the range again.")
    end
  end

  def decide_selection(state, _retargeted), do: state

  @doc "Moves only from the exact still-presented review target in its original window."
  @spec move_presented(
          State.t(),
          {:next_presented_review_change,
           {non_neg_integer(), pid(), non_neg_integer(), pos_integer(), non_neg_integer()}}
        ) :: State.t()
  def move_presented(
        state,
        {:next_presented_review_change, {window, buffer, version, review, point}}
      ) do
    case SessionState.active_window_struct(state.workspace) do
      %MingaEditor.Window{id: ^window, content: {:buffer, ^buffer}} ->
        MingaEditor.Commands.Movement.execute(
          state,
          {:next_minga_change, buffer, version, review, point}
        )

      _changed ->
        state
    end
  end

  @doc "Keeps the exact already-offered blocker, not a reselected unit at the current cursor."
  @spec keep_blocker(State.t(), Buffer.t(), BufferProcess.review_target()) :: State.t()
  def keep_blocker(state, buffer, target),
    do: decide_prepared(state, buffer, target, :keep, 1, :blocking)

  @doc "Applies the exact captured offer; never prepares a new target after selection."
  @spec decide_offer(
          State.t(),
          Buffer.t(),
          BufferProcess.review_target(),
          decision(),
          pos_integer(),
          PendingKeep.continuation()
        ) ::
          State.t()
  def decide_offer(
        %{workspace: %{editing: %{pending_keep: nil}}} = state,
        buffer,
        target,
        decision,
        count,
        continuation
      ),
      do: decide_prepared(state, buffer, target, decision, count, continuation)

  def decide_offer(state, _buffer, _target, _decision, _count, _continuation),
    do: NoticeWorkflow.publish(state, "A review decision is still pending here")

  @spec decide_prepared(
          State.t(),
          Buffer.t(),
          BufferProcess.review_target(),
          decision(),
          pos_integer(),
          PendingKeep.continuation()
        ) :: State.t()
  defp decide_prepared(state, buffer, target, :keep, count, continuation) do
    case Buffer.file_path(buffer) do
      nil -> decide_now(state, buffer, target, :keep, count, continuation)
      _file -> request_keep(state, buffer, target, count, continuation)
    end
  end

  defp decide_prepared(state, buffer, target, :reject, count, continuation),
    do: decide_now(state, buffer, target, :reject, count, continuation)

  @spec request_keep(
          State.t(),
          Buffer.t(),
          BufferProcess.review_target(),
          pos_integer(),
          PendingKeep.continuation()
        ) :: State.t()
  defp request_keep(
         %State{workspace: %{editing: %{pending_keep: nil}}} = state,
         buffer,
         target,
         count,
         continuation
       ) do
    id = make_ref()
    requests = state.interaction.keep_requests || :gen_server.reqids_new()
    requests = Buffer.request_keep(buffer, target, {active_tab_id(state), id}, requests)
    vim = VimState.begin_keep(state.workspace.editing, id, buffer, count, continuation)

    state |> State.put_keep_requests(requests) |> put_editing(vim)
  end

  defp request_keep(state, _buffer, _target, _count, _continuation),
    do: NoticeWorkflow.publish(state, "A review decision is still pending here")

  @doc "Queues a dependent file key without holding other editing contexts."
  @spec defer_key(State.t(), non_neg_integer(), non_neg_integer()) ::
          {:held, State.t()} | :independent
  def defer_key(%State{workspace: %{editing: %{pending_keep: nil}}}, _codepoint, _mods),
    do: :independent

  def defer_key(state, codepoint, modifiers) do
    case VimState.hold_keep_key(
           state.workspace.editing,
           state.workspace.buffers.active,
           {codepoint, modifiers}
         ) do
      {:held, vim} -> {:held, put_editing(state, vim)}
      :independent -> :independent
    end
  end

  @doc "Orders a dependent command before it prepares or mutates a review target."
  @spec sequence(State.t(), Minga.Mode.command(), (State.t(), Minga.Mode.command() -> output)) ::
          State.t() | output
        when output: var
  def sequence(state, command, execute) do
    case VimState.hold_keep_command(
           state.workspace.editing,
           state.workspace.buffers.active,
           command
         ) do
      {:held, vim} -> put_editing(state, vim)
      :independent -> execute.(state, command)
    end
  end

  @doc "Resumes held input only in its original editing context and buffer."
  @spec resume_ready(State.t()) :: State.t()
  def resume_ready(state) do
    case VimState.take_keep_input(state.workspace.editing, state.workspace.buffers.active) do
      {:ok, input, vim} ->
        Enum.reduce(input, put_editing(state, vim), fn
          {:key, {codepoint, modifiers}}, state ->
            Router.route_key(state, codepoint, modifiers)

          {:command, buffer, command}, %{workspace: %{buffers: %{active: buffer}}} = state ->
            KeyDispatch.execute_admitted_command(state, command)

          {:command, _closed_or_retargeted, _command}, state ->
            state
        end)

      :none ->
        state
    end
  end

  @doc "Claims a monitored Buffer reply and applies it only to the originating context."
  @spec response(State.t(), term()) :: {:handled, State.t()} | :unrelated
  def response(%State{interaction: %{keep_requests: nil}}, _message), do: :unrelated

  def response(%State{interaction: %{keep_requests: requests}} = state, message) do
    case :gen_server.check_response(message, requests, true) do
      {{:reply, result}, {tab_id, id}, rest} ->
        {:handled, finish_request(store_outstanding_requests(state, rest), tab_id, id, result)}

      {{:error, _gone}, {tab_id, id}, rest} ->
        state = store_outstanding_requests(state, rest)
        {:handled, finish_request(state, tab_id, id, {:error, :buffer_unavailable})}

      _unrelated ->
        :unrelated
    end
  end

  @spec store_outstanding_requests(State.t(), :gen_server.request_id_collection()) :: State.t()
  defp store_outstanding_requests(state, requests) do
    remaining = if :gen_server.reqids_size(requests) == 0, do: nil, else: requests
    State.put_keep_requests(state, remaining)
  end

  @spec finish_request(State.t(), Tab.id() | nil, reference(), result()) :: State.t()
  defp finish_request(state, tab_id, id, result) do
    if active_tab_id(state) == tab_id,
      do: finish_active(state, id, result),
      else: finish_inactive(state, tab_id, id, result)
  end

  @spec finish_active(State.t(), reference(), result()) :: State.t()
  defp finish_active(state, id, result) do
    %{editing: vim, buffers: %{active: buffer}} = state.workspace

    selection = current_selection(vim, buffer, result)

    case VimState.finish_keep(vim, id, outcome(result), selection) do
      {:ok, keep, updated} ->
        snapshot = Router.capture_snapshot(state)

        state
        |> put_editing(updated)
        |> report(result, keep.count, keep.continuation)
        |> Router.post_action_housekeeping(snapshot)

      :stale ->
        state
    end
  end

  @spec finish_inactive(State.t(), Tab.id() | nil, reference(), result()) :: State.t()
  defp finish_inactive(state, nil, _id, _result), do: state

  defp finish_inactive(state, tab_id, id, result) do
    with %ShellState{} = shell <- Runtime.state(state.shell_runtime),
         %TabBar{} = tab_bar <- ShellState.tab_bar(shell),
         %Tab{
           context: %TabContext{editing: %VimState{} = vim, buffers: %{active: buffer}} = context
         } <- TabBar.get(tab_bar, tab_id),
         selection = current_selection(vim, buffer, result),
         {:ok, _keep, updated} <- VimState.finish_keep(vim, id, outcome(result), selection) do
      context = TabContext.put_fields(context, editing: updated)
      shell = ShellState.install_tab_bar(shell, TabBar.update_context(tab_bar, tab_id, context))
      %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell)}
    else
      _closed_or_changed -> state
    end
  end

  @spec current_selection(VimState.t(), pid() | nil, result()) ::
          {pid() | nil, Buffer.position() | nil}
  defp current_selection(%VimState{mode_state: %Minga.Mode.VisualState{}}, buffer, :ok)
       when is_pid(buffer) do
    {buffer, Buffer.cursor(buffer)}
  catch
    :exit, _ -> {buffer, nil}
  end

  defp current_selection(_vim, buffer, _result), do: {buffer, nil}

  @spec outcome(result()) :: :ok | :refused | :gone
  defp outcome(:ok), do: :ok
  defp outcome({:error, :buffer_unavailable}), do: :gone
  defp outcome(_refused), do: :refused

  @spec active_tab_id(State.t()) :: Tab.id() | nil
  defp active_tab_id(state) do
    case Runtime.traditional_tab_bar(state.shell_runtime) do
      %TabBar{active_id: id} -> id
      nil -> nil
    end
  end

  @spec put_editing(State.t(), VimState.t()) :: State.t()
  defp put_editing(state, vim),
    do: %{state | workspace: SessionState.set_editing(state.workspace, vim)}

  @spec decide_now(
          State.t(),
          Buffer.t(),
          BufferProcess.review_target(),
          decision(),
          pos_integer(),
          PendingKeep.continuation()
        ) :: State.t()
  defp decide_now(state, buffer, target, decision, count, continuation) do
    same_visual? =
      case continuation do
        {:visual, visual, cursor} ->
          vim = state.workspace.editing
          vim.mode_state == visual and current_selection(vim, buffer, :ok) == {buffer, cursor}

        _other ->
          false
      end

    operation =
      case {decision, continuation, same_visual?} do
        {:reject, {:visual, _, _}, false} -> :reject_preserving_cursor
        _unchanged -> decision
      end

    result = Buffer.decide_review(buffer, target, operation)

    state =
      case result do
        :ok -> settle_now(state, :keep, count, continuation, same_visual?)
        {:ok, _} -> settle_now(state, :reject, count, continuation, same_visual?)
        _refused -> state
      end

    report(state, result, count, continuation)
  end

  @spec settle_now(State.t(), decision(), pos_integer(), PendingKeep.continuation(), boolean()) ::
          State.t()
  defp settle_now(state, decision, count, continuation, same_visual?) do
    vim =
      VimState.complete_review(
        state.workspace.editing,
        decision,
        count,
        continuation,
        same_visual?
      )

    put_editing(state, vim)
  end

  @spec report(State.t(), result(), pos_integer(), PendingKeep.continuation()) :: State.t()
  defp report(state, :ok, _count, :blocking),
    do: NoticeWorkflow.publish(state, "Kept the blocking Minga change")

  defp report(state, :ok, count, _continuation),
    do: NoticeWorkflow.publish(state, "Kept #{change_count(count)}")

  defp report(state, {:ok, _receipts}, count, _continuation),
    do: NoticeWorkflow.publish(state, "Rejected #{change_count(count)}")

  defp report(state, {:blocked, {:overlaps, :you}}, _count, _continuation),
    do: NoticeWorkflow.publish(state, "Nothing rejected. Your edit overlaps a selected change.")

  defp report(state, {:blocked, {:overlaps, key}}, _count, _continuation),
    do:
      NoticeWorkflow.publish(
        state,
        "Nothing rejected. An overlapping edit is still pending: #{inspect(key)}."
      )

  defp report(state, {:error, :stale_review}, _count, :blocking),
    do:
      NoticeWorkflow.publish(
        state,
        "Nothing changed. Try undo again to review the current blocker."
      )

  defp report(state, {:error, :stale_review}, _count, _continuation),
    do: NoticeWorkflow.publish(state, "The changes moved. Review the range again.")

  defp report(state, {:error, :buffer_unavailable}, _count, _continuation),
    do: NoticeWorkflow.publish(state, "Nothing changed. The original buffer is unavailable.")

  defp report(state, {:error, reason}, _count, _continuation),
    do: NoticeWorkflow.publish(state, "No review decision was applied: #{inspect(reason)}")

  @spec change_count(pos_integer()) :: String.t()
  defp change_count(count), do: Plural.count(count, "Minga change", "Minga changes")
end
