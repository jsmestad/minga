defmodule MingaEditor.Agent.ConnectionInput do
  @moduledoc """
  Holds sealed setup input outside the Editor's effect request and outcome.

  An unjoined worker cannot write credentials. The scheduled effect joins it with a one-use receipt and owns its execution lifetime. Session still orders the actual write against exact-target cancellation.
  """

  alias MingaAgent.Credentials.Secret
  alias MingaAgent.Session
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}

  @join_window 5_000
  @await_time 160_000

  @type input_kind :: {:api_key, String.t()}
  @type receipt :: reference()
  @type result :: {:ok, ConnectionSnapshot.t()} | {:error, atom()}
  @typep input_context :: {ConnectionTarget.t(), reference(), input_kind(), receipt()}

  @doc "Starts a supervised holder and delivers the secret directly to it."
  @spec start(
          GenServer.server(),
          pid(),
          ConnectionTarget.t(),
          reference(),
          input_kind(),
          Secret.t()
        ) ::
          {:ok, pid(), receipt()} | {:error, :input_worker_unavailable}
  def start(
        task_supervisor,
        owner,
        %ConnectionTarget{} = target,
        operation_ref,
        kind,
        secret
      ) do
    receipt = make_ref()
    context = {target, operation_ref, kind, receipt}

    case Task.Supervisor.start_child(task_supervisor, __MODULE__, :run, [owner, context]) do
      {:ok, worker} ->
        :ok = Session.request_api_key_worker(target.session, target, operation_ref, worker)
        send(worker, {:sealed_input, receipt, secret})
        {:ok, worker, receipt}

      {:error, _reason} ->
        {:error, :input_worker_unavailable}
    end
  catch
    :exit, _reason -> {:error, :input_worker_unavailable}
  end

  @doc "Joins as the scheduled worker and waits for a credential outcome, not input admission."
  @spec await(pid(), receipt()) :: result()
  def await(worker, receipt) do
    monitor = Process.monitor(worker)
    send(worker, {:join, receipt, self()})

    receive do
      {:connection_input_joined, ^receipt, ^worker} ->
        await_joined(worker, receipt, monitor)

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :input_worker_unavailable}
    after
      @join_window ->
        Process.demonitor(monitor, [:flush])
        {:error, :input_worker_unavailable}
    end
  end

  @spec await_joined(pid(), receipt(), reference()) :: result()
  defp await_joined(worker, receipt, monitor) do
    receive do
      {:connection_input_result, ^receipt, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :input_worker_unavailable}
    after
      @await_time ->
        Process.unlink(worker)
        Process.exit(worker, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :input_worker_timeout}
    end
  end

  @doc "Discards an unjoined holder with the exact receipt."
  @spec abort(pid(), receipt()) :: :ok
  def abort(worker, receipt) do
    send(worker, {:abort, receipt})
    :ok
  end

  @doc false
  @spec run(pid(), input_context()) :: :ok
  def run(owner, {%ConnectionTarget{session: session}, operation_ref, _kind, receipt} = context) do
    Process.flag(:sensitive, true)
    owner_ref = Process.monitor(owner)
    session_ref = Process.monitor(session)
    deadline = System.monotonic_time(:millisecond) + @join_window

    receive do
      {:sealed_input, ^receipt, secret} ->
        wait_for_join(context, secret, owner_ref, session_ref, deadline)

      {:abort, ^receipt} ->
        :ok

      {:connection_cancelled, ^operation_ref} ->
        :ok

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        :ok

      {:DOWN, ^session_ref, :process, _pid, _reason} ->
        :ok
    after
      @join_window -> :ok
    end
  end

  @spec wait_for_join(input_context(), Secret.t(), reference(), reference(), integer()) :: :ok
  defp wait_for_join(
         context,
         secret,
         owner_ref,
         session_ref,
         deadline
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)
    await_input_join(context, secret, owner_ref, session_ref, remaining)
  end

  @spec await_input_join(input_context(), Secret.t(), reference(), reference(), integer()) :: :ok
  defp await_input_join(_context, _secret, _owner_ref, _session_ref, remaining)
       when remaining <= 0, do: :ok

  defp await_input_join(
         {_target, operation_ref, _kind, receipt} = context,
         secret,
         owner_ref,
         session_ref,
         remaining
       ) do
    receive do
      {:join, ^receipt, join} when is_pid(join) ->
        # The scheduler's canceled task exits abnormally and takes this worker with it.
        Process.link(join)
        send(join, {:connection_input_joined, receipt, self()})
        result = submit(context, secret)
        send(join, {:connection_input_result, receipt, result})
        :ok

      {:abort, ^receipt} ->
        :ok

      {:connection_cancelled, ^operation_ref} ->
        :ok

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        :ok

      {:DOWN, ^session_ref, :process, _pid, _reason} ->
        :ok
    after
      remaining -> :ok
    end
  end

  @spec submit(input_context(), Secret.t()) :: result()
  defp submit(
         {%ConnectionTarget{session: session} = target, operation_ref, {:api_key, provider},
          _receipt},
         secret
       ) do
    receive do
      {:api_key_worker_binding, ^operation_ref, :ok} ->
        with :ok <- prepare_model_catalog() do
          Session.commit_api_key(session, target, operation_ref, provider, secret)
        end

      {:api_key_worker_binding, ^operation_ref, {:error, reason}} ->
        {:error, reason}

      {:connection_cancelled, ^operation_ref} ->
        {:error, :cancelled}
    after
      @join_window -> {:error, :input_worker_unavailable}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :credential_result_unknown}
    :exit, _reason -> {:error, :session_unavailable}
  end

  @spec prepare_model_catalog() :: :ok | {:error, :model_catalog_unavailable}
  defp prepare_model_catalog do
    # First use parses the bundled catalog. Do it in the authorized worker before Session refreshes model readiness.
    _providers = LLMDB.providers()
    :ok
  rescue
    LLMDB.LoadError -> {:error, :model_catalog_unavailable}
  end
end
