defmodule Minga.Extension.Instance.Projection do
  @moduledoc "The sole writer of extension lifecycle fields in `Extension.Registry`."

  alias Minga.Extension.Instance.CleanupFailure
  alias Minga.Extension.Instance.PhaseFailure
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.State
  alias Minga.Extension.Instance.StopContext
  alias Minga.Extension.Registry

  @doc "Publishes the current tagged phase as the compatible registry view."
  @spec publish(State.t()) :: :ok | {:error, term()}
  def publish(%State{} = state) do
    Registry.update(state.registry, state.name, fields(state))
  catch
    :exit, reason -> {:error, {:projection_unavailable, state.name, reason}}
  end

  @doc "Returns lifecycle fields for a tagged Instance phase."
  @spec fields(State.t()) :: keyword()
  def fields(%State{phase: phase} = state) do
    artifact_fields = artifact_fields(state)
    Keyword.merge(artifact_fields, phase_fields(phase))
  end

  @spec artifact_fields(State.t()) :: keyword()
  defp artifact_fields(%State{artifact: {:prepared, artifact}}) do
    [module: artifact.module, manifest: artifact.manifest]
  end

  defp artifact_fields(%State{}), do: []

  @spec phase_fields(State.phase()) :: keyword()
  defp phase_fields(:stopped), do: [status: :stopped, pid: nil, last_error: nil]
  defp phase_fields({:stub, _artifact}), do: [status: :stub, pid: nil, last_error: nil]

  defp phase_fields({:starting, _context}),
    do: [status: :stopped, pid: nil, last_error: {:lifecycle_transition, :starting}]

  defp phase_fields({:running, %Runtime{} = runtime}),
    do: [status: :running, pid: runtime.pid, last_error: nil]

  defp phase_fields({:stopping, %StopContext{} = context}) do
    pid = if context.runtime == nil, do: nil, else: context.runtime.pid

    [
      status: :stopped,
      pid: pid,
      last_error: {:lifecycle_transition, {:stopping, context.stage}}
    ]
  end

  defp phase_fields({:crashed, %PhaseFailure{} = context}),
    do: [status: :crashed, pid: nil, last_error: context.reason]

  defp phase_fields({:load_error, %PhaseFailure{} = context}),
    do: [status: :load_error, pid: nil, last_error: context.reason]

  defp phase_fields({:cleanup_failed, %CleanupFailure{} = context}) do
    pid =
      case context.retry.runtime do
        %{pid: runtime_pid} -> runtime_pid
        nil -> nil
      end

    [status: :load_error, pid: pid, last_error: context.reason]
  end
end
