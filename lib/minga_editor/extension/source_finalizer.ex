defmodule MingaEditor.Extension.SourceFinalizer do
  @moduledoc """
  Finalizes Editor-owned work and presentation for one contribution source.

  Extension cleanup requests this workflow asynchronously and waits for an
  explicit Editor acknowledgement outside the lifecycle authority mailbox. The
  generation-owned effect scheduler drains before source presentation is removed.
  """

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.EventWorkflow
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState

  @cleanup_family :editor_effects
  @unload_family :editor_extension_unload
  @editor_request_timeout 2_000

  @type source :: ContributionCleanup.contribution_source()
  @type result :: :ok | {:error, term()}
  @type unload_context :: %{
          required(:token) => CodeLease.unload_token(),
          optional(:callback_registry) => CallbackRegistry.registry(),
          optional(:callback_admission) => GenServer.server()
        }

  @doc "Registers the Editor finalizer with source-owned contribution cleanup."
  @spec ensure_cleanup_registered() :: :ok
  def ensure_cleanup_registered do
    # Register a module capture, not an Editor or scheduler closure. Re-registering
    # on every Editor generation is idempotent and guarantees a restarted Editor
    # repairs a callback that tests or lifecycle code may have removed.
    :ok = ContributionCleanup.register(@cleanup_family, &__MODULE__.unregister_source/1)
    ContributionCleanup.register_contextual(@unload_family, &__MODULE__.unload_source/2)
  end

  @doc "Finalizes a source against the production Editor, if it is running."
  @spec unregister_source(source()) :: result()
  def unregister_source(source), do: unregister_source(source, MingaEditor)

  @doc "Finalizes a source against an explicit Editor server."
  @spec unregister_source(source(), GenServer.server() | nil) :: result()
  def unregister_source(_source, nil), do: :ok

  def unregister_source(source, pid) when is_pid(pid) do
    if pid == self() do
      {:error, :editor_finalizer_called_from_editor}
    else
      call_editor(pid, source)
    end
  end

  def unregister_source(source, name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> call_editor(pid, source)
    end
  end

  @doc "Runs token-scoped unload callbacks against the production Editor, if it is running."
  @spec unload_source(CallbackInvoker.source(), unload_context()) :: result()
  def unload_source({:extension, name} = source, context)
      when is_atom(name) and is_map(context) do
    case Process.whereis(MingaEditor) do
      nil -> :ok
      pid -> call_editor_unload(pid, source, context)
    end
  end

  @doc "Schedules source-filtered unload callbacks and defers the cleanup acknowledgement."
  @spec finalize_unload(
          EditorState.t(),
          CallbackInvoker.source(),
          unload_context(),
          {pid(), reference()}
        ) :: {:ok, EditorState.t()} | {:error, term(), EditorState.t()}
  def finalize_unload(%EditorState{} = state, {:extension, _name} = source, context, reply_to) do
    EventWorkflow.dispatch_unload(state, source, context, reply_to)
  end

  @doc "Cancels source work before removing its live picker presentation."
  @spec finalize(EditorState.t(), source()) :: {result(), EditorState.t()}
  def finalize(%EditorState{} = state, source) do
    case EffectScheduler.cancel_source(state.effect_scheduler, source) do
      :ok -> {:ok, PickerUI.remove_source(state, source)}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @spec call_editor(pid(), source()) :: result()
  defp call_editor(pid, source) do
    request_editor(pid, {:finalize_extension_source_request, source})
  end

  @spec call_editor_unload(pid(), source(), unload_context()) :: result()
  defp call_editor_unload(pid, source, context) do
    request_editor(pid, {:unload_extension_source_request, source, context})
  end

  @spec request_editor(pid(), tuple()) :: result()
  defp request_editor(pid, request) do
    ref = Process.monitor(pid)
    GenServer.cast(pid, Tuple.insert_at(request, tuple_size(request), {self(), ref}))

    receive do
      {:extension_source_finalized, ^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:editor_unavailable, reason}}
    after
      @editor_request_timeout ->
        Process.demonitor(ref, [:flush])
        {:error, {:editor_request_timeout, @editor_request_timeout}}
    end
  end
end
