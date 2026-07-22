defmodule MingaEditor.Extension.EventEffectTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.EventEffect
  alias MingaEditor.Extension.EventWorkflow
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Frontend
  alias MingaEditor.State.Render, as: RenderState
  alias MingaEditor.Test.ExtensionBlockingEventHandler, as: BlockingHandler

  @timeout 2_000

  setup do
    registry = unique_name(:callback_registry)
    admission = unique_name(:callback_admission)
    generation = unique_name(:callback_generation)
    persistence_key = {__MODULE__, make_ref()}
    code_lease = unique_name(:callback_code_admission)

    start_supervised!({CallbackRegistry, name: registry})

    start_supervised!(
      {ArtifactGenerationState, name: generation, persistence_key: persistence_key}
    )

    start_supervised!({ArtifactAdmission, name: admission, state_owner: generation})
    start_supervised!({CodeLease, name: code_lease})

    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor, observer: self()},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())
    source = register_handler(registry, admission, code_lease)

    state = %EditorState{
      effect_scheduler: scheduler,
      frontend: %Frontend{port_manager: nil},
      workspace: %SessionState{}
    }

    on_exit(fn -> ArtifactGenerationState.reset_for_test(persistence_key) end)

    %{
      registry: registry,
      code_lease: code_lease,
      scheduler: scheduler,
      source: source,
      state: state
    }
  end

  test "blocking callbacks run off the caller and commit against the exact snapshot", ctx do
    token = make_ref()

    returned =
      EventWorkflow.dispatch(
        ctx.state,
        {:editor_action, :block, {self(), token}},
        callback_registry: ctx.registry,
        callback_admission: ctx.code_lease
      )

    assert returned == ctx.state

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      status: :running,
                      request: %{id: request_id, effect: %EventEffect{}}
                    }},
                   @timeout

    assert_receive {:extension_callback_entered, ^token, worker}, @timeout
    refute worker == self()
    send(worker, {:release_extension_callback, token})

    outcome = receive_outcome(ctx.scheduler, request_id, :completed)
    assert :ok = EffectScheduler.claim(ctx.scheduler, outcome)
    assert {state, %Outcome{status: :completed} = applied} = EventEffect.apply(ctx.state, outcome)
    assert state == ctx.state
    EffectScheduler.finalize(ctx.scheduler, applied)
  end

  test "render-only progress does not invalidate an otherwise current callback result", ctx do
    render = RenderState.append_message(ctx.state.render, "render advanced", :info, :editor)
    current = %{ctx.state | render: render}
    candidate = EditorState.apply_theme(ctx.state, MingaEditor.UI.Theme.get!(:doom_one))

    assert {:ok, accepted} =
             EditorState.accept_extension_event_result(current, ctx.state, candidate)

    assert accepted.render == render
    assert accepted.appearance == candidate.appearance
  end

  test "concurrent interactive events are rejected visibly instead of queued on stale state",
       ctx do
    token = make_ref()

    state =
      EventWorkflow.dispatch(
        ctx.state,
        {:editor_action, :block, {self(), token}},
        callback_registry: ctx.registry,
        callback_admission: ctx.code_lease
      )

    assert_receive {:effect_lifecycle, %Outcome{status: :running, request: %{id: request_id}}},
                   @timeout

    assert_receive {:extension_callback_entered, ^token, worker}, @timeout

    rejected =
      EventWorkflow.dispatch(
        state,
        {:editor_action, :execute_git_command, :status},
        callback_registry: ctx.registry,
        callback_admission: ctx.code_lease
      )

    assert rejected.shell_runtime.state.notice.message == "Git command not scheduled: :queue_full"
    send(worker, {:release_extension_callback, token})
    outcome = receive_outcome(ctx.scheduler, request_id, :completed)
    assert :ok = EffectScheduler.claim(ctx.scheduler, outcome)
    {_state, applied} = EventEffect.apply(rejected, outcome)
    EffectScheduler.finalize(ctx.scheduler, applied)
  end

  test "a declined interactive Git action restores unavailable feedback", ctx do
    state =
      EventWorkflow.dispatch(
        ctx.state,
        {:editor_action, :open_git_diff_for_path, :arguments},
        callback_registry: ctx.registry,
        callback_admission: ctx.code_lease
      )

    assert_receive {:effect_lifecycle, %Outcome{status: :running, request: %{id: request_id}}},
                   @timeout

    outcome = receive_outcome(ctx.scheduler, request_id, :completed)
    assert :ok = EffectScheduler.claim(ctx.scheduler, outcome)
    current = EditorState.apply_theme(state, MingaEditor.UI.Theme.get!(:doom_one))
    assert {result, %Outcome{status: :stale} = applied} = EventEffect.apply(current, outcome)

    assert result.shell_runtime.state.notice.message ==
             "Git porcelain extension is disabled or failed to load"

    assert EventEffect.render?(applied)
    EffectScheduler.finalize(ctx.scheduler, applied)
  end

  test "declined source-owned actions restore visible feedback", ctx do
    actions = [
      {{:editor_action, :execute_git_command, :status}, "Git command unavailable"},
      {{:editor_action, :branch_delete_confirm, {"/repo", "feature", false}},
       "Branch delete action unavailable"},
      {{:editor_action, :branch_delete_cancel, nil}, "Branch delete action unavailable"}
    ]

    Enum.each(actions, fn {event, message} ->
      state =
        EventWorkflow.dispatch(ctx.state, event,
          callback_registry: ctx.registry,
          callback_admission: ctx.code_lease
        )

      assert_receive {:effect_lifecycle, %Outcome{status: :running, request: %{id: request_id}}},
                     @timeout

      outcome = receive_outcome(ctx.scheduler, request_id, :completed)
      assert :ok = EffectScheduler.claim(ctx.scheduler, outcome)
      assert {result, %Outcome{status: :completed} = applied} = EventEffect.apply(state, outcome)
      assert result.shell_runtime.state.notice.message == message
      EffectScheduler.finalize(ctx.scheduler, applied)
    end)
  end

  test "failing unload callbacks complete the deferred Editor reply with an error", ctx do
    {:ok, token} = CodeLease.quiesce_source(ctx.source, server: ctx.code_lease)
    reply_tag = make_ref()

    context = %{
      token: token,
      callback_registry: ctx.registry,
      callback_admission: ctx.code_lease
    }

    assert {:noreply, state} =
             MingaEditor.handle_cast(
               {:unload_extension_source_request, ctx.source, context, {self(), reply_tag}},
               ctx.state
             )

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      status: :running,
                      request: %{id: request_id, source: nil, resource: resource}
                    }},
                   @timeout

    assert resource == {:extension_editor_unload, ctx.source}
    outcome = receive_outcome(ctx.scheduler, request_id, :completed)
    assert :ok = EffectScheduler.claim(ctx.scheduler, outcome)
    assert {:error, [failure], _callback_state} = outcome.result
    assert {^state, %Outcome{status: :completed} = applied} = EventEffect.apply(state, outcome)
    EffectScheduler.finalize(ctx.scheduler, applied)

    assert_receive {:extension_source_finalized, ^reply_tag, {:error, [^failure]}}, @timeout
  end

  test "a callback result cannot overwrite newer Editor state", ctx do
    token = make_ref()

    _state =
      EventWorkflow.dispatch(
        ctx.state,
        {:editor_action, :block, {self(), token}},
        callback_registry: ctx.registry,
        callback_admission: ctx.code_lease
      )

    assert_receive {:effect_lifecycle, %Outcome{status: :running, request: %{id: request_id}}},
                   @timeout

    assert_receive {:extension_callback_entered, ^token, worker}, @timeout
    current = EditorState.apply_theme(ctx.state, MingaEditor.UI.Theme.get!(:doom_one))
    refute current == ctx.state
    send(worker, {:release_extension_callback, token})

    outcome = receive_outcome(ctx.scheduler, request_id, :completed)
    assert :ok = EffectScheduler.claim(ctx.scheduler, outcome)

    assert {^current, %Outcome{status: :stale, reason: :editor_state_changed} = applied} =
             EventEffect.apply(current, outcome)

    EffectScheduler.finalize(ctx.scheduler, applied)
  end

  test "a callback that never returns times out without holding its code lease", ctx do
    token = make_ref()

    _state =
      EventWorkflow.dispatch(
        ctx.state,
        {:editor_action, :block, {self(), token}},
        callback_registry: ctx.registry,
        callback_admission: ctx.code_lease,
        timeout_ms: 500
      )

    assert_receive {:effect_lifecycle, %Outcome{status: :running, request: %{id: request_id}}},
                   @timeout

    assert_receive {:extension_callback_entered, ^token, _worker}, @timeout
    outcome = receive_outcome(ctx.scheduler, request_id, :failed)
    assert :ok = EffectScheduler.claim(ctx.scheduler, outcome)
    assert {state, %Outcome{status: :failed} = applied} = EventEffect.apply(ctx.state, outcome)
    assert state == ctx.state
    EffectScheduler.finalize(ctx.scheduler, applied)
    _lease_state = :sys.get_state(ctx.code_lease)
    assert CodeLease.active_leases(server: ctx.code_lease, source: ctx.source) == []
  end

  defp register_handler(registry, admission, code_lease) do
    source = {:extension, unique_name(:event_source)}

    {:ok, claim} =
      ArtifactAdmission.claim_source_modules(
        source,
        [BlockingHandler],
        :crypto.hash(:sha256, inspect({source, BlockingHandler})),
        server: admission,
        trusted_application: :minga
      )

    :ok = ArtifactAdmission.commit_attempt(claim, server: admission)
    :ok = CodeLease.activate_source(source, [BlockingHandler], server: code_lease)

    :ok =
      CallbackRegistry.register_extension(
        elem(source, 1),
        [{BlockingHandler, [:editor_action, :source_unload], []}],
        registry: registry,
        artifact_admission: admission
      )

    source
  end

  defp receive_outcome(scheduler, request_id, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{id: ^request_id}, status: ^status} = outcome},
                   @timeout

    outcome
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
