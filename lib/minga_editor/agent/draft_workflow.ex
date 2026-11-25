defmodule MingaEditor.Agent.DraftWorkflow do
  @moduledoc "Saves and restores draft presentation against its original workspace and record."

  alias Minga.Buffer
  alias MingaAgent.DraftAttachment
  alias MingaAgent.DraftSnapshot
  alias MingaAgent.Session
  alias MingaAgent.Session.TurnExecution
  alias MingaEditor.Agent.{DraftSave, PromptBuffer, QuestionResponse, UIState}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.{NoticeWorkflow, Workflow}
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Agent

  @typep result ::
           :ok
           | {:ok, DraftSave.revision(), DraftSnapshot.t() | nil}
           | {:ok, DraftSave.revision(), DraftSnapshot.attachment()}
           | {:ok, DraftSave.revision()}
           | {:ok, TurnExecution.queue_receipt()}
           | {:accepted, DraftSave.revision(), term()}
           | {:admitted, DraftSave.revision()}
           | {:not_admitted, DraftSave.revision()}
           | {:error, term()}

  @doc "Requests the initial saved revision for an attached composer."
  @spec bind(State.t()) :: State.t()
  def bind(
        %State{
          workspace: %{
            agent_ui:
              %UIState{
                draft_save: nil,
                connection:
                  %{
                    persistent_drafts?: true,
                    target: %{session: session, session_id: id}
                  } = connection,
                panel: %{prompt_buffer: buffer}
              } = ui
          }
        } = state
      )
      when is_pid(session) and is_pid(buffer) do
    with %TabBar{} = tabs <- tab_bar(state),
         ^session <- Runtime.active_session(state.shell_runtime),
         true <- node(session) == node() or Map.get(connection, :remote_composer_drafts?, false) do
      ref = make_ref()
      owner = TabBar.active_workspace_id(tabs)
      target = {session, id}

      case request(state, target, {owner, ref}, :read) do
        :ok ->
          save = DraftSave.loading(target, buffer, ref, Buffer.inspection_marker(buffer))
          Workflow.install_agent_ui(state, UIState.project_draft_save(ui, save))

        {:error, :not_driver} ->
          state

        {:error, _reason} ->
          report(state, :failed)
      end
    else
      _not_an_active_agent -> state
    end
  catch
    :exit, _reason -> state
  end

  def bind(%State{} = state), do: state

  @doc "Resumes draft work when the original remote Session renews its driver receipt."
  @spec driver_reattached(State.t(), pid()) :: State.t()
  def driver_reattached(%State{} = state, session) when node(session) != node() do
    with %TabBar{} = tabs <- tab_bar(state),
         %Workspace{id: owner} <- TabBar.find_workspace_by_session(tabs, session) do
      update_origin(state, owner, &resume_remote_draft(&1, state, owner, session))
    else
      _unowned -> state
    end
  end

  def driver_reattached(%State{} = state, _session), do: bind(state)

  @spec resume_remote_draft(UIState.t(), State.t(), non_neg_integer(), pid()) ::
          {term(), UIState.t()}
  defp resume_remote_draft(
         %UIState{
           draft_save: %DraftSave{
             target: {previous, record} = origin,
             buffer: buffer,
             request: pending
           },
           connection: %{target: %{session: session, session_id: record}},
           panel: %{prompt_buffer: buffer}
         } = ui,
         state,
         owner,
         session
       )
       when node(previous) == node(session) do
    ui = retry_retirement(ui, state, owner)

    case pending do
      {:queueing, _, _, _, _, _} ->
        request_queue_receipt(ui, state, owner, origin, session)

      {:ready, _, _} ->
        {:unchanged, arm_remote_writer(ui, owner, session)}

      {:saving, _, _, _, _} when previous == session ->
        {:unchanged, UIState.project_draft_save(ui, DraftSave.renew_saving_driver(ui.draft_save))}

      {:saving, _, _, _, _} ->
        {:unchanged, arm_remote_writer(ui, owner, session)}

      _other ->
        case initial_read_marker(pending) do
          {:ok, marker} ->
            load_remote_draft(ui, state, owner, {session, record}, buffer, marker)

          :not_initial ->
            {:unchanged, ui}
        end
    end
  end

  defp resume_remote_draft(
         %UIState{
           draft_save: nil,
           connection: %{
             persistent_drafts?: true,
             remote_composer_drafts?: true,
             target: %{session: session, session_id: record}
           },
           panel: %{prompt_buffer: buffer}
         } = ui,
         state,
         owner,
         session
       )
       when is_pid(buffer) do
    load_remote_draft(
      ui,
      state,
      owner,
      {session, record},
      buffer,
      Buffer.inspection_marker(buffer)
    )
  catch
    :exit, _reason -> {:unchanged, ui}
  end

  defp resume_remote_draft(ui, _state, _owner, _session), do: {:unchanged, ui}

  @spec arm_remote_writer(UIState.t(), non_neg_integer(), pid()) :: UIState.t()
  defp arm_remote_writer(%UIState{draft_save: %DraftSave{} = save} = ui, owner, replacement) do
    ui |> UIState.project_draft_save(DraftSave.rebind_writer(save, replacement)) |> arm(owner)
  end

  @spec load_remote_draft(
          UIState.t(),
          State.t(),
          non_neg_integer(),
          DraftSave.target(),
          pid(),
          DraftSave.marker()
        ) :: {term(), UIState.t()}
  defp load_remote_draft(ui, state, owner, target, buffer, marker) do
    ref = make_ref()

    case request(state, target, {owner, ref}, :read) do
      :ok ->
        save = DraftSave.loading(target, buffer, ref, marker)
        {:unchanged, UIState.project_draft_save(ui, save)}

      {:error, _reason} ->
        {:failed, ui}
    end
  end

  @spec initial_read_marker(DraftSave.request()) :: {:ok, DraftSave.marker()} | :not_initial
  defp initial_read_marker({:loading, _ref, marker}), do: {:ok, marker}
  defp initial_read_marker({:load_failed, marker}), do: {:ok, marker}
  defp initial_read_marker(_other), do: :not_initial

  @spec request(
          State.t(),
          DraftSave.target(),
          {non_neg_integer(), reference()},
          Session.remote_composer_operation()
        ) ::
          :ok | {:error, term()}
  defp request(_state, {session, id}, correlation, operation) when node(session) == node(),
    do: Session.request_composer_draft(session, id, correlation, operation)

  defp request(%State{effect_scheduler: nil}, _target, _correlation, _operation),
    do: {:error, :scheduler_unavailable}

  defp request(
         %State{effect_scheduler: scheduler} = state,
         {session, id} = target,
         correlation,
         operation
       ) do
    editor = self()

    with {_driver, _receipt} = authority <-
           QuestionResponse.remote_authority(state, session, editor),
         supervisor = EffectScheduler.task_supervisor(scheduler),
         {:ok, _worker} <-
           Task.Supervisor.start_child(supervisor, fn ->
             result = SessionClient.composer(target, authority, operation)

             send(
               editor,
               {:composer_draft_result, session, id, correlation,
                remote_result(operation, result)}
             )
           end) do
      :ok
    else
      ^editor -> {:error, :not_driver}
      {:error, _reason} = error -> error
    end
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  @spec remote_result(Session.remote_composer_operation(), Session.composer_result()) :: result()
  defp remote_result({:reconcile_queue, _, _, _}, {:error, reason})
       when reason != :queue_receipt_missing,
       do: {:error, {:remote_unavailable, reason}}

  defp remote_result(_operation, result), do: result

  @doc "Checks exact composer buffers before an ordinary close discards their live state."
  @spec before_close(State.t(), :active | :all | non_neg_integer()) ::
          {:ok, State.t()} | {:error, State.t()}
  def before_close(state, scope) do
    case tab_bar(state) do
      %TabBar{} = tabs ->
        active = TabBar.active_workspace_id(tabs)
        ids = close_workspace_ids(tabs, active, scope)
        guard_close(state, tabs, active, ids)

      nil ->
        {:ok, state}
    end
  end

  @spec close_workspace_ids(TabBar.t(), non_neg_integer(), :active | :all | non_neg_integer()) ::
          [non_neg_integer()]
  defp close_workspace_ids(tabs, _active, :all),
    do: for(%Workspace{kind: :agent, id: id} <- tabs.workspaces, do: id)

  defp close_workspace_ids(_tabs, active, :active), do: [active]
  defp close_workspace_ids(_tabs, _active, owner), do: [owner]

  @spec guard_close(State.t(), TabBar.t(), non_neg_integer(), [non_neg_integer()]) ::
          {:ok, State.t()} | {:error, State.t()}
  defp guard_close(state, tabs, active, ids) do
    {state, pending?} =
      Enum.reduce(ids, {state, false}, &guard_workspace_close(&1, &2, tabs, active))

    if pending? do
      message = "Draft unsaved. Close cancelled."

      {:error, state |> NoticeWorkflow.publish(message) |> MingaEditor.schedule_render(16)}
    else
      {:ok, state}
    end
  end

  @spec guard_workspace_close(
          non_neg_integer(),
          {State.t(), boolean()},
          TabBar.t(),
          non_neg_integer()
        ) ::
          {State.t(), boolean()}
  defp guard_workspace_close(owner, {state, _pending?} = acc, tabs, active) do
    with %UIState{draft_save: %DraftSave{} = save} = ui <- close_ui(state, tabs, active, owner),
         true <- unconfirmed?(ui, save) do
      {update_origin(state, owner, &{:unchanged, arm(&1, owner)}), true}
    else
      _confirmed -> acc
    end
  end

  @spec close_ui(State.t(), TabBar.t(), non_neg_integer(), non_neg_integer()) :: UIState.t() | nil
  defp close_ui(state, _tabs, active, active), do: state.workspace.agent_ui

  defp close_ui(_state, tabs, _active, owner) do
    case TabBar.get_workspace(tabs, owner) do
      %Workspace{payload: %Agent{agent_ui: ui}} -> ui
      _other -> nil
    end
  end

  @spec unconfirmed?(UIState.t(), DraftSave.t()) :: boolean()
  defp unconfirmed?(_ui, %DraftSave{retirement: {_, _}}), do: true
  defp unconfirmed?(_ui, %DraftSave{request: {:queueing, _, _, _, _, _}}), do: true

  defp unconfirmed?(_ui, %DraftSave{request: {:ready, _, {_, _} = marker}, buffer: buffer}) do
    Buffer.inspection_marker(buffer) != marker
  catch
    :exit, _reason -> false
  end

  defp unconfirmed?(_ui, %DraftSave{request: {phase, _, _, _, _}})
       when phase in [:saving, :attaching],
       do: true

  defp unconfirmed?(_ui, %DraftSave{request: {:submitting, _, _, _, _, _}}), do: true

  defp unconfirmed?(_ui, %DraftSave{request: {:removing, _, _, _, _, _}}), do: true
  defp unconfirmed?(ui, _save), do: not PromptBuffer.input_empty?(ui)

  @doc "Checks the outgoing composer before an existing Session process changes records."
  @spec before_reopen(State.t(), String.t()) :: :ok | {:error, State.t()}
  def before_reopen(%State{workspace: %{agent_ui: ui}} = state, incoming) do
    case ui.draft_save do
      %DraftSave{target: {_session, ^incoming}} ->
        :ok

      %DraftSave{retirement: {_, _}} ->
        {:error, reopen_notice(state)}

      %DraftSave{request: {:queueing, _, _, _, _, _}} ->
        {:error, reopen_notice(state)}

      %DraftSave{request: {:ready, _revision, marker}, buffer: buffer} ->
        if Buffer.inspection_marker(buffer) == marker,
          do: :ok,
          else: {:error, pending_notice(state, buffer)}

      %DraftSave{request: {phase, _, _, _, _}} when phase in [:saving, :attaching] ->
        {:error, reopen_notice(state)}

      %DraftSave{request: {phase, _, _, _, _, _}} when phase in [:removing, :submitting] ->
        {:error, reopen_notice(state)}

      _unconfirmed ->
        if PromptBuffer.input_empty?(ui),
          do: :ok,
          else: {:error, reopen_notice(state)}
    end
  catch
    :exit, _reason -> {:error, reopen_notice(state)}
  end

  @doc "Attaches a fresh prompt after a different durable record has been successfully opened."
  @spec after_reopen(State.t(), pid(), String.t()) :: State.t()
  def after_reopen(
        %State{
          workspace: %{
            agent_ui:
              %UIState{
                draft_save:
                  %DraftSave{target: {session, incoming}, request: :attachment_review_required} =
                    save
              } = ui
          }
        } = state,
        session,
        incoming
      ) do
    case tab_bar(state) do
      %TabBar{} = tabs ->
        ref = make_ref()
        owner = TabBar.active_workspace_id(tabs)

        case request(state, {session, incoming}, {owner, ref}, :read) do
          :ok ->
            Workflow.install_agent_ui(
              state,
              UIState.project_draft_save(ui, DraftSave.review_attachments(save, ref))
            )

          {:error, _reason} ->
            report(state, :failed)
        end

      nil ->
        state
    end
  catch
    :exit, _reason -> report(state, :failed)
  end

  def after_reopen(
        %State{
          workspace: %{
            agent_ui:
              %UIState{
                connection: %{target: %{session: session, session_id: incoming}},
                draft_save:
                  %DraftSave{
                    target: {previous, incoming},
                    request: {:submission_unconfirmed, revision, id, _}
                  } = save
              } = ui
          }
        } = state,
        session,
        incoming
      )
      when node(previous) == node(session) do
    with ^session <- Runtime.active_session(state.shell_runtime),
         %TabBar{} = tabs <- tab_bar(state),
         target = {session, incoming},
         owner = TabBar.active_workspace_id(tabs),
         ref = make_ref(),
         :ok <- request(state, target, {owner, ref}, {:reconcile_submission, revision, id}) do
      save = DraftSave.check_submission(save, target, ref)
      Workflow.install_agent_ui(state, UIState.project_draft_save(ui, save))
    else
      _unavailable -> report(state, :submission_uncertain)
    end
  end

  def after_reopen(
        %State{
          workspace: %{agent_ui: %UIState{draft_save: %DraftSave{target: {session, incoming}}}}
        } = state,
        session,
        incoming
      ),
      do: recover_recall_conflict(state, session, incoming)

  def after_reopen(
        %State{workspace: %{agent_ui: %UIState{draft_save: nil}}} = state,
        _session,
        _incoming
      ),
      do: state

  def after_reopen(%State{workspace: %{agent_ui: ui}} = state, session, _incoming) do
    old_buffer = ui.panel.prompt_buffer

    fresh =
      ui
      |> UIState.clear_connection()
      |> UIState.detach_prompt_buffer()
      |> UIState.reset_prompt_metadata()
      |> UIState.project_draft_save(nil)
      |> PromptBuffer.ensure()

    if is_pid(old_buffer), do: GenServer.stop(old_buffer, :normal)

    state
    |> Workflow.install_agent_ui(fresh)
    |> MingaEditor.AgentLifecycle.rebuild_agent_from_session(session)
  end

  @doc "Reloads a recalled draft only in the selected original session."
  @spec recover_recall_conflict(State.t(), pid() | nil, String.t() | integer()) :: State.t()
  def recover_recall_conflict(
        %State{
          workspace: %{
            agent_ui:
              %UIState{
                draft_save:
                  %DraftSave{target: {session, id}, request: :recall_conflicted, buffer: buffer} =
                    save
              } = ui
          }
        } = state,
        session,
        id
      ) do
    with true <- PromptBuffer.input_empty?(ui),
         %TabBar{} = tabs <- tab_bar(state),
         ^session <- Runtime.active_session(state.shell_runtime) do
      ref = make_ref()
      owner = TabBar.active_workspace_id(tabs)
      pending = DraftSave.reload_recall(save, ref, Buffer.inspection_marker(buffer))
      :ok = Session.request_composer_draft(session, id, {owner, ref}, :read)
      Workflow.install_agent_ui(state, UIState.project_draft_save(ui, pending))
    else
      _blocked -> report(state, :recall_conflict)
    end
  catch
    :exit, _reason -> report(state, :failed)
  end

  def recover_recall_conflict(state, _session, _id), do: state

  @spec pending_notice(State.t(), pid()) :: State.t()
  defp pending_notice(state, buffer), do: state |> edited(buffer) |> reopen_notice()

  @spec reopen_notice(State.t()) :: State.t()
  defp reopen_notice(state) do
    NoticeWorkflow.publish(
      state,
      "Current draft is not confirmed saved. Keep it here or clear it before reopening."
    )
  end

  @doc "Coalesces a prompt-buffer edit without reading its text on every event."
  @spec edited(State.t(), pid()) :: State.t()
  def edited(
        %State{workspace: %{agent_ui: %UIState{draft_save: %DraftSave{buffer: buffer}} = ui}} =
          state,
        buffer
      ) do
    case tab_bar(state) do
      %TabBar{} = tabs ->
        Workflow.install_agent_ui(state, arm(ui, TabBar.active_workspace_id(tabs)))

      nil ->
        state
    end
  end

  def edited(%State{} = state, buffer) do
    with %TabBar{} = tabs <- tab_bar(state),
         active = TabBar.active_workspace_id(tabs),
         %Workspace{id: owner} <-
           Enum.find(tabs.workspaces, &(&1.id != active and owns_draft_buffer?(&1, buffer))) do
      update_inactive(state, tabs, owner, &{:unchanged, arm(&1, owner)})
    else
      _no_matching_composer -> state
    end
  end

  @doc "Commits a captured snapshot only to the explicitly chosen, still-bound composer."
  @spec attach_text(
          State.t(),
          non_neg_integer(),
          DraftSave.target(),
          DraftAttachment.text_snapshot()
        ) ::
          State.t()
  def attach_text(state, owner, target, snapshot) do
    update_origin(state, owner, &capture_text(state, &1, owner, target, snapshot))
  end

  @doc "Removes only the identified captured revision from the still-bound composer."
  @spec remove_attachment(
          State.t(),
          non_neg_integer(),
          DraftSave.target(),
          DraftAttachment.identity()
        ) ::
          State.t()
  def remove_attachment(state, owner, target, identity) do
    update_origin(state, owner, &commit_attachment_removal(state, &1, owner, target, identity))
  end

  @spec commit_attachment_removal(
          State.t(),
          UIState.t(),
          non_neg_integer(),
          DraftSave.target(),
          DraftAttachment.identity()
        ) ::
          {term(), UIState.t()}
  defp commit_attachment_removal(
         state,
         %UIState{
           draft_save: %DraftSave{target: target, buffer: buffer} = save,
           panel: %{prompt_buffer: buffer}
         } = ui,
         owner,
         target,
         identity
       ) do
    ref = make_ref()
    marker = Buffer.inspection_marker(buffer)

    with {:ok, revision, pending, remaining} <-
           DraftSave.begin_removal(save, ref, marker, identity),
         {:ok, snapshot} <- PromptBuffer.draft_snapshot(ui, remaining),
         :ok <- request(state, target, {owner, ref}, {:remove_attachment, revision, snapshot}) do
      {:unchanged, UIState.project_draft_save(ui, pending)}
    else
      {:error, :private_input} -> {:private_attachment, ui}
      _not_ready -> {:attachment_not_ready, ui}
    end
  catch
    :exit, _reason -> {:attachment_not_ready, ui}
  end

  defp commit_attachment_removal(_state, ui, _owner, _target, _identity),
    do: {:attachment_not_ready, ui}

  @spec capture_text(
          State.t(),
          UIState.t(),
          non_neg_integer(),
          DraftSave.target(),
          DraftAttachment.text_snapshot()
        ) ::
          {term(), UIState.t()}
  defp capture_text(
         state,
         %UIState{
           draft_save: %DraftSave{target: target, buffer: buffer} = save,
           panel: %{prompt_buffer: buffer}
         } = ui,
         owner,
         target,
         snapshot
       ) do
    ref = make_ref()
    marker = Buffer.inspection_marker(buffer)

    with {:ok, revision, pending} <- DraftSave.begin_attachment(save, ref, marker),
         {:ok, draft} <- PromptBuffer.draft_snapshot(ui, save.attachments),
         draft =
           draft || %DraftSnapshot{text: "", cursor: {0, 0}, paste_blocks: [], attachments: []},
         :ok <- request(state, target, {owner, ref}, {:attach_text, revision, draft, snapshot}) do
      {:unchanged, UIState.project_draft_save(ui, pending)}
    else
      {:error, :private_input} -> {:private_attachment, ui}
      _not_ready -> {:attachment_not_ready, ui}
    end
  catch
    :exit, _reason -> {:attachment_not_ready, ui}
  end

  defp capture_text(_state, ui, _owner, _target, _snapshot),
    do: {:attachment_not_ready, ui}

  @spec owns_draft_buffer?(Workspace.t(), pid()) :: boolean()
  defp owns_draft_buffer?(
         %Workspace{
           payload: %Agent{
             agent_ui: %UIState{
               draft_save: %DraftSave{buffer: buffer},
               panel: %{prompt_buffer: buffer}
             }
           }
         },
         buffer
       ),
       do: true

  defp owns_draft_buffer?(_workspace, _buffer), do: false

  @doc "Submits against the displayed active turn of the original saved composer."
  @spec queue(State.t(), TurnExecution.prompt_kind(), TurnExecution.content()) ::
          {:saved, State.t()} | :ordinary
  def queue(%State{} = state, kind, content) do
    queue(state, kind, content, :current)
  end

  @doc "Submits only to the saved queue target echoed from the displayed control."
  @spec queue(
          State.t(),
          TurnExecution.prompt_kind(),
          TurnExecution.content(),
          Session.queue_target() | :current
        ) ::
          {:saved, State.t()} | :ordinary
  def queue(%State{} = state, kind, content, expected) do
    agent = TraditionalState.agent(state.shell_runtime.state)

    with {session, {record, _, _} = target} <- agent.queue_target,
         true <- expected in [:current, target],
         true <- supports_saved_queue?(state.workspace.agent_ui, session),
         ^session <- Runtime.active_session(state.shell_runtime),
         %TabBar{} = tabs <- tab_bar(state) do
      owner = TabBar.active_workspace_id(tabs)
      update = &capture_queue(&1, state, owner, {session, record}, target, kind, content)
      {:saved, update_origin(state, owner, update)}
    else
      _no_active_target -> :ordinary
    end
  end

  @spec supports_saved_queue?(UIState.t(), pid()) :: boolean()
  defp supports_saved_queue?(_ui, session) when node(session) == node(), do: true

  defp supports_saved_queue?(
         %UIState{connection: %{remote_composer_drafts?: true, target: %{session: session}}},
         session
       ),
       do: true

  defp supports_saved_queue?(_ui, _session), do: false

  @spec capture_queue(
          UIState.t(),
          State.t(),
          non_neg_integer(),
          DraftSave.target(),
          Session.queue_target(),
          TurnExecution.prompt_kind(),
          TurnExecution.content()
        ) :: {term(), UIState.t()}
  defp capture_queue(
         %UIState{draft_save: %DraftSave{target: destination, retirement: {_, _}}} = ui,
         state,
         owner,
         destination,
         _target,
         _kind,
         _content
       ),
       do: {:queue_not_ready, retry_retirement(ui, state, owner)}

  defp capture_queue(
         %UIState{
           draft_save: %DraftSave{target: destination, buffer: buffer}
         } = ui,
         state,
         owner,
         destination,
         target,
         kind,
         content
       ) do
    capture_queue(
      ui,
      state,
      owner,
      destination,
      target,
      kind,
      content,
      Buffer.inspection_marker(buffer)
    )
  catch
    :exit, _reason -> {:queue_not_ready, ui}
  end

  defp capture_queue(ui, _state, _owner, _destination, _target, _kind, _content),
    do: {:queue_not_ready, ui}

  # `marker` is the composer as it was when the key was pressed. A queue held
  # behind an autosave runs later with that marker, so text typed after the
  # press stays in the composer instead of being cleared with the queued input.
  @spec capture_queue(
          UIState.t(),
          State.t(),
          non_neg_integer(),
          DraftSave.target(),
          Session.queue_target(),
          TurnExecution.prompt_kind(),
          TurnExecution.content(),
          DraftSave.marker()
        ) :: {term(), UIState.t()}
  defp capture_queue(
         %UIState{
           draft_save: %DraftSave{target: destination, buffer: buffer} = save,
           panel: %{prompt_buffer: buffer}
         } = ui,
         state,
         owner,
         {_session, record} = destination,
         {record, _, sequence} = target,
         kind,
         content,
         marker
       ) do
    ref = make_ref()
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    shown = Enum.map(save.attachments, &DraftAttachment.identity/1)

    with false <- nil in shown,
         {:ok, revision, pending} <-
           DraftSave.begin_queue(save, ref, marker, {sequence, token, kind}) do
      operation =
        {:queue, target, kind, {revision, token, shown, PromptBuffer.prompt_text(ui)}, content}

      case request(state, destination, {owner, ref}, operation) do
        :ok -> {:unchanged, UIState.project_draft_save(ui, pending)}
        {:error, _reason} -> {:queue_not_ready, ui}
      end
    else
      :pending -> defer_queue(ui, save, {target, kind, content, marker})
      _unavailable -> {:queue_not_ready, ui}
    end
  catch
    :exit, _reason -> {:queue_not_ready, ui}
  end

  defp capture_queue(ui, _state, _owner, _destination, _target, _kind, _content, _marker),
    do: {:queue_not_ready, ui}

  # The composer's own autosave is answering: hold the queue and run it when the
  # save does (`release_deferred_queue/4`), so a fast typist is never refused.
  @spec defer_queue(UIState.t(), DraftSave.t(), DraftSave.deferred_queue()) ::
          {:unchanged | :queue_not_ready, UIState.t()}
  defp defer_queue(ui, save, deferred) do
    case DraftSave.defer_queue(save, deferred) do
      {:ok, held} -> {:unchanged, UIState.project_draft_save(ui, held)}
      :pending -> {:queue_not_ready, ui}
    end
  end

  # Runs a queue held behind an autosave once the save has answered. A save that
  # left the composer unable to queue reports the refusal it would have shown.
  @spec release_deferred_queue(
          {term(), UIState.t()},
          State.t(),
          non_neg_integer(),
          DraftSave.target()
        ) :: {term(), UIState.t()}
  defp release_deferred_queue(
         {outcome, %UIState{draft_save: %DraftSave{} = save} = ui},
         state,
         owner,
         destination
       ) do
    case DraftSave.release_deferred_queue(save) do
      :none ->
        {outcome, ui}

      {:drop, released} ->
        {:queue_not_ready, UIState.project_draft_save(ui, released)}

      {:run, {target, kind, content, marker}, released} ->
        ui
        |> UIState.project_draft_save(released)
        |> capture_queue(state, owner, destination, target, kind, content, marker)
        |> keep_outcome(outcome)
    end
  end

  defp release_deferred_queue(result, _state, _owner, _destination), do: result

  # The save's own outcome stays unless the held queue has something to say.
  @spec keep_outcome({term(), UIState.t()}, term()) :: {term(), UIState.t()}
  defp keep_outcome({:unchanged, ui}, outcome), do: {outcome, ui}
  defp keep_outcome(result, _outcome), do: result

  @doc "Checks a pending local admission against the recovered owner without submitting it again."
  @spec reconcile_restarted_queue(State.t(), String.t(), pid(), pid()) :: State.t()
  def reconcile_restarted_queue(state, record, previous, replacement)
      when node(previous) == node() and node(replacement) == node() do
    with %TabBar{} = tabs <- tab_bar(state),
         %Workspace{id: owner} <- TabBar.find_workspace_by_session(tabs, replacement) do
      update_origin(
        state,
        owner,
        &request_queue_receipt(&1, state, owner, {previous, record}, replacement)
      )
    else
      _unowned -> state
    end
  end

  def reconcile_restarted_queue(state, _record, _previous, _replacement), do: state

  @spec request_queue_receipt(
          UIState.t(),
          State.t(),
          non_neg_integer(),
          DraftSave.target(),
          pid()
        ) ::
          {term(), UIState.t()}
  defp request_queue_receipt(
         %UIState{draft_save: %DraftSave{buffer: buffer} = save, panel: %{prompt_buffer: buffer}} =
           ui,
         state,
         owner,
         {_previous, record} = origin,
         replacement
       ) do
    case DraftSave.rebind_queue(save, origin, replacement) do
      {:ok, ref, previous, {sequence, token, _kind}, rebound} ->
        op = {:reconcile_queue, sequence, token, previous}

        case request(state, {replacement, record}, {owner, ref}, op) do
          :ok -> {:unchanged, UIState.project_draft_save(ui, rebound)}
          {:error, _reason} -> {:queue_receipt_unconfirmed, ui}
        end

      :stale ->
        {:unchanged, ui}
    end
  end

  defp request_queue_receipt(ui, _state, _owner, _origin, _replacement), do: {:unchanged, ui}

  @doc "Recalls saved input into the original workspace without blocking the Editor process."
  @spec recall(State.t(), pid()) :: {:saved, State.t()} | :volatile
  def recall(
        %State{workspace: %{agent_ui: %UIState{draft_save: %DraftSave{target: {session, _}}}}} =
          state,
        session
      ) do
    case tab_bar(state) do
      %TabBar{} = tabs ->
        owner = TabBar.active_workspace_id(tabs)
        ref = make_ref()
        {:saved, update_origin(state, owner, &capture_recall(&1, owner, ref))}

      nil ->
        {:saved, report(state, :recall_not_ready)}
    end
  end

  def recall(
        %State{
          workspace: %{
            agent_ui: %UIState{
              connection: %{persistent_drafts?: true, target: %{session: session}}
            }
          }
        } = state,
        session
      ),
      do: {:saved, report(state, :recall_not_ready)}

  def recall(_state, _session), do: :volatile

  @doc "Starts volatile queue recall without waiting for the arriving local Session."
  @spec recall_volatile(State.t(), pid()) :: State.t()
  def recall_volatile(state, session) do
    with %{target: %{session: ^session}, conversation: conversation}
         when is_reference(conversation) <-
           state.workspace.agent_ui.connection,
         %TabBar{} = tabs <- tab_bar(state),
         owner when is_integer(owner) <- TabBar.active_workspace_id(tabs) do
      :ok = Session.request_volatile_queue_recall(session, conversation, owner)
      state
    else
      _unconfirmed -> state
    end
  end

  @doc "Restores recalled input to the originating conversation without replacing newer draft text."
  @spec apply_volatile_recall(
          State.t(),
          pid(),
          reference(),
          pos_integer(),
          [String.t() | [ReqLLM.Message.ContentPart.t()]]
        ) :: State.t()
  def apply_volatile_recall(state, _session, _conversation, _owner, []), do: state

  def apply_volatile_recall(state, session, conversation, owner, queued) do
    update_origin(state, owner, fn
      %UIState{connection: %{target: %{session: ^session}, conversation: ^conversation}} = ui ->
        restored = Session.combine_queue_entries_to_text(queued)
        draft = PromptBuffer.prompt_text(ui)
        text = if draft == "", do: restored, else: restored <> "\n\n" <> draft
        {:unchanged, PromptBuffer.set_prompt_text(ui, text)}

      ui ->
        {:unchanged, ui}
    end)
    |> MingaEditor.schedule_render(16)
  end

  @spec capture_recall(UIState.t(), non_neg_integer(), reference()) :: {term(), UIState.t()}
  defp capture_recall(
         %UIState{
           draft_save: %DraftSave{target: {session, id}, buffer: buffer} = save,
           panel: %{prompt_buffer: buffer}
         } = ui,
         owner,
         ref
       )
       when node(session) == node() do
    marker = Buffer.inspection_marker(buffer)

    with {:ok, revision, pending} <- DraftSave.begin_recall(save, ref, marker),
         {:ok, snapshot} <- PromptBuffer.draft_snapshot(ui, save.attachments) do
      :ok =
        Session.request_composer_draft(
          session,
          id,
          {owner, ref},
          {:recall, revision, snapshot, :keep_running}
        )

      {:unchanged, UIState.project_draft_save(ui, pending)}
    else
      _not_ready -> {:recall_not_ready, ui}
    end
  catch
    :exit, _reason -> {:recall_not_ready, ui}
  end

  defp capture_recall(ui, _owner, _ref), do: {:recall_not_ready, ui}

  @doc "Commits the newest prompt snapshot for the workspace that armed the timer."
  @spec due(State.t(), non_neg_integer(), reference()) :: State.t()
  def due(state, owner, token),
    do: update_origin(state, owner, &save_due(state, &1, owner, token))

  @doc "Installs only a result for the original workspace, record and outstanding request."
  @spec handle_result(State.t(), pid(), String.t(), non_neg_integer(), reference(), result()) ::
          State.t()
  def handle_result(state, _session, id, owner, ref, :ok) do
    update_origin(state, owner, fn
      %UIState{draft_save: %DraftSave{target: {_, ^id}, retirement: {^ref, _}} = save} = ui ->
        {:unchanged, UIState.project_draft_save(ui, DraftSave.queue_receipt_retired(save, ref))}

      ui ->
        {:unchanged, ui}
    end)
  end

  def handle_result(state, session, id, owner, ref, result) do
    update_origin(state, owner, fn
      %UIState{
        draft_save: %DraftSave{target: {^session, ^id}, buffer: buffer} = save,
        panel: %{prompt_buffer: buffer}
      } = ui ->
        {outcome, updated} = apply_result(ui, save, owner, ref, result)

        acknowledged =
          acknowledge_accepted_queue(updated, state, {session, id}, owner, outcome, result)

        release_deferred_queue({outcome, acknowledged}, state, owner, {session, id})

      ui ->
        {:unchanged, ui}
    end)
  end

  @spec acknowledge_accepted_queue(
          UIState.t(),
          State.t(),
          DraftSave.target(),
          non_neg_integer(),
          term(),
          result()
        ) :: UIState.t()
  defp acknowledge_accepted_queue(ui, _state, {session, id}, _owner, outcome, {:ok, receipt})
       when node(session) == node() and
              (outcome == :queued_older_draft or elem(outcome, 0) == :queued) do
    Session.confirm_queue_receipt(session, id, receipt)
    ui
  end

  defp acknowledge_accepted_queue(
         %UIState{draft_save: %DraftSave{} = save} = ui,
         state,
         _target,
         owner,
         outcome,
         {:ok, receipt}
       )
       when outcome == :queued_older_draft or elem(outcome, 0) == :queued do
    save = DraftSave.retire_queue_receipt(save, make_ref(), receipt)
    retry_retirement(UIState.project_draft_save(ui, save), state, owner)
  end

  defp acknowledge_accepted_queue(ui, _state, _target, _owner, _outcome, _result), do: ui

  @spec retry_retirement(UIState.t(), State.t(), non_neg_integer()) :: UIState.t()
  defp retry_retirement(
         %UIState{
           draft_save: %DraftSave{target: {previous, record}, retirement: {_, receipt}} = save,
           connection: %{target: %{session: session, session_id: record}}
         } = ui,
         state,
         owner
       )
       when node(previous) == node(session) do
    ref = make_ref()

    case request(state, {session, record}, {owner, ref}, {:confirm_queue_receipt, receipt}) do
      :ok -> UIState.project_draft_save(ui, DraftSave.retire_queue_receipt(save, ref, receipt))
      {:error, _reason} -> ui
    end
  end

  defp retry_retirement(ui, _state, _owner), do: ui

  @spec arm(UIState.t(), non_neg_integer()) :: UIState.t()
  defp arm(%UIState{draft_save: %DraftSave{} = save} = ui, owner) do
    token = make_ref()

    case DraftSave.schedule(save, token) do
      {:ok, scheduled} ->
        Process.send_after(self(), {:composer_draft_due, owner, token}, 350)
        UIState.project_draft_save(ui, scheduled)

      :pending ->
        ui
    end
  end

  @spec save_due(State.t(), UIState.t(), non_neg_integer(), reference()) :: {term(), UIState.t()}
  defp save_due(
         state,
         %UIState{draft_save: %DraftSave{buffer: buffer} = save, panel: %{prompt_buffer: buffer}} =
           ui,
         owner,
         token
       ) do
    case DraftSave.due(save, token) do
      {:ok, save} -> persist(state, UIState.project_draft_save(ui, save), save, owner)
      :stale -> {:unchanged, ui}
    end
  end

  defp save_due(_state, ui, _owner, _token), do: {:unchanged, ui}

  @spec persist(State.t(), UIState.t(), DraftSave.t(), non_neg_integer()) :: {term(), UIState.t()}
  defp persist(state, ui, %DraftSave{target: target, buffer: buffer} = save, owner) do
    ref = make_ref()
    marker = Buffer.inspection_marker(buffer)

    with {:ok, revision, pending} <- DraftSave.begin_save(save, ref, marker),
         {:ok, snapshot} <- PromptBuffer.draft_snapshot(ui, save.attachments),
         :ok <- request(state, target, {owner, ref}, {:save, revision, snapshot}) do
      {:unchanged, UIState.project_draft_save(ui, pending)}
    else
      {:error, :private_input} -> {:unchanged, ui}
      {:error, _reason} -> {:failed, ui}
      _already_current_or_pending -> {:unchanged, ui}
    end
  catch
    :exit, _reason -> {:failed, ui}
  end

  @doc "Keeps submission blocked until a capable remote Session has offered its saved draft."
  @spec submission(State.t()) ::
          :ordinary
          | {:attached, DraftSave.target(), [DraftAttachment.identity()]}
          | {:remote, DraftSave.target()}
          | {:error, String.t()}
  def submission(%State{
        workspace: %{
          agent_ui: %UIState{
            draft_save: nil,
            connection: %{remote_composer_drafts?: true, target: %{session: session}}
          }
        }
      })
      when node(session) != node(),
      do: {:error, "Wait for the original Agent conversation to load its saved draft."}

  def submission(%State{
        workspace: %{
          agent_ui: %UIState{
            draft_save: %DraftSave{target: {session, id}},
            connection: %{target: %{session: current, session_id: current_id}}
          }
        }
      })
      when node(session) != node() and (session != current or id != current_id),
      do: {:error, "The Agent conversation changed. The draft was not sent."}

  def submission(%State{
        workspace: %{
          agent_ui: %UIState{
            draft_save: %DraftSave{request: :attachment_review_required, target: {session, _id}}
          }
        }
      })
      when node(session) != node(),
      do: {:error, "Open Draft attachments to reload the saved context before sending."}

  def submission(%State{
        workspace: %{
          agent_ui: %UIState{draft_save: %DraftSave{request: :blocked, target: {session, _id}}}
        }
      })
      when node(session) != node(),
      do:
        {:error,
         "The saved draft could not be confirmed. Reconnect to the original Agent conversation before sending."}

  def submission(%State{
        workspace: %{
          agent_ui: %UIState{draft_save: %DraftSave{target: {session, _} = target} = save}
        },
        frontend: frontend
      })
      when node(session) != node() do
    case DraftSave.submission(save, frontend.composer_input_offer) do
      :ordinary -> {:remote, target}
      result -> result
    end
  end

  def submission(%State{workspace: %{agent_ui: ui}, frontend: frontend}),
    do: DraftSave.submission(ui.draft_save, frontend.composer_input_offer)

  @doc "Submits the displayed attachments without blocking editing or changing another workspace."
  @spec submit_remote(
          State.t(),
          DraftSave.target(),
          [DraftAttachment.identity()],
          String.t() | [ReqLLM.Message.ContentPart.t()]
        ) :: State.t()
  def submit_remote(
        %State{
          workspace: %{
            agent_ui:
              %UIState{
                draft_save:
                  %DraftSave{target: target, buffer: buffer, request: {:ready, revision, _}} =
                    save,
                panel: %{prompt_buffer: buffer}
              } = ui
          }
        } = state,
        {session, _record} = target,
        shown,
        content
      )
      when node(session) != node() do
    with %TabBar{} = tabs <- tab_bar(state),
         ^session <- Runtime.active_session(state.shell_runtime),
         owner = TabBar.active_workspace_id(tabs),
         ref = make_ref(),
         id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
         {:ok, pending} <-
           DraftSave.begin_submission(save, ref, Buffer.inspection_marker(buffer), id),
         :ok <- request(state, target, {owner, ref}, {:submit, revision, id, shown, content}) do
      Workflow.install_agent_ui(state, UIState.project_draft_save(ui, pending))
    else
      _reason -> report(state, :submission_refused)
    end
  catch
    :exit, _reason -> report(state, :submission_refused)
  end

  def submit_remote(state, _target, _shown, _content), do: report(state, :submission_refused)

  @spec apply_result(UIState.t(), DraftSave.t(), non_neg_integer(), reference(), result()) ::
          {term(), UIState.t()}
  defp apply_result(
         ui,
         %DraftSave{request: {phase, ref, initial}} = save,
         owner,
         ref,
         {:ok, revision, draft}
       )
       when phase in [:loading, :reloading_recall] do
    case restore_loaded(ui, save, initial, draft) do
      {:ok, restored, restored_save, marker} ->
        installed =
          UIState.project_draft_save(
            restored,
            DraftSave.loaded(restored_save, revision, marker, draft)
          )

        {:restored, arm(installed, owner)}

      :edited when phase == :reloading_recall ->
        fail_result(ui, save, ref, :blocked)

      :edited when is_struct(draft, DraftSnapshot) and draft.attachments != [] ->
        {:failed, UIState.project_draft_save(ui, DraftSave.conflicted(save, draft))}

      :edited ->
        fail_result(ui, save, ref, :blocked)
    end
  end

  defp apply_result(
         ui,
         %DraftSave{
           request: {:queueing, ref, previous, _, initial, {sequence, token, kind}},
           buffer: buffer
         } = save,
         owner,
         ref,
         {:ok, {sequence, token, kind, revision}}
       )
       when revision == previous + 1 do
    if Buffer.inspection_marker(buffer) == initial do
      cleared = PromptBuffer.clear_input_and_scroll(ui)
      updated = DraftSave.queue_saved(save, ref, revision, Buffer.inspection_marker(buffer))
      {{:queued, kind}, UIState.project_draft_save(cleared, updated)}
    else
      updated = DraftSave.queue_saved(save, ref, revision, nil)
      {:queued_older_draft, arm(UIState.project_draft_save(ui, updated), owner)}
    end
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:queueing, ref, _, _, _, _}, target: {session, _}},
         _owner,
         ref,
         {:error, {:remote_unavailable, _reason}}
       )
       when node(session) != node(),
       do: {:queue_receipt_unconfirmed, ui}

  defp apply_result(
         ui,
         %DraftSave{request: {:queueing, ref, _, _, _, _}} = save,
         owner,
         ref,
         result
       ) do
    disposition =
      case result do
        {:error, {:stale_draft_revision, _}} -> :blocked
        {:error, :stale_target} -> :blocked
        {:error, :queue_receipt_unconfirmed} -> :blocked
        {:ok, _other_receipt} -> :blocked
        _refused -> :retryable
      end

    updated = DraftSave.queue_refused(save, ref, disposition)

    notice =
      case result do
        {:error, :queue_receipts_full} -> :queue_receipts_full
        {:error, :queue_receipt_unconfirmed} -> :queue_receipt_unconfirmed
        _other -> :queue_refused
      end

    {notice, arm(UIState.project_draft_save(ui, updated), owner)}
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:recalling, ref, _, _, initial}} = save,
         owner,
         ref,
         {:ok, revision, %DraftSnapshot{} = draft}
       ) do
    case install_snapshot(ui, save, initial, draft) do
      {:ok, restored, restored_save, marker} ->
        updated =
          DraftSave.recall_result(restored_save, ref, {:installed, revision, marker, draft})

        {:recalled, arm(UIState.project_draft_save(restored, updated), owner)}

      :edited ->
        {:recall_conflict,
         UIState.project_draft_save(ui, DraftSave.recall_result(save, ref, :conflict))}
    end
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:recalling, ref, _, _, _}} = save,
         owner,
         ref,
         {:error, :no_pending_inputs}
       ) do
    {:ok, ready} = DraftSave.failed(save, ref, :retryable)
    {:unchanged, arm(UIState.project_draft_save(ui, ready), owner)}
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:recalling, ref, _, _, _}} = save,
         _owner,
         ref,
         {:error, {:stale_draft_revision, _}}
       ),
       do: fail_result(ui, save, ref, :blocked)

  defp apply_result(
         ui,
         %DraftSave{request: {:recalling, ref, _, _, _}} = save,
         owner,
         ref,
         {:error, :stale_turn}
       ) do
    {:ok, ready} = DraftSave.failed(save, ref, :retryable)
    {:stale_stop, arm(UIState.project_draft_save(ui, ready), owner)}
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:recalling, ref, _, _, _}} = save,
         owner,
         ref,
         {:error, _reason}
       ) do
    {:ok, ready} = DraftSave.failed(save, ref, :retryable)
    {:recall_refused, arm(UIState.project_draft_save(ui, ready), owner)}
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:reviewing_attachments, ref}} = save,
         owner,
         ref,
         {:ok, revision, draft}
       )
       when is_struct(draft, DraftSnapshot) or is_nil(draft) do
    reviewed = DraftSave.attachments_reviewed(save, revision, draft)
    {:attachments_reloaded, arm(UIState.project_draft_save(ui, reviewed), owner)}
  end

  defp apply_result(ui, save, owner, ref, {:ok, revision, {_kind, _, _, _, _} = attachment}) do
    case DraftSave.attached(save, ref, revision, attachment) do
      {:ok, saved} -> {:attached, arm(UIState.project_draft_save(ui, saved), owner)}
      :stale -> {:unchanged, ui}
    end
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:removing, ref, _, _, _, _}} = save,
         owner,
         ref,
         {:ok, revision}
       ) do
    {:ok, saved} = DraftSave.saved(save, ref, revision)
    {:attachment_removed, arm(UIState.project_draft_save(ui, saved), owner)}
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:submitting, ref, _, _, {version, _}, _}} = save,
         owner,
         ref,
         {:ok, revision}
       ),
       do: settle_submission(ui, save, owner, ref, revision, version, :restored)

  defp apply_result(
         ui,
         %DraftSave{request: {:submitting, ref, _, _, {version, _}, _}} = save,
         owner,
         ref,
         {:accepted, revision, _reason}
       ),
       do: settle_submission(ui, save, owner, ref, revision, version, :submitted_offline)

  defp apply_result(
         ui,
         %DraftSave{request: {:submitting, ref, _, _, _, _}} = save,
         _owner,
         ref,
         {:error, reason}
       ) do
    {outcome, disposition} = submission_failure(reason)
    {:ok, failed} = DraftSave.failed(save, ref, disposition)
    {outcome, UIState.project_draft_save(ui, failed)}
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:checking_submission, ref, _, _, {version, _}}} = save,
         owner,
         ref,
         {:admitted, revision}
       ),
       do: settle_submission(ui, save, owner, ref, revision, version, :submission_recovered)

  defp apply_result(
         ui,
         %DraftSave{request: {:checking_submission, ref, _, _, _}} = save,
         _owner,
         ref,
         {:error, _reason}
       ) do
    {:ok, pending} = DraftSave.failed(save, ref, :unconfirmed)
    {:submission_uncertain, UIState.project_draft_save(ui, pending)}
  end

  defp apply_result(
         ui,
         %DraftSave{request: {:checking_submission, ref, _, _, _}} = save,
         owner,
         ref,
         {:not_admitted, revision}
       ) do
    ready = DraftSave.submission_refused(save, ref, revision)
    {:submission_refused, arm(UIState.project_draft_save(ui, ready), owner)}
  end

  defp apply_result(ui, save, owner, ref, {:ok, revision}) do
    case DraftSave.saved(save, ref, revision) do
      {:ok, saved} -> {:unchanged, arm(UIState.project_draft_save(ui, saved), owner)}
      :stale -> {:unchanged, ui}
    end
  end

  defp apply_result(ui, save, _owner, ref, {:error, {:stale_draft_revision, _}}),
    do: fail_result(ui, save, ref, :blocked)

  defp apply_result(
         ui,
         save,
         _owner,
         ref,
         {:error, {:draft_commit_uncertain, :attach_draft, _, _}}
       ),
       do: fail_result(ui, save, ref, :blocked)

  defp apply_result(
         ui,
         %DraftSave{request: {phase, _, _, _, _}} = save,
         _owner,
         ref,
         {:error, {:remote_unavailable, _}}
       )
       when phase in [:attaching],
       do: fail_result(ui, save, ref, :blocked)

  defp apply_result(
         ui,
         %DraftSave{request: {:removing, _, _, _, _, _}} = save,
         _owner,
         ref,
         {:error, {:remote_unavailable, _}}
       ),
       do: fail_result(ui, save, ref, :blocked)

  defp apply_result(ui, save, _owner, ref, {:error, reason})
       when reason in [:stale_target, :not_persistent],
       do: fail_result(ui, save, ref, :blocked)

  defp apply_result(
         ui,
         %DraftSave{request: {:saving, ref, _, _, _}, rearm_on_save_failure: true} = save,
         owner,
         ref,
         {:error, _reason}
       ) do
    {outcome, updated} = fail_result(ui, save, ref, :retryable)
    {outcome, arm(updated, owner)}
  end

  defp apply_result(ui, save, _owner, ref, {:error, _reason}),
    do: fail_result(ui, save, ref, :retryable)

  defp apply_result(ui, _save, _owner, _ref, _result), do: {:unchanged, ui}

  @spec settle_submission(
          UIState.t(),
          DraftSave.t(),
          non_neg_integer(),
          reference(),
          DraftSave.revision(),
          non_neg_integer(),
          atom()
        ) ::
          {atom(), UIState.t()}
  defp settle_submission(
         ui,
         %DraftSave{buffer: buffer} = save,
         owner,
         ref,
         revision,
         version,
         outcome
       ) do
    {ui, marker} =
      if Buffer.version(buffer) == version do
        cleared = PromptBuffer.clear_input_and_scroll(ui)
        {cleared, Buffer.inspection_marker(buffer)}
      else
        {ui, nil}
      end

    {:ok, submitted} = DraftSave.submitted(save, ref, revision, marker)
    {outcome, arm(UIState.project_draft_save(ui, submitted), owner)}
  end

  @spec submission_failure(term()) :: {term(), :retryable | :blocked | :unconfirmed}
  defp submission_failure({:remote_unavailable, _}), do: {:submission_uncertain, :unconfirmed}

  defp submission_failure({:conversation_persistence_failed, {:draft_commit_uncertain, _, _, _}}),
    do: {:submission_uncertain, :unconfirmed}

  defp submission_failure({:stale_draft_revision, _}),
    do: submission_failure(:draft_attachments_changed)

  defp submission_failure(:draft_attachments_changed),
    do:
      {{:submission_notice,
        "Saved attachments changed. Reopen the draft and review them before sending."}, :blocked}

  defp submission_failure(:draft_attachments_too_large),
    do:
      {{:submission_notice,
        "The attachments exceed the selected route's prompt limit. Remove context before sending."},
       :retryable}

  defp submission_failure(:attachment_route_unsupported),
    do:
      {{:submission_notice,
        "The selected route cannot send these attachments. Choose a text model."}, :retryable}

  defp submission_failure(:attachment_send_busy),
    do:
      {{:submission_notice,
        "Wait for the active turn before sending attachments. The draft was kept."}, :retryable}

  defp submission_failure(:not_driver),
    do:
      {{:submission_notice,
        "Reconnect as the original Agent conversation's driver. The draft was kept."}, :blocked}

  defp submission_failure(:stale_target),
    do:
      {{:submission_notice, "The original Agent conversation changed. The draft was kept."},
       :blocked}

  defp submission_failure(:credentials_not_configured),
    do:
      {{:submission_notice, "Configure a provider on the Agent daemon. The draft was kept."},
       :retryable}

  defp submission_failure(reason) when reason in [:credentials_pending, :provider_not_ready],
    do:
      {{:submission_notice, "The Agent daemon's provider is not ready. The draft was kept."},
       :retryable}

  defp submission_failure(_reason), do: {:submission_refused, :retryable}

  @spec restore_loaded(UIState.t(), DraftSave.t(), DraftSave.marker(), DraftSnapshot.t() | nil) ::
          {:ok, UIState.t(), DraftSave.t(), DraftSave.marker() | nil} | :edited
  defp restore_loaded(ui, %DraftSave{buffer: buffer} = save, _initial, nil) do
    marker = if PromptBuffer.input_empty?(ui), do: Buffer.inspection_marker(buffer), else: nil
    {:ok, ui, save, marker}
  catch
    :exit, _reason -> :edited
  end

  defp restore_loaded(ui, save, initial, %DraftSnapshot{} = draft) do
    if PromptBuffer.input_empty?(ui),
      do: install_snapshot(ui, save, initial, draft),
      else: :edited
  end

  @spec install_snapshot(UIState.t(), DraftSave.t(), DraftSave.marker(), DraftSnapshot.t()) ::
          {:ok, UIState.t(), DraftSave.t(), DraftSave.marker()} | :edited
  defp install_snapshot(ui, %DraftSave{buffer: buffer} = save, initial, %DraftSnapshot{} = draft) do
    with ^initial <- Buffer.inspection_marker(buffer),
         {:ok, restored} <- PromptBuffer.restore_draft(UIState.detach_prompt_buffer(ui), draft) do
      restored_buffer = restored.panel.prompt_buffer
      GenServer.stop(buffer, :normal)

      {:ok, restored, DraftSave.restore_buffer(save, restored_buffer),
       Buffer.inspection_marker(restored_buffer)}
    else
      _changed -> :edited
    end
  catch
    :exit, _reason -> :edited
  end

  @spec fail_result(UIState.t(), DraftSave.t(), reference(), :retryable | :blocked) ::
          {term(), UIState.t()}
  defp fail_result(ui, save, ref, retry) do
    case DraftSave.failed(save, ref, retry) do
      {:ok, failed} -> {:failed, UIState.project_draft_save(ui, failed)}
      :stale -> {:unchanged, ui}
    end
  end

  @spec update_origin(State.t(), non_neg_integer(), (UIState.t() -> {term(), UIState.t()})) ::
          State.t()
  defp update_origin(state, owner, update) do
    case tab_bar(state) do
      %TabBar{} = tabs ->
        if TabBar.active_workspace_id(tabs) == owner do
          {outcome, ui} = update.(state.workspace.agent_ui)
          state |> Workflow.install_agent_ui(ui) |> report(outcome)
        else
          update_inactive(state, tabs, owner, update)
        end

      nil ->
        state
    end
  end

  @spec update_inactive(State.t(), TabBar.t(), non_neg_integer(), (UIState.t() ->
                                                                     {term(), UIState.t()})) ::
          State.t()
  defp update_inactive(state, tabs, owner, update) do
    case TabBar.get_workspace(tabs, owner) do
      %Workspace{label: label, payload: %Agent{agent_ui: %UIState{} = ui}} ->
        {outcome, updated} = update.(ui)

        shell =
          TraditionalState.install_tab_bar(
            state.shell_runtime.state,
            TabBar.set_workspace_agent_ui(tabs, owner, updated)
          )

        state = %{
          state
          | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell)
        }

        report_inactive(state, outcome, label)

      _other ->
        state
    end
  end

  @spec report_inactive(State.t(), term(), String.t()) :: State.t()
  defp report_inactive(state, :failed, _label) do
    Minga.API.message("An inactive Agent draft could not be saved or restored.")
    state
  end

  defp report_inactive(state, :attached, label) do
    state
    |> NoticeWorkflow.publish("Snapshot attached to #{label}.")
    |> MingaEditor.schedule_render(16)
  end

  defp report_inactive(state, outcome, _label)
       when outcome in [
              :private_attachment,
              :attachment_not_ready,
              :submission_uncertain,
              :submitted_offline
            ],
       do: report(state, outcome)

  defp report_inactive(state, outcome, _label)
       when outcome in [:recall_refused, :recall_conflict],
       do: report(state, outcome)

  defp report_inactive(state, outcome, _label)
       when outcome in [:queue_refused, :queue_receipt_unconfirmed],
       do: report(state, outcome)

  defp report_inactive(state, _outcome, _label), do: state

  @spec report(State.t(), term()) :: State.t()
  defp report(state, :failed) do
    message = "Draft not saved or restored. Current input was kept."
    Minga.API.message(message)

    state
    |> NoticeWorkflow.publish(message)
    |> MingaEditor.schedule_render(16)
  end

  defp report(state, :restored), do: MingaEditor.schedule_render(state, 16)

  defp report(state, :submitted_offline),
    do:
      report(
        state,
        {:submission_notice,
         "Prompt saved in the conversation, but the provider could not start it."}
      )

  defp report(state, :submission_refused),
    do:
      report(
        state,
        {:submission_notice, "The prompt was not submitted. The draft was kept."}
      )

  defp report(state, :submission_uncertain),
    do:
      report(
        state,
        {:submission_notice,
         "Send could not be confirmed. The draft was kept. Open Draft attachments to check the exact submission."}
      )

  defp report(state, :submission_recovered),
    do:
      report(state, {:submission_notice, "The original conversation accepted the previous send."})

  defp report(state, {:submission_notice, message}),
    do: state |> NoticeWorkflow.publish(message) |> MingaEditor.schedule_render(16)

  defp report(state, :attachments_reloaded),
    do:
      state
      |> NoticeWorkflow.publish("Saved attachments reloaded. Open Attachments to review them.")
      |> MingaEditor.schedule_render(16)

  defp report(state, :attachment_removed),
    do:
      state
      |> NoticeWorkflow.publish("Snapshot removed from the draft.")
      |> MingaEditor.schedule_render(16)

  defp report(state, :attached),
    do:
      state
      |> NoticeWorkflow.publish("Snapshot attached.")
      |> MingaEditor.schedule_render(16)

  defp report(state, :private_attachment),
    do: NoticeWorkflow.publish(state, "Snapshots cannot be attached to credential input.")

  defp report(state, :attachment_not_ready),
    do:
      NoticeWorkflow.publish(
        state,
        "Attachment not saved. Select a ready Agent composer and try again."
      )

  defp report(state, :recalled),
    do:
      state
      |> NoticeWorkflow.publish("Queued input recalled to the composer.")
      |> MingaEditor.schedule_render(16)

  defp report(state, :stale_stop),
    do: NoticeWorkflow.publish(state, "That Agent turn is no longer active.")

  defp report(state, :recall_not_ready),
    do:
      NoticeWorkflow.publish(
        state,
        "Wait for the composer draft to finish saving. Queued input was kept."
      )

  defp report(state, :recall_refused),
    do:
      NoticeWorkflow.publish(
        state,
        "Queued input could not be recalled. The queue and current draft were kept."
      )

  defp report(state, :recall_conflict),
    do:
      NoticeWorkflow.publish(
        state,
        "Queued input was saved separately. Copy and clear your current edits, then select this session again in Sessions."
      )

  defp report(state, {:queued, kind}) do
    message =
      if kind == :steering, do: "Steering saved in the queue.", else: "Queued for the next turn."

    state |> NoticeWorkflow.publish(message) |> MingaEditor.schedule_render(16)
  end

  defp report(state, :queued_older_draft),
    do: NoticeWorkflow.publish(state, "The submitted input was queued. Newer edits were kept.")

  defp report(state, :queue_not_ready),
    do:
      NoticeWorkflow.publish(
        state,
        "Wait for the saved composer to be ready. The draft was kept."
      )

  defp report(state, :queue_refused),
    do:
      NoticeWorkflow.publish(
        state,
        "The queue did not accept this draft. Current input was kept."
      )

  defp report(state, :queue_receipt_unconfirmed),
    do:
      NoticeWorkflow.publish(
        state,
        "Could not verify the queue submission. Current input was kept. Check the saved session before sending again."
      )

  defp report(state, :queue_receipts_full),
    do:
      NoticeWorkflow.publish(
        state,
        "This session has too many unconfirmed queue replies. Your draft was kept. Use another session to queue new input."
      )

  defp report(state, :unchanged), do: state

  @spec tab_bar(State.t()) :: TabBar.t() | nil
  defp tab_bar(%State{shell_runtime: %{state: %TraditionalState{} = shell}}),
    do: TraditionalState.tab_bar(shell)

  defp tab_bar(%State{}), do: nil
end
