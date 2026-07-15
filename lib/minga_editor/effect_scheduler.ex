defmodule MingaEditor.EffectScheduler do
  @moduledoc """
  Editor-generation-owned process wrapper for bounded slow effects.

  Work is serialized by stable resource identity while unrelated resources run
  concurrently. Lifecycle, policy, admission, and worker transitions live in
  `MingaEditor.EffectScheduler.Engine`.
  """

  use GenServer

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler.Engine
  alias MingaEditor.EffectScheduler.State

  @default_max_admitted 64

  @typedoc "Scheduler server reference."
  @type server :: GenServer.server()
  @type admission :: Engine.admission()
  @type handoff :: Engine.handoff()
  @type admission_error :: Engine.admission_error()
  @type claim :: Engine.claim()
  @type cancel_error :: :not_found | :scheduler_unavailable
  @type source :: Minga.Extension.ContributionCleanup.contribution_source()

  @doc "Starts an effect scheduler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      server_name -> GenServer.start_link(__MODULE__, opts, name: server_name)
    end
  end

  @doc "Attaches the single Editor owner for this scheduler generation."
  @spec attach(server(), pid()) :: :ok | {:error, :already_attached}
  def attach(server, owner) when is_pid(owner), do: GenServer.call(server, {:attach, owner})

  @doc "Admits a typed effect request under its declared bounded policy."
  @spec schedule(server(), Request.t()) :: admission()
  def schedule(server, %Request{} = request), do: GenServer.call(server, {:schedule, request})

  @doc "Cancels an admitted request by id."
  @spec cancel(server(), Request.id()) :: :ok | {:error, :not_found}
  def cancel(server, request_id) when is_reference(request_id),
    do: GenServer.call(server, {:cancel, request_id})

  @doc "Cancels the admitted request correlated with a semantic operation."
  @spec cancel_operation(server() | nil, MingaEditor.State.Operation.id()) ::
          :ok | {:error, cancel_error()}
  def cancel_operation(nil, operation_id) when is_integer(operation_id) and operation_id > 0,
    do: {:error, :scheduler_unavailable}

  def cancel_operation(server, operation_id) when is_integer(operation_id) and operation_id > 0 do
    GenServer.call(server, {:cancel_operation, operation_id})
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  @doc "Cancels queued, running, and pending work attributed to a source."
  @spec cancel_source(server() | nil, source()) :: :ok | {:error, :scheduler_unavailable}
  def cancel_source(nil, _source), do: {:error, :scheduler_unavailable}

  def cancel_source(server, source) do
    GenServer.call(server, {:cancel_source, source})
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  @doc "Cancels queued, running, and pending work for a semantic resource."
  @spec cancel_resource(server() | nil, Request.resource()) ::
          :ok | {:error, :scheduler_unavailable}
  def cancel_resource(nil, _resource), do: {:error, :scheduler_unavailable}

  def cancel_resource(server, resource) do
    GenServer.call(server, {:cancel_resource, resource})
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  @doc "Returns whether a source has queued, running, or pending work."
  @spec active_source?(server() | nil, source()) :: boolean()
  def active_source?(nil, _source), do: false

  def active_source?(server, source) do
    GenServer.call(server, {:active_source?, source})
  catch
    :exit, _reason -> false
  end

  @doc "Returns whether an exact request still holds scheduler admission."
  @spec admitted?(server() | nil, Request.id()) :: boolean()
  def admitted?(nil, _request_id), do: false

  def admitted?(server, request_id) when is_reference(request_id) do
    GenServer.call(server, {:admitted?, request_id})
  catch
    :exit, _reason -> false
  end

  @doc "Claims a still-current candidate before its domain handler applies it."
  @spec claim(server(), Outcome.t()) :: claim()
  def claim(server, %Outcome{} = outcome), do: GenServer.call(server, {:claim, outcome})

  @doc "Finalizes the domain-applied terminal outcome exactly once."
  @spec finalize(server(), Outcome.t()) :: :ok
  def finalize(server, %Outcome{} = outcome), do: GenServer.cast(server, {:finalize, outcome})

  @doc "Atomically finalizes one candidate and admits its typed follow-up request."
  @spec finalize_and_schedule(server(), Outcome.t(), Request.t()) :: handoff()
  def finalize_and_schedule(server, %Outcome{} = outcome, %Request{} = request),
    do: GenServer.call(server, {:finalize_and_schedule, outcome, request})

  @doc "Returns whether the scheduler has running or queued work for a domain handler."
  @spec active?(server() | nil, module()) :: boolean()
  def active?(nil, _handler), do: false

  def active?(server, handler) when is_atom(handler) do
    GenServer.call(server, {:active?, handler})
  catch
    :exit, _reason -> false
  end

  @doc "Returns bounded scheduler statistics without exposing queued payloads."
  @spec stats(server()) :: %{
          resources: non_neg_integer(),
          running: non_neg_integer(),
          queued: non_neg_integer(),
          pending: non_neg_integer(),
          admitted: non_neg_integer(),
          capacity: pos_integer()
        }
  def stats(server), do: GenServer.call(server, :stats)

  @impl true
  @spec init(keyword()) :: {:ok, State.t()}
  def init(opts) do
    Process.flag(:trap_exit, true)
    max_admitted = Keyword.get(opts, :max_admitted, @default_max_admitted)
    true = is_integer(max_admitted) and max_admitted > 0

    {:ok,
     State.new(
       Keyword.fetch!(opts, :task_supervisor),
       Keyword.get(opts, :observer),
       max_admitted
     )}
  end

  @impl true
  def handle_call({:attach, owner}, _from, state), do: reply(Engine.attach(state, owner))

  def handle_call({:schedule, request}, _from, state),
    do: reply(Engine.schedule(state, request))

  def handle_call({:cancel, request_id}, _from, state),
    do: reply(Engine.cancel(state, request_id))

  def handle_call({:cancel_operation, operation_id}, _from, state),
    do: reply(Engine.cancel_operation(state, operation_id))

  def handle_call({:cancel_source, source}, _from, state),
    do: reply(Engine.cancel_source(state, source))

  def handle_call({:cancel_resource, resource}, _from, state),
    do: reply(Engine.cancel_resource(state, resource))

  def handle_call({:active_source?, source}, _from, state),
    do: {:reply, Engine.active_source?(state, source), state}

  def handle_call({:admitted?, request_id}, _from, state),
    do: {:reply, Engine.admitted?(state, request_id), state}

  def handle_call({:claim, outcome}, _from, state), do: reply(Engine.claim(state, outcome))

  def handle_call({:finalize_and_schedule, outcome, request}, _from, state),
    do: reply(Engine.finalize_and_schedule(state, outcome, request))

  def handle_call({:active?, handler}, _from, state),
    do: {:reply, Engine.active?(state, handler), state}

  def handle_call(:stats, _from, state), do: {:reply, Engine.stats(state), state}

  @impl true
  def handle_cast({:finalize, outcome}, state), do: {:noreply, Engine.finalize(state, outcome)}

  @impl true
  def handle_info({task_ref, result}, state) when is_reference(task_ref),
    do: {:noreply, Engine.task_result(state, task_ref, result)}

  def handle_info({:DOWN, ref, :process, pid, reason}, state),
    do: {:noreply, Engine.process_down(state, ref, pid, reason)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), State.t()) :: :ok
  def terminate(_reason, state) do
    _state = Engine.shutdown(state, :owner_shutdown)
    :ok
  end

  @spec reply({term(), State.t()}) :: {:reply, term(), State.t()}
  defp reply({response, state}), do: {:reply, response, state}
end
