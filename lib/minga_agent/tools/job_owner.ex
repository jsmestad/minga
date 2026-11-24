defmodule MingaAgent.Tools.JobOwner do
  @moduledoc """
  Supervises the running shell jobs of one agent session.

  The Session admits each job in its `MingaAgent.Session.JobLedger` and passes the admitted record here. The owner runs the command in a linked task through the injected process backend, reports `{:job_started, id, epoch}` once the task exists, and reports exactly one `{:job_settled, id, epoch, outcome, exit_code, output}` for every job, foreground or background. It keeps only live task bookkeeping; job identity and recorded status belong to the Session.

  When an artifact store is available, job output is retained through it and the settled report carries the output reference. A foreground job captures under its tool call's capture key, because the job's output is the call's result. A background job captures under a key derived from its job id, because the start call stores its own handle text under the call's key.

  Foreground starts block the caller until the job ends and return the shell result. Background starts return once the task is running. Job tasks are linked, so they die with the owner, and `terminate/2` kills any still running.

  The owner only sends to the Session and never calls it, so Session calls into the owner (cancel, reap) cannot deadlock.
  """

  use GenServer

  alias MingaAgent.Session.JobLedger.Record
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tools.OutputCapture
  alias MingaAgent.Tools.ProcessBackend.System, as: SystemProcessBackend
  alias MingaAgent.Tools.Shell

  @typedoc "Options for running a job."
  @type start_opts :: [
          process_backend: module(),
          on_output: (String.t() -> :ok),
          env: [{String.t(), String.t()}],
          artifact_store: GenServer.server() | nil,
          capture_key: term() | nil,
          helper_path: String.t()
        ]

  @typedoc "Why the owner refused to run an admitted record."
  @type start_error :: :stale_epoch | :already_running

  @typedoc "Message sent to the Session when a job's task is running."
  @type started_message :: {:job_started, Record.id(), Record.epoch()}

  @typedoc "Message sent to the Session when a job ends."
  @type settled_message ::
          {:job_settled, Record.id(), Record.epoch(), Record.outcome(), integer() | nil,
           Record.output()}

  @type init_opts :: [session: pid(), epoch: Record.epoch()]

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Starts a JobOwner that reports to `session` under the given epoch."
  @spec start_link(init_opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Runs an admitted foreground job and blocks until it ends.

  Returns the shell result as `Shell.execute/4` or `Shell.capture/4` would. The Session also receives the job's settled report.
  """
  @spec start_foreground(GenServer.server(), Record.t(), start_opts()) ::
          Shell.result() | {:error, start_error()}
  def start_foreground(owner, %Record{background?: false} = record, opts \\ []) do
    timeout_ms = (record.timeout_secs + 5) * 1_000
    GenServer.call(owner, {:start, record, opts}, timeout_ms)
  end

  @doc "Runs an admitted background job and returns once its task is running."
  @spec start_background(GenServer.server(), Record.t(), start_opts()) ::
          :ok | {:error, start_error()}
  def start_background(owner, %Record{background?: true} = record, opts \\ []) do
    GenServer.call(owner, {:start, record, opts})
  end

  @doc "Kills a running job. The Session receives a `:cancelled` settled report."
  @spec cancel(GenServer.server(), Record.id()) :: :ok | {:error, :job_not_found}
  def cancel(owner, job_id) when is_binary(job_id) do
    GenServer.call(owner, {:cancel, job_id})
  end

  @doc "Kills every running job without reporting. Called during session teardown."
  @spec reap_all(GenServer.server()) :: :ok
  def reap_all(owner) do
    GenServer.call(owner, :reap_all)
  end

  # ── Server callbacks ────────────────────────────────────────────────────────

  @typep live_entry :: %{
           record: Record.t(),
           task_pid: pid(),
           monitor_ref: reference(),
           from: GenServer.from() | nil
         }

  @typep state :: %{
           session: pid(),
           epoch: Record.epoch(),
           live: %{Record.id() => live_entry()},
           tasks: MapSet.t(pid()),
           cancelled_unstarted: MapSet.t(Record.id())
         }

  @impl GenServer
  @spec init(init_opts()) :: {:ok, state()}
  def init(opts) do
    # Job tasks are linked so they die with the owner; trapping keeps a task exit from stopping it.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       session: Keyword.fetch!(opts, :session),
       epoch: Keyword.fetch!(opts, :epoch),
       live: %{},
       tasks: MapSet.new(),
       cancelled_unstarted: MapSet.new()
     }}
  end

  @impl GenServer
  def handle_call({:start, %Record{epoch: epoch}, _opts}, _from, %{epoch: current} = state)
      when epoch != current do
    {:reply, {:error, :stale_epoch}, state}
  end

  def handle_call({:start, %Record{id: id} = record, opts}, from, state) do
    cond do
      Map.has_key?(state.live, id) ->
        {:reply, {:error, :already_running}, state}

      MapSet.member?(state.cancelled_unstarted, id) ->
        cancelled = MapSet.delete(state.cancelled_unstarted, id)
        {:reply, {:error, :cancelled}, %{state | cancelled_unstarted: cancelled}}

      true ->
        start_job(state, record, job_opts(record, opts), from)
    end
  end

  def handle_call({:cancel, job_id}, _from, state) do
    case Map.fetch(state.live, job_id) do
      {:ok, entry} ->
        Process.exit(entry.task_pid, :kill)

        {:reply, :ok,
         settle(state, entry, :cancelled, nil, no_output(), {:error, "job cancelled"})}

      # Session cancels a job whose caller died; if its start has not arrived yet, refuse it later.
      :error ->
        cancelled = MapSet.put(state.cancelled_unstarted, job_id)
        {:reply, {:error, :job_not_found}, %{state | cancelled_unstarted: cancelled}}
    end
  end

  def handle_call(:reap_all, _from, state) do
    Enum.each(state.live, fn {_job_id, entry} ->
      Process.exit(entry.task_pid, :kill)
      Process.demonitor(entry.monitor_ref, [:flush])
      if entry.from, do: GenServer.reply(entry.from, {:error, :session_terminated})
    end)

    {:reply, :ok, %{state | live: %{}}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_live_by_monitor(state, ref) do
      %{task_pid: ^pid} = entry ->
        result = {:error, "job process exited: #{inspect(reason)}"}
        {:noreply, settle(state, entry, :crashed, nil, no_output(), result)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:job_result, job_id, result, exit_code}, state) do
    case Map.fetch(state.live, job_id) do
      {:ok, entry} ->
        {outcome, exit_code, output} = classify_result(result, exit_code)
        {:noreply, settle(state, entry, outcome, exit_code, output, result)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    if MapSet.member?(state.tasks, pid) do
      {:noreply, %{state | tasks: MapSet.delete(state.tasks, pid)}}
    else
      {:stop, reason, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, state) do
    Enum.each(state.live, fn {_job_id, entry} -> Process.exit(entry.task_pid, :kill) end)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  # Foreground callers wait for the settled result; background callers get :ok once the task runs.
  @spec start_job(state(), Record.t(), start_opts(), GenServer.from()) ::
          {:noreply, state()} | {:reply, :ok, state()}
  defp start_job(state, %Record{background?: background?} = record, opts, from) do
    waiter = if background?, do: nil, else: from
    state = spawn_job(state, record, opts, waiter)
    send(state.session, {:job_started, record.id, record.epoch})

    if background?, do: {:reply, :ok, state}, else: {:noreply, state}
  end

  @spec spawn_job(state(), Record.t(), start_opts(), GenServer.from() | nil) :: state()
  defp spawn_job(state, record, opts, from) do
    owner = self()
    %Record{id: job_id, command: command, cwd: cwd, timeout_secs: timeout_secs} = record

    task_pid =
      spawn_link(fn ->
        task = self()

        report_exit = fn code ->
          send(task, {:job_exit_status, code})
          :ok
        end

        result =
          command
          |> run_shell(cwd, timeout_secs, Keyword.put(opts, :on_exit_status, report_exit))
          |> retain_text_result(opts)

        send(owner, {:job_result, job_id, result, received_exit_status()})
      end)

    entry = %{
      record: record,
      task_pid: task_pid,
      monitor_ref: Process.monitor(task_pid),
      from: from
    }

    %{state | live: Map.put(state.live, job_id, entry), tasks: MapSet.put(state.tasks, task_pid)}
  end

  # A background job outlives the tool call that started it, and that call stores its own result
  # under the call's capture key. The job therefore captures under a key derived from its id, in
  # the same checkpoint, so the two captures can never resume each other.
  @spec job_opts(Record.t(), start_opts()) :: start_opts()
  defp job_opts(%Record{background?: false}, opts), do: opts

  defp job_opts(%Record{background?: true, id: id}, opts) do
    case Keyword.get(opts, :capture_key) do
      {:delivery, checkpoint, _call_id} ->
        Keyword.put(opts, :capture_key, {:delivery, checkpoint, "job:" <> id})

      _no_capture ->
        opts
    end
  end

  # A backend that returns text instead of a retained Output still has its bytes stored through the
  # artifact store when one is available, so the settled record and the caller share one reference.
  @spec retain_text_result(Shell.result(), start_opts()) :: Shell.result()
  defp retain_text_result({:ok, text} = result, opts) when is_binary(text),
    do: capture_text(result, text, [], opts)

  defp retain_text_result({:error, {:incomplete, reason, text}} = result, opts)
       when is_atom(reason) and is_binary(text),
       do: capture_text(result, text, [capture_status: {:incomplete, reason}], opts)

  defp retain_text_result(result, _opts), do: result

  @spec capture_text(Shell.result(), String.t(), OutputCapture.capture_opts(), start_opts()) ::
          Shell.result()
  defp capture_text(result, text, capture_opts, opts) do
    case {Keyword.get(opts, :artifact_store), Keyword.get(opts, :capture_key)} do
      {nil, _key} -> result
      {_store, nil} -> result
      {store, key} -> OutputCapture.bytes(store, key, text, capture_opts)
    end
  catch
    :exit, reason -> {:error, {:retention_unavailable, reason}}
  end

  # Shell reports the exit code through its callback in this same process before it returns.
  @spec received_exit_status() :: integer() | nil
  defp received_exit_status do
    receive do
      {:job_exit_status, code} -> code
    after
      0 -> nil
    end
  end

  @spec run_shell(String.t(), String.t(), pos_integer(), start_opts()) :: Shell.result()
  defp run_shell(command, cwd, timeout_secs, opts) do
    {backend, opts} = Keyword.pop(opts, :process_backend, SystemProcessBackend)
    backend.shell(command, cwd, timeout_secs, opts)
  end

  @spec classify_result(Shell.result(), integer() | nil) ::
          {Record.outcome(), integer() | nil, Record.output()}
  defp classify_result({:ok, text}, exit_code) when is_binary(text),
    do: {exit_outcome(exit_code), exit_code, %{reference: nil, preview: text}}

  defp classify_result({:ok, %Output{} = output}, exit_code),
    do: {exit_outcome(exit_code), exit_code, output_facts(output)}

  defp classify_result({:error, {:incomplete, :timeout, text}}, _exit_code) when is_binary(text),
    do: {:timeout, nil, %{reference: nil, preview: text}}

  defp classify_result({:error, %Output{capture: {:incomplete, :timeout}} = output}, _exit_code),
    do: {:timeout, nil, output_facts(output)}

  defp classify_result({:error, %Output{} = output}, exit_code),
    do: {:failed, exit_code, output_facts(output)}

  defp classify_result({:error, reason}, exit_code) when is_binary(reason),
    do: {:failed, exit_code, %{reference: nil, preview: reason}}

  defp classify_result({:error, _reason}, exit_code), do: {:failed, exit_code, no_output()}

  @spec exit_outcome(integer() | nil) :: :completed | :failed
  defp exit_outcome(0), do: :completed
  defp exit_outcome(_nonzero_or_unknown), do: :failed

  @spec output_facts(Output.t()) :: Record.output()
  defp output_facts(%Output{reference: reference, view: view}),
    do: %{reference: reference, preview: view}

  @spec no_output() :: Record.output()
  defp no_output, do: %{reference: nil, preview: nil}

  # Reports the end to the Session before replying, so a caller that queries the Session next sees it.
  @spec settle(
          state(),
          live_entry(),
          Record.outcome(),
          integer() | nil,
          Record.output(),
          Shell.result()
        ) :: state()
  defp settle(state, entry, outcome, exit_code, output, result) do
    %Record{id: id, epoch: epoch} = entry.record
    Process.demonitor(entry.monitor_ref, [:flush])
    send(state.session, {:job_settled, id, epoch, outcome, exit_code, output})
    if entry.from, do: GenServer.reply(entry.from, result)
    %{state | live: Map.delete(state.live, id)}
  end

  @spec find_live_by_monitor(state(), reference()) :: live_entry() | nil
  defp find_live_by_monitor(state, ref) do
    Enum.find_value(state.live, fn {_id, entry} -> if entry.monitor_ref == ref, do: entry end)
  end
end
