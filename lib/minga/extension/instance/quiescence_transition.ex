defmodule Minga.Extension.Instance.QuiescenceTransition do
  @moduledoc "Code-lease drain and editor-finalizer transitions for an extension stop."

  alias Minga.Extension.CodeLease
  alias Minga.Extension.Instance.Contributions
  alias Minga.Extension.Instance.State
  alias Minga.Extension.Instance.StopContext
  alias Minga.Extension.Instance.Worker

  import Minga.Extension.Instance.Lifecycle

  @spec begin_quiesce(State.t()) :: {:noreply, State.t()}
  def begin_quiesce(%State{phase: {:stopping, context}} = state) do
    source = {:extension, state.name}
    lease_server = Keyword.get(state.collaborators, :code_lease, CodeLease)

    case CodeLease.quiesce_source(source, server: lease_server) do
      {:ok, token} ->
        begin_drain(state, context, source, token, lease_server)

      {:error, {:source_not_active, ^source}} ->
        request_editor_without_token(state)

      {:error, {:source_inactive, ^source}} ->
        request_editor_without_token(state)

      {:error, reason} ->
        Minga.Extension.Instance.StopTransition.stop_failed(
          state,
          {:source_quiesce_failed, reason}
        )
    end
  end

  @spec begin_drain(State.t(), StopContext.t(), term(), reference(), GenServer.server()) ::
          {:noreply, State.t()}
  def begin_drain(state, context, source, token, lease_server) do
    drain_ref = make_ref()

    case CodeLease.notify_when_drained(source, self(), drain_ref, server: lease_server) do
      :ok ->
        timer =
          Process.send_after(
            self(),
            {CodeLease, :drain_timeout, drain_ref},
            Minga.Extension.Instance.TransitionHandler.drain_timeout_ms(state)
          )

        finalizer_context = %{
          token: token,
          callback_registry:
            Keyword.get(
              state.collaborators,
              :callback_registry,
              Minga.Extension.CallbackRegistry.default_table()
            ),
          callback_admission: lease_server
        }

        updated_context = StopContext.begin_drain(context, token, drain_ref, timer)
        state = State.stopping(state, updated_context)
        start_finalizer(state, :editor_effects, finalizer_context)

      {:error, reason} ->
        state =
          State.stopping(state, StopContext.remember_failed_drain(context, token, drain_ref))

        Minga.Extension.Instance.StopTransition.stop_failed(
          state,
          abort_failure(state, {:code_lease_drain_failed, reason})
        )
    end
  end

  @spec request_editor_without_token(State.t()) :: {:noreply, State.t()}
  def request_editor_without_token(%State{phase: {:stopping, context}} = state) do
    state = State.stopping(state, StopContext.begin_editor_finalize(context))
    start_finalizer(state, :editor_effects, %{})
  end

  @spec start_finalizer(State.t(), atom(), map()) :: {:noreply, State.t()}
  def start_finalizer(%State{phase: {:stopping, context}} = state, family, finalizer_context) do
    worker =
      Worker.start(
        self(),
        {:finalizer, family},
        Minga.Extension.Instance.TransitionHandler.callback_timeout(state),
        fn ->
          Contributions.finalize(state.name, family, finalizer_context, state.collaborators)
        end
      )

    updated = StopContext.attach_finalizer(context, worker)
    {:noreply, State.stopping(state, updated)}
  end

  @spec source_drained(State.t(), term(), reference()) :: {:noreply, State.t()}
  def source_drained(
        %State{name: name, phase: {:stopping, %StopContext{drain_ref: ref} = context}} = state,
        {:extension, name},
        ref
      ) do
    cancel_timer(context.drain_timer)

    continue_after_barrier(State.stopping(state, StopContext.source_drained(context)))
  end

  def source_drained(state, _source, _ref), do: {:noreply, state}

  @spec drain_timeout(State.t(), reference()) :: {:noreply, State.t()}
  def drain_timeout(
        %State{phase: {:stopping, %StopContext{drain_ref: ref, drain_done?: false} = context}} =
          state,
        ref
      ) do
    state = State.stopping(state, StopContext.clear_drain_timer(context))

    reason =
      {:code_lease_drain_timeout,
       Minga.Extension.Instance.TransitionHandler.drain_timeout_ms(state)}

    Minga.Extension.Instance.StopTransition.stop_failed(state, abort_failure(state, reason))
  end

  def drain_timeout(state, _ref), do: {:noreply, state}

  @spec finalizer_ack(State.t(), reference(), atom(), term()) :: {:noreply, State.t()}
  def finalizer_ack(
        %State{phase: {:stopping, %StopContext{editor_ref: ref} = context}} = state,
        ref,
        :editor_effects,
        result
      ) do
    updated_context = StopContext.editor_effects_done(context, result)
    continue_after_barrier(State.stopping(state, updated_context))
  end

  def finalizer_ack(
        %State{phase: {:stopping, %StopContext{editor_ref: ref, exit_kind: :explicit} = context}} =
          state,
        ref,
        :editor_extension_unload,
        {:error, reason}
      ) do
    state = State.stopping(state, StopContext.fail_finalizer(context, reason))

    Minga.Extension.Instance.StopTransition.stop_failed(
      state,
      abort_failure(state, {:source_quiesce_failed, reason})
    )
  end

  def finalizer_ack(
        %State{phase: {:stopping, %StopContext{editor_ref: ref} = context}} = state,
        ref,
        :editor_extension_unload,
        result
      ) do
    context = StopContext.merge_finalizer_result(context, result)
    complete_unload(State.stopping(state, context))
  end

  def finalizer_ack(state, _ref, _family, _result), do: {:noreply, state}

  @spec continue_after_barrier(State.t()) :: {:noreply, State.t()}
  def continue_after_barrier(
        %State{
          phase:
            {:stopping,
             %{
               drain_done?: true,
               editor_done?: true,
               exit_kind: :explicit,
               finalizer_error: nil
             }}
        } = state
      ),
      do: continue_after_successful_barrier(state)

  def continue_after_barrier(
        %State{
          phase:
            {:stopping,
             %{
               drain_done?: true,
               editor_done?: true,
               exit_kind: :explicit,
               finalizer_error: reason
             }}
        } = state
      ) do
    Minga.Extension.Instance.StopTransition.stop_failed(
      state,
      abort_failure(state, {:source_quiesce_failed, reason})
    )
  end

  def continue_after_barrier(
        %State{phase: {:stopping, %StopContext{drain_done?: true, editor_done?: true}}} = state
      ),
      do: continue_after_successful_barrier(state)

  def continue_after_barrier(state), do: {:noreply, state}

  @spec continue_after_successful_barrier(State.t()) :: {:noreply, State.t()}
  def continue_after_successful_barrier(
        %State{phase: {:stopping, %StopContext{token: token} = context}} = state
      )
      when is_reference(token) do
    finalizer_context = %{
      token: token,
      callback_registry:
        Keyword.get(
          state.collaborators,
          :callback_registry,
          Minga.Extension.CallbackRegistry.default_table()
        ),
      callback_admission: Keyword.get(state.collaborators, :code_lease, CodeLease)
    }

    state = State.stopping(state, StopContext.begin_editor_unload(context))
    start_finalizer(state, :editor_extension_unload, finalizer_context)
  end

  def continue_after_successful_barrier(state), do: finish_quiesce(state)

  @spec complete_unload(State.t()) :: {:noreply, State.t()}
  def complete_unload(%State{phase: {:stopping, context}} = state) do
    server = Keyword.get(state.collaborators, :code_lease, CodeLease)
    result = CodeLease.complete_unload(context.token, server: server)
    context = StopContext.merge_finalizer_result(context, result)
    finish_quiesce(State.stopping(state, context))
  end

  @spec finish_quiesce(State.t()) :: {:noreply, State.t()}
  def finish_quiesce(
        %State{phase: {:stopping, %StopContext{exit_kind: :explicit, finalizer_error: nil}}} =
          state
      ),
      do: Minga.Extension.Instance.StopTransition.advance_runtime_termination(state)

  def finish_quiesce(
        %State{phase: {:stopping, %StopContext{exit_kind: :explicit, finalizer_error: reason}}} =
          state
      ) do
    Minga.Extension.Instance.StopTransition.stop_failed(
      state,
      abort_failure(state, {:source_quiesce_failed, reason})
    )
  end

  def finish_quiesce(%State{phase: {:stopping, _context}} = state),
    do: Minga.Extension.Instance.StopTransition.advance_runtime_termination(state)
end
