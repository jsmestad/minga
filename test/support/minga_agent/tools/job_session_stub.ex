defmodule MingaAgent.Test.JobSessionStub do
  @moduledoc """
  Stands in for `MingaAgent.Session` in tool-level shell tests.

  It speaks the Session's job message protocol over the real `MingaAgent.Session.JobLedger` and a real `MingaAgent.Tools.JobOwner`, so the shell and job tools run their production path without a full Session. It does not monitor admission callers or replace a dead owner; `MingaAgent.SessionJobOwnerTest` covers those against a real Session.
  """

  use GenServer

  alias MingaAgent.Session.JobLedger
  alias MingaAgent.Tools.JobOwner

  @doc "Starts the stub and its JobOwner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the tool context metadata that routes jobs to this stub."
  @spec metadata(pid(), map()) :: map()
  def metadata(stub, extra \\ %{}) when is_pid(stub) and is_map(extra),
    do: Map.merge(extra, %{parent_session: stub, session_jobs?: true})

  @impl GenServer
  def init(_opts) do
    {:ok, owner} = JobOwner.start_link(session: self(), epoch: 1)
    {:ok, %{owner: owner, ledger: JobLedger.new()}}
  end

  @impl GenServer
  def handle_call({:admit_job, spec}, _from, state) do
    case JobLedger.admit(state.ledger, spec, 1, DateTime.utc_now()) do
      {:ok, record, ledger} -> {:reply, {:ok, record, state.owner}, %{state | ledger: ledger}}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:job, job_id}, _from, state),
    do: {:reply, JobLedger.fetch(state.ledger, job_id), state}

  def handle_call(:jobs, _from, state), do: {:reply, JobLedger.list(state.ledger), state}

  def handle_call({:cancel_job, job_id}, _from, state) do
    reply =
      case JobOwner.cancel(state.owner, job_id) do
        :ok -> :ok
        {:error, :job_not_found} -> {:error, :already_terminal}
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info({:job_started, _job_id, _epoch}, state), do: {:noreply, state}

  def handle_info({:job_settled, job_id, epoch, outcome, exit_code, output}, state) do
    now = DateTime.utc_now()
    ledger = JobLedger.settle(state.ledger, job_id, epoch, outcome, exit_code, output, now)
    {:noreply, %{state | ledger: ledger}}
  end
end
