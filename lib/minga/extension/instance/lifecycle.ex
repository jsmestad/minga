defmodule Minga.Extension.Instance.Lifecycle do
  @moduledoc "Shared lifecycle operations used by Instance transition handlers."

  alias Minga.Extension.CodeLease
  alias Minga.Extension.Instance.PhaseFailure
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.State
  alias Minga.Extension.Instance.StopContext
  alias Minga.Extension.InstanceRegistry

  @doc "Applies a declaration update and preserves the current state on rejection."
  @spec declare(State.t(), Minga.Extension.Entry.t(), GenServer.server(), keyword()) ::
          {:reply, :ok | {:error, term()}, State.t()}
  def declare(state, declaration, registry, opts) do
    case State.declare(state, declaration, registry, opts) do
      {:ok, updated} -> {:reply, :ok, updated}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @doc "Returns the local runtime supervisor identity for this authority."
  @spec runtime_supervisor(State.t()) :: GenServer.server()
  def runtime_supervisor(state) do
    InstanceRegistry.via(state.instance_registry, :runtime, state.name)
  end

  @spec terminal_finalizer_error(:normal | :crash, term()) :: term()
  def terminal_finalizer_error(:crash, reason),
    do: {:terminal_crash_cleanup_failed, [quiesce: reason]}

  def terminal_finalizer_error(:normal, reason),
    do: {:terminal_exit_cleanup_failed, [quiesce: reason]}

  @spec terminal_cleanup_error(StopContext.t(), term()) :: term()
  def terminal_cleanup_error(
        %StopContext{exit_kind: :crash, finalizer_error: finalizer},
        failures
      ),
      do: {:terminal_crash_cleanup_failed, [quiesce: finalizer, cleanup: failures]}

  def terminal_cleanup_error(
        %StopContext{exit_kind: :normal, finalizer_error: finalizer},
        failures
      ),
      do: {:terminal_exit_cleanup_failed, [quiesce: finalizer, cleanup: failures]}

  def terminal_cleanup_error(%StopContext{}, failures), do: {:cleanup_failed, failures}

  @spec maybe_abort_unload(State.t()) :: :ok | {:error, term()}
  def maybe_abort_unload(%State{phase: {:stopping, %StopContext{token: token}}} = state)
      when is_reference(token) do
    server = Keyword.get(state.collaborators, :code_lease, CodeLease)
    CodeLease.abort_unload(token, server: server)
  end

  def maybe_abort_unload(_state), do: :ok

  @spec abort_failure(State.t(), term()) :: term()
  def abort_failure(state, reason) do
    case maybe_abort_unload(state) do
      :ok ->
        reason

      {:error, abort_reason} ->
        {:multiple_cleanup_failures, [reason, {:abort_unload, abort_reason}]}
    end
  end

  @spec cancel_timer(reference() | nil) :: :ok
  def cancel_timer(nil), do: :ok

  def cancel_timer(timer) do
    _ = Process.cancel_timer(timer)
    :ok
  end

  @spec wrap_cleanup_failure(term(), {:error, term()}) :: term()
  def wrap_cleanup_failure(reason, {:error, failures}), do: {:cleanup_failed, reason, failures}

  @spec maybe_demonitor(Runtime.t() | nil) :: :ok
  def maybe_demonitor(runtime), do: Runtime.demonitor(runtime)

  @spec lifecycle_span(atom(), atom(), (-> result)) :: result when result: var
  def lifecycle_span(name, phase, fun) do
    Minga.Telemetry.span_with_stop_metadata(
      [:minga, :extension, :lifecycle],
      %{extension: name, phase: phase},
      fn ->
        result = fun.()
        {result, lifecycle_result_metadata(result)}
      end
    )
  end

  @spec lifecycle_result_metadata(term()) :: map()
  def lifecycle_result_metadata({:error, reason}), do: %{outcome: :error, reason: reason}

  def lifecycle_result_metadata({:error, reason, _state, _runtime}),
    do: %{outcome: :error, reason: reason}

  def lifecycle_result_metadata(_result), do: %{outcome: :ok}

  @spec emit_terminal_phase(atom(), State.phase()) :: :ok
  def emit_terminal_phase(name, phase) do
    Minga.Telemetry.execute(
      [:minga, :extension, :lifecycle, :terminal],
      %{count: 1},
      %{extension: name, phase: telemetry_phase(phase)}
    )
  end

  @spec telemetry_phase(State.phase()) :: State.phase() | {:crashed | :load_error, map()}
  defp telemetry_phase({tag, %PhaseFailure{reason: reason}}) when tag in [:crashed, :load_error],
    do: {tag, %{reason: reason}}

  defp telemetry_phase(phase), do: phase

  @spec emit_restart_count(atom(), non_neg_integer()) :: :ok
  def emit_restart_count(name, count) do
    Minga.Telemetry.execute(
      [:minga, :extension, :lifecycle, :crash_restart_count],
      %{count: count},
      %{extension: name, phase: :crash_restart_count}
    )
  end

  @spec broadcast_started(State.t()) :: :ok
  def broadcast_started(%State{artifact: {:prepared, artifact}} = state) do
    Minga.Events.broadcast(:extension_agent_contributions_started, %{
      source: artifact.source,
      module: artifact.module,
      manifest: artifact.manifest,
      root: extension_root(state.declaration, artifact.module)
    })
  end

  @spec extension_root(Minga.Extension.Entry.t(), module()) :: String.t() | nil
  def extension_root(%{path: path}, _module) when is_binary(path), do: Path.expand(path)

  def extension_root(%{hex: %{app: app}}, _module) when is_atom(app) do
    case :code.lib_dir(app) do
      path when is_list(path) -> List.to_string(path)
      _other -> nil
    end
  end

  def extension_root(_declaration, module) do
    case :code.which(module) do
      path when is_list(path) -> path |> List.to_string() |> Path.dirname() |> Path.dirname()
      _other -> nil
    end
  end
end
