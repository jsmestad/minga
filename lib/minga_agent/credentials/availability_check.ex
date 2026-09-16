defmodule MingaAgent.Credentials.AvailabilityCheck do
  @moduledoc """
  Session-owned lifecycle for one correlated live credential availability check.

  The value owns request identity and worker metadata. `MingaAgent.Session`
  performs Task and timer effects, then installs their references through these
  transitions. Superseding a check returns the old worker resources for explicit
  cleanup before the new request starts.
  """

  alias MingaAgent.Credentials.Snapshot

  @enforce_keys [:generation, :phase]
  defstruct generation: 0, phase: :idle

  @type request :: %{
          token: reference(),
          generation: non_neg_integer(),
          session_id: String.t(),
          snapshot: Snapshot.t(),
          model_name: String.t()
        }
  @type cleanup :: {Task.t(), reference()} | nil
  @type phase :: :idle | {:pending, request()} | {:running, request(), Task.t(), reference()}
  @type t :: %__MODULE__{generation: non_neg_integer(), phase: phase()}

  @doc "Creates an idle availability-check lifecycle."
  @spec new() :: t()
  def new, do: %__MODULE__{generation: 0, phase: :idle}

  @doc "Invalidates old work and prepares the newest availability request."
  @spec request(t(), Snapshot.t(), String.t(), String.t()) :: {t(), request(), cleanup()}
  def request(%__MODULE__{} = check, %Snapshot{} = snapshot, model_name, session_id)
      when is_binary(model_name) and is_binary(session_id) do
    generation = check.generation + 1

    request = %{
      token: make_ref(),
      generation: generation,
      session_id: session_id,
      snapshot: snapshot,
      model_name: model_name
    }

    {%__MODULE__{generation: generation, phase: {:pending, request}}, request, cleanup(check)}
  end

  @doc "Installs the supervised worker and timeout for the current request."
  @spec install(t(), reference(), Task.t(), reference()) :: {:ok, t()} | :stale
  def install(
        %__MODULE__{phase: {:pending, %{token: token} = request}} = check,
        token,
        %Task{} = task,
        timer_ref
      )
      when is_reference(timer_ref) do
    {:ok, %{check | phase: {:running, request, task, timer_ref}}}
  end

  def install(%__MODULE__{}, _token, %Task{}, _timer_ref), do: :stale

  @doc "Accepts the correlated worker result and returns to idle."
  @spec complete(t(), reference(), reference(), term()) ::
          {:ok, request(), term(), reference(), t()} | :stale
  def complete(
        %__MODULE__{phase: {:running, %{token: token} = request, %Task{ref: task_ref}, timer_ref}} =
          check,
        task_ref,
        token,
        result
      ) do
    {:ok, request, result, timer_ref, %{check | phase: :idle}}
  end

  def complete(%__MODULE__{}, _task_ref, _token, _result), do: :stale

  @doc "Accepts a current worker exit and returns to idle."
  @spec worker_down(t(), reference(), term()) ::
          {:ok, request(), term(), reference(), t()} | :stale
  def worker_down(
        %__MODULE__{phase: {:running, request, %Task{ref: task_ref}, timer_ref}} = check,
        task_ref,
        reason
      ) do
    {:ok, request, reason, timer_ref, %{check | phase: :idle}}
  end

  def worker_down(%__MODULE__{}, _task_ref, _reason), do: :stale

  @doc "Accepts a current timeout and returns the worker for termination."
  @spec timeout(t(), reference()) :: {:ok, request(), Task.t(), t()} | :stale
  def timeout(
        %__MODULE__{phase: {:running, %{token: token} = request, task, _timer_ref}} = check,
        token
      ) do
    {:ok, request, task, %{check | phase: :idle}}
  end

  def timeout(%__MODULE__{}, _token), do: :stale

  @doc "Settles a current request whose worker could not start."
  @spec start_failed(t(), reference()) :: {:ok, request(), t()} | :stale
  def start_failed(
        %__MODULE__{phase: {:pending, %{token: token} = request}} = check,
        token
      ) do
    {:ok, request, %{check | phase: :idle}}
  end

  def start_failed(%__MODULE__{}, _token), do: :stale

  @doc "Returns whether the owner has a pending or running check."
  @spec checking?(t()) :: boolean()
  def checking?(%__MODULE__{phase: :idle}), do: false
  def checking?(%__MODULE__{}), do: true

  @doc "Returns the request awaiting worker startup."
  @spec pending_request(t()) :: request() | nil
  def pending_request(%__MODULE__{phase: {:pending, request}}), do: request
  def pending_request(%__MODULE__{}), do: nil

  @doc "Invalidates the current check and returns resources requiring cleanup."
  @spec stop(t()) :: {t(), cleanup()}
  def stop(%__MODULE__{} = check) do
    {%{check | generation: check.generation + 1, phase: :idle}, cleanup(check)}
  end

  @spec cleanup(t()) :: cleanup()
  defp cleanup(%__MODULE__{phase: {:running, _request, task, timer_ref}}),
    do: {task, timer_ref}

  defp cleanup(%__MODULE__{}), do: nil
end
