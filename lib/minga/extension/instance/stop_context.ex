defmodule Minga.Extension.Instance.StopContext do
  @moduledoc "Phase-owned state and transitions for one extension stop operation."

  alias Minga.Extension.Entry
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.Worker

  @type queued_start :: {:current, GenServer.from()} | {:deferred, GenServer.from(), Entry.t()}
  @type completion :: :stop | {:start_failure, term(), [GenServer.from()]}
  @type stage ::
          :quiescing | :draining | :editor_finalize | :editor_unload | :terminating | :cleanup

  @enforce_keys [:waiters, :exit_kind, :exit_reason, :runtime]
  defstruct [
    :waiters,
    :exit_kind,
    :exit_reason,
    :runtime,
    start_waiters: [],
    stage: :quiescing,
    token: nil,
    drain_ref: nil,
    editor_ref: nil,
    drain_done?: false,
    editor_done?: false,
    finalizer_error: nil,
    drain_timer: nil,
    worker: nil,
    completion: :stop
  ]

  @type t :: %__MODULE__{
          waiters: [GenServer.from()],
          start_waiters: [queued_start()],
          stage: stage(),
          token: reference() | nil,
          drain_ref: reference() | nil,
          editor_ref: reference() | nil,
          drain_done?: boolean(),
          editor_done?: boolean(),
          finalizer_error: term() | nil,
          exit_kind: :explicit | :normal | :crash,
          exit_reason: term(),
          runtime: Runtime.t() | nil,
          drain_timer: reference() | nil,
          worker: Worker.t() | nil,
          completion: completion()
        }

  @doc "Builds an initial quiescing stop transition."
  @spec new(GenServer.from() | nil, :explicit | :normal | :crash, term(), Runtime.t() | nil) ::
          t()
  def new(waiter, exit_kind, exit_reason, runtime) do
    waiters = if waiter == nil, do: [], else: [waiter]

    %__MODULE__{
      waiters: waiters,
      exit_kind: exit_kind,
      exit_reason: exit_reason,
      runtime: runtime
    }
  end

  @doc "Adds another stop caller."
  @spec join(t(), GenServer.from()) :: t()
  def join(context, from), do: %{context | waiters: [from | context.waiters]}

  @doc "Queues a start intent behind this stop."
  @spec queue_start(t(), queued_start()) :: t()
  def queue_start(context, start), do: %{context | start_waiters: [start | context.start_waiters]}

  @doc "Replaces stop waiters when a queued stop is transferred from a start."
  @spec transfer_waiters(t(), [GenServer.from()]) :: t()
  def transfer_waiters(context, waiters), do: %{context | waiters: waiters}

  @doc "Records that this stop is rolling back a failed start."
  @spec rollback_start(t(), term(), [GenServer.from()], [GenServer.from()]) :: t()
  def rollback_start(context, reason, start_waiters, stop_waiters) do
    %{context | waiters: stop_waiters, completion: {:start_failure, reason, start_waiters}}
  end

  @doc "Replaces the failed-start reason after projection also fails."
  @spec replace_start_failure(t(), term(), [GenServer.from()]) :: t()
  def replace_start_failure(context, reason, start_waiters) do
    %{context | completion: {:start_failure, reason, start_waiters}}
  end

  @doc "Begins lease draining."
  @spec begin_drain(t(), reference(), reference(), reference()) :: t()
  def begin_drain(context, token, drain_ref, timer) do
    %{context | stage: :draining, token: token, drain_ref: drain_ref, drain_timer: timer}
  end

  @doc "Remembers a failed drain request so unload can be aborted correctly."
  @spec remember_failed_drain(t(), reference(), reference()) :: t()
  def remember_failed_drain(context, token, drain_ref),
    do: %{context | token: token, drain_ref: drain_ref}

  @doc "Moves directly to editor finalization when no active lease exists."
  @spec begin_editor_finalize(t()) :: t()
  def begin_editor_finalize(context), do: %{context | stage: :editor_finalize, drain_done?: true}

  @doc "Attaches the worker and acknowledgement identity for an editor finalizer."
  @spec attach_finalizer(t(), Worker.t()) :: t()
  def attach_finalizer(context, worker), do: %{context | worker: worker, editor_ref: worker.id}

  @doc "Marks the code source drained and clears timer ownership."
  @spec source_drained(t()) :: t()
  def source_drained(context), do: %{context | drain_done?: true, drain_timer: nil}

  @doc "Clears a fired or cancelled drain timer."
  @spec clear_drain_timer(t()) :: t()
  def clear_drain_timer(context), do: %{context | drain_timer: nil}

  @doc "Records completion of editor effects and merges a finalizer result."
  @spec editor_effects_done(t(), :ok | {:error, term()}) :: t()
  def editor_effects_done(context, result) do
    %{context | editor_done?: true, finalizer_error: merge_error(context.finalizer_error, result)}
  end

  @doc "Records an explicit finalizer failure."
  @spec fail_finalizer(t(), term()) :: t()
  def fail_finalizer(context, reason), do: %{context | finalizer_error: reason}

  @doc "Merges an unload or completion result into finalizer failure state."
  @spec merge_finalizer_result(t(), :ok | {:error, term()}) :: t()
  def merge_finalizer_result(context, result) do
    %{context | finalizer_error: merge_error(context.finalizer_error, result)}
  end

  @doc "Moves the stop barrier to editor unload."
  @spec begin_editor_unload(t()) :: t()
  def begin_editor_unload(context), do: %{context | stage: :editor_unload}

  @doc "Moves the stop operation to runtime termination."
  @spec begin_termination(t()) :: t()
  def begin_termination(context), do: %{context | stage: :terminating}

  @doc "Records the worker performing termination or cleanup."
  @spec attach_worker(t(), Worker.t()) :: t()
  def attach_worker(context, worker), do: %{context | worker: worker}

  @doc "Moves to cleanup and records its worker."
  @spec begin_cleanup(t(), Worker.t()) :: t()
  def begin_cleanup(context, worker), do: %{context | stage: :cleanup, worker: worker}

  @doc "Clears completed or failed worker bookkeeping."
  @spec finish_work(t()) :: t()
  def finish_work(context), do: %{context | worker: nil}

  @doc "Records a terminal-runtime cleanup failure."
  @spec record_terminal_failure(t(), term()) :: t()
  def record_terminal_failure(context, failure), do: %{context | finalizer_error: failure}

  @doc "Clears runtime identity after its DOWN arrives during stop."
  @spec runtime_exited(t()) :: t()
  def runtime_exited(context), do: %{context | runtime: nil}

  @doc "Builds a clean retry after cleanup failed."
  @spec cleanup_retry(t(), keyword()) :: t()
  def cleanup_retry(context, opts \\ []) do
    %{
      context
      | waiters: [],
        start_waiters: [],
        stage: Keyword.get(opts, :stage, context.stage),
        completion: Keyword.get(opts, :completion, context.completion),
        drain_timer: nil,
        worker: nil
    }
  end

  @doc "Starts a cleanup-only retry for one caller."
  @spec retry_cleanup(t(), GenServer.from()) :: t()
  def retry_cleanup(context, from), do: %{context | waiters: [from], start_waiters: []}

  @doc "Restarts quiescence retry state for one caller."
  @spec retry_quiescence(t(), GenServer.from()) :: t()
  def retry_quiescence(context, from) do
    %{
      context
      | waiters: [from],
        start_waiters: [],
        stage: :quiescing,
        token: nil,
        drain_ref: nil,
        drain_timer: nil,
        editor_ref: nil,
        drain_done?: false,
        editor_done?: false,
        finalizer_error: nil,
        worker: nil
    }
  end

  @spec merge_error(term() | nil, :ok | {:error, term()}) :: term() | nil
  defp merge_error(current, :ok), do: current
  defp merge_error(nil, {:error, reason}), do: reason

  defp merge_error(current, {:error, reason}),
    do: {:multiple_finalizer_failures, [current, reason]}
end
