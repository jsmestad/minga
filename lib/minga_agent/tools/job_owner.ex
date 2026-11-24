defmodule MingaAgent.Tools.JobOwner do
  @moduledoc """
  Owns running verification jobs for one agent session.

  Each session that needs job execution starts one JobOwner. The owner
  spawns monitored processes for shell commands, tracks bounded
  concurrency, and delivers terminal outcomes to the owning session.

  Foreground jobs block the caller until terminal. Background jobs
  return a stable handle immediately and buffer completion
  notifications for the session to deliver at a safe turn boundary.
  """

  use GenServer

  alias MingaAgent.Tools.Job
  alias MingaAgent.Tools.Shell

  @max_concurrent 8
  @max_retained 64

  @typedoc "Options for starting a job."
  @type start_opts :: [
          on_output: (String.t() -> :ok),
          env: [{String.t(), String.t()}],
          artifact_store: GenServer.server() | nil,
          capture_key: term() | nil,
          helper_path: String.t()
        ]

  @typedoc "Completion notification for a background job."
  @type completion :: {Job.id(), Job.generation(), Job.outcome(), non_neg_integer() | nil}

  @type init_opts :: [session_id: String.t(), notify: pid()]

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Starts a JobOwner for the given session."
  @spec start_link(init_opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts a foreground job and blocks until it completes.

  Returns the shell result directly, as if `Shell.execute/4` or
  `Shell.capture/4` were called. The job lifecycle is tracked
  internally for status queries and output retention.
  """
  @spec start_foreground(GenServer.server(), String.t(), String.t(), pos_integer(), start_opts()) ::
          Shell.result()
  def start_foreground(owner, command, cwd, timeout_secs, opts \\ []) do
    timeout_ms = (timeout_secs + 5) * 1_000

    GenServer.call(
      owner,
      {:start_foreground, command, cwd, timeout_secs, opts},
      timeout_ms
    )
  end

  @doc """
  Starts a background job and returns a stable handle immediately.

  The owning session receives a completion notification when the job
  reaches a terminal state.
  """
  @spec start_background(GenServer.server(), String.t(), String.t(), pos_integer(), start_opts()) ::
          {:ok, Job.id()} | {:error, :too_many_jobs}
  def start_background(owner, command, cwd, timeout_secs, opts \\ []) do
    GenServer.call(owner, {:start_background, command, cwd, timeout_secs, opts})
  end

  @doc "Returns the current status of a job."
  @spec job_status(GenServer.server(), Job.id()) ::
          {:ok, Job.t()} | {:error, :job_not_found}
  def job_status(owner, job_id) when is_binary(job_id) do
    GenServer.call(owner, {:job_status, job_id})
  end

  @doc "Returns the retained output text for a terminal job."
  @spec job_output(GenServer.server(), Job.id()) ::
          {:ok, String.t()} | {:error, :job_not_found | :job_still_running}
  def job_output(owner, job_id) when is_binary(job_id) do
    GenServer.call(owner, {:job_output, job_id})
  end

  @doc "Cancels a running job."
  @spec cancel(GenServer.server(), Job.id()) ::
          :ok | {:error, :job_not_found | :already_terminal}
  def cancel(owner, job_id) when is_binary(job_id) do
    GenServer.call(owner, {:cancel, job_id})
  end

  @doc "Drains pending completion notifications."
  @spec drain_completions(GenServer.server()) :: [completion()]
  def drain_completions(owner) do
    GenServer.call(owner, :drain_completions)
  end

  @doc "Reaps all running jobs and marks them interrupted. Called during session teardown."
  @spec reap_all(GenServer.server()) :: :ok
  def reap_all(owner) do
    GenServer.call(owner, :reap_all)
  end

  # ── Server callbacks ────────────────────────────────────────────────────────

  @typep live_entry :: %{
           job: Job.t(),
           task_pid: pid(),
           monitor_ref: reference(),
           from: GenServer.from() | nil
         }

  @typep state :: %{
           session_id: String.t(),
           notify: pid(),
           next_generation: Job.generation(),
           live: %{Job.id() => live_entry()},
           retained: %{Job.id() => Job.t()},
           retained_order: [Job.id()],
           completions: [completion()]
         }

  @impl GenServer
  @spec init(init_opts()) :: {:ok, state()}
  def init(opts) do
    state = %{
      session_id: Keyword.fetch!(opts, :session_id),
      notify: Keyword.fetch!(opts, :notify),
      next_generation: 1,
      live: %{},
      retained: %{},
      retained_order: [],
      completions: []
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:start_foreground, command, cwd, timeout_secs, opts}, from, state) do
    case admit_job(state, command, cwd, timeout_secs, false) do
      {:ok, job, state} ->
        state = spawn_job(state, job, opts, from)
        {:noreply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_background, command, cwd, timeout_secs, opts}, _from, state) do
    case admit_job(state, command, cwd, timeout_secs, true) do
      {:ok, job, state} ->
        state = spawn_job(state, job, opts, nil)
        {:reply, {:ok, job.id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:job_status, job_id}, _from, state) do
    case find_job(state, job_id) do
      {:ok, job} -> {:reply, {:ok, job}, state}
      :not_found -> {:reply, {:error, :job_not_found}, state}
    end
  end

  def handle_call({:job_output, job_id}, _from, state) do
    case find_job(state, job_id) do
      {:ok, %Job{} = job} ->
        if Job.finished?(job) do
          {:reply, {:ok, job.output_text || ""}, state}
        else
          {:reply, {:error, :job_still_running}, state}
        end

      :not_found ->
        {:reply, {:error, :job_not_found}, state}
    end
  end

  def handle_call({:cancel, job_id}, _from, state) do
    case Map.fetch(state.live, job_id) do
      {:ok, entry} ->
        Process.exit(entry.task_pid, :kill)
        job = Job.terminate(entry.job, :cancelled, nil)
        state = finish_job(state, job_id, entry, job)
        {:reply, :ok, state}

      :error ->
        case Map.fetch(state.retained, job_id) do
          {:ok, _job} -> {:reply, {:error, :already_terminal}, state}
          :error -> {:reply, {:error, :job_not_found}, state}
        end
    end
  end

  def handle_call(:drain_completions, _from, state) do
    {:reply, Enum.reverse(state.completions), %{state | completions: []}}
  end

  def handle_call(:reap_all, _from, state) do
    state =
      Enum.reduce(state.live, state, fn {job_id, entry}, acc ->
        Process.exit(entry.task_pid, :kill)
        Process.demonitor(entry.monitor_ref, [:flush])
        job = Job.interrupt(entry.job)

        if entry.from, do: GenServer.reply(entry.from, {:error, :session_terminated})

        retain_job(%{acc | live: Map.delete(acc.live, job_id)}, job)
      end)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_live_by_monitor(state, ref) do
      {job_id, entry} when entry.task_pid == pid ->
        state = handle_job_exit(state, job_id, entry, reason)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:job_result, job_id, result}, state) do
    case Map.fetch(state.live, job_id) do
      {:ok, entry} ->
        {job, shell_result} = process_shell_result(entry.job, result)
        state = finish_job(state, job_id, entry, job, shell_result)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec admit_job(state(), String.t(), String.t(), pos_integer(), boolean()) ::
          {:ok, Job.t(), state()} | {:error, :too_many_jobs}
  defp admit_job(state, command, cwd, timeout_secs, background?) do
    if map_size(state.live) >= @max_concurrent do
      {:error, :too_many_jobs}
    else
      gen = state.next_generation
      id = generate_id()

      job =
        Job.new(
          id: id,
          session_id: state.session_id,
          command: command,
          cwd: cwd,
          timeout_secs: timeout_secs,
          generation: gen,
          started_at: System.monotonic_time(:millisecond),
          background?: background?
        )

      {:ok, job, %{state | next_generation: gen + 1}}
    end
  end

  @spec spawn_job(state(), Job.t(), start_opts(), GenServer.from() | nil) :: state()
  defp spawn_job(state, job, opts, from) do
    owner = self()
    job_id = job.id
    command = job.command
    cwd = job.cwd
    timeout_secs = job.timeout_secs

    task_pid =
      spawn(fn ->
        result = run_shell(command, cwd, timeout_secs, opts)
        send(owner, {:job_result, job_id, result})
      end)

    ref = Process.monitor(task_pid)
    job = Job.mark_running(job)

    entry = %{
      job: job,
      task_pid: task_pid,
      monitor_ref: ref,
      from: from
    }

    %{state | live: Map.put(state.live, job.id, entry)}
  end

  @spec run_shell(String.t(), String.t(), pos_integer(), start_opts()) :: Shell.result()
  defp run_shell(command, cwd, timeout_secs, opts) do
    if Keyword.has_key?(opts, :artifact_store) and Keyword.get(opts, :artifact_store) != nil do
      Shell.capture(command, cwd, timeout_secs, opts)
    else
      Shell.execute(command, cwd, timeout_secs, opts)
    end
  end

  @spec handle_job_exit(state(), Job.id(), live_entry(), term()) :: state()
  defp handle_job_exit(state, job_id, entry, reason) do
    # If we already got a :job_result message, the job was processed.
    # The DOWN message arrives after the process exits.
    case Map.fetch(state.live, job_id) do
      {:ok, ^entry} ->
        {outcome, exit_code} = exit_reason_to_outcome(reason)
        job = Job.terminate(entry.job, outcome, exit_code)
        result = {:error, "job process exited: #{inspect(reason)}"}
        finish_job(state, job_id, entry, job, result)

      _already_removed ->
        state
    end
  end

  @spec process_shell_result(Job.t(), Shell.result()) :: {Job.t(), Shell.result()}
  defp process_shell_result(job, {:ok, text} = result) when is_binary(text) do
    job =
      job
      |> Job.terminate(:completed, 0)
      |> Job.set_output(nil, text)

    {job, result}
  end

  defp process_shell_result(job, {:ok, %MingaAgent.Tool.Output{} = output} = result) do
    job =
      job
      |> Job.terminate(:completed, 0)
      |> Job.set_output(output.reference, output.view)

    {job, result}
  end

  defp process_shell_result(job, {:error, {:incomplete, :timeout, text}} = result) do
    job =
      job
      |> Job.terminate(:timeout, nil)
      |> Job.set_output(nil, text)

    {job, result}
  end

  defp process_shell_result(job, {:error, _reason} = result) do
    job = Job.terminate(job, :failed, nil)
    {job, result}
  end

  @spec finish_job(state(), Job.id(), live_entry(), Job.t()) :: state()
  defp finish_job(state, job_id, entry, job) do
    finish_job(state, job_id, entry, job, nil)
  end

  @spec finish_job(state(), Job.id(), live_entry(), Job.t(), Shell.result() | nil) :: state()
  defp finish_job(state, job_id, entry, job, shell_result) do
    Process.demonitor(entry.monitor_ref, [:flush])

    if entry.from do
      result = shell_result || {:error, "job #{Job.summary_status(job)}"}
      GenServer.reply(entry.from, result)
    end

    state = %{state | live: Map.delete(state.live, job_id)}
    state = retain_job(state, job)

    if job.background? do
      completion = {job.id, job.generation, Job.outcome(job), job.exit_code}
      notify_completion(state.notify, completion)
      %{state | completions: [completion | state.completions]}
    else
      state
    end
  end

  @spec retain_job(state(), Job.t()) :: state()
  defp retain_job(state, job) do
    state = evict_oldest_retained(state)

    %{
      state
      | retained: Map.put(state.retained, job.id, job),
        retained_order: state.retained_order ++ [job.id]
    }
  end

  @spec evict_oldest_retained(state()) :: state()
  defp evict_oldest_retained(state) do
    if map_size(state.retained) >= @max_retained do
      case state.retained_order do
        [oldest | rest] ->
          %{state | retained: Map.delete(state.retained, oldest), retained_order: rest}

        [] ->
          state
      end
    else
      state
    end
  end

  @spec notify_completion(pid(), completion()) :: :ok
  defp notify_completion(notify_pid, completion) do
    send(notify_pid, {:job_completion, completion})
    :ok
  end

  @spec find_job(state(), Job.id()) :: {:ok, Job.t()} | :not_found
  defp find_job(state, job_id) do
    case Map.fetch(state.live, job_id) do
      {:ok, entry} -> {:ok, entry.job}
      :error -> find_retained(state, job_id)
    end
  end

  @spec find_retained(state(), Job.id()) :: {:ok, Job.t()} | :not_found
  defp find_retained(state, job_id) do
    case Map.fetch(state.retained, job_id) do
      {:ok, job} -> {:ok, job}
      :error -> :not_found
    end
  end

  @spec find_live_by_monitor(state(), reference()) :: {Job.id(), live_entry()} | nil
  defp find_live_by_monitor(state, ref) do
    Enum.find(state.live, fn {_id, entry} -> entry.monitor_ref == ref end)
  end

  @spec exit_reason_to_outcome(term()) :: {Job.outcome(), non_neg_integer() | nil}
  defp exit_reason_to_outcome(:normal), do: {:completed, 0}
  defp exit_reason_to_outcome(:killed), do: {:cancelled, nil}
  defp exit_reason_to_outcome(_reason), do: {:crashed, nil}

  @spec generate_id() :: Job.id()
  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
