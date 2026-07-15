defmodule Minga.Extension.Instance do
  @moduledoc """
  Stable per-extension lifecycle authority.

  Public requests, runtime exits, drain events, and finalizer acknowledgements
  share this one mailbox. Handler modules compute transitions, while this sole
  GenServer owns message ordering and lifecycle authority.
  """

  use GenServer

  alias Minga.Extension.CodeLease
  alias Minga.Extension.Instance.Lifecycle
  alias Minga.Extension.Instance.QuiescenceTransition
  alias Minga.Extension.Instance.Recovery
  alias Minga.Extension.Instance.StartTransition
  alias Minga.Extension.Instance.State
  alias Minga.Extension.Instance.StopTransition
  alias Minga.Extension.Instance.TransitionHandler
  alias Minga.Extension.Instance.Worker
  alias Minga.Extension.InstanceRegistry

  @type server :: GenServer.server()
  @type result :: {:ok, pid()} | {:error, term()}

  @doc "Builds the permanent authority child spec."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Starts one named lifecycle authority."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :extension)
    registry = Keyword.get(opts, :instance_registry, InstanceRegistry)
    GenServer.start_link(__MODULE__, opts, name: InstanceRegistry.via(registry, :instance, name))
  end

  @doc "Updates the declaration snapshot used by later transitions."
  @spec declare(server(), Minga.Extension.Entry.t(), GenServer.server(), keyword()) ::
          :ok | {:error, term()}
  def declare(server, declaration, registry, opts) do
    GenServer.call(server, {:declare, declaration, registry, opts}, :infinity)
  end

  @doc "Starts or joins the extension's current start transition."
  @spec start(server()) :: result()
  def start(server), do: GenServer.call(server, :start, :infinity)

  @doc "Starts only when the captured deferred declaration is still current."
  @spec start_deferred(server(), Minga.Extension.Entry.t()) :: result()
  def start_deferred(server, declaration) do
    GenServer.call(server, {:start_deferred, declaration}, :infinity)
  end

  @doc "Projects a bulk prerequisite failure through the lifecycle authority."
  @spec fail_start(server(), term()) :: {:error, term()}
  def fail_start(server, reason), do: GenServer.call(server, {:fail_start, reason}, :infinity)

  @doc "Prepares and captures the declaration artifact and returns its load policy."
  @spec load_policy(server()) :: {:ok, Minga.Extension.load_policy()} | {:error, term()}
  def load_policy(server), do: GenServer.call(server, :load_policy, :infinity)

  @doc "Registers a lazy stub through this authority."
  @spec stub(server()) :: :ok | {:error, term()}
  def stub(server), do: GenServer.call(server, :stub, :infinity)

  @doc "Stops or joins the extension's current stop transition."
  @spec stop(server(), keyword()) :: :ok | {:error, term()}
  def stop(server, opts \\ []), do: GenServer.call(server, {:stop, opts}, :infinity)

  @doc "Returns the tagged authority phase for diagnostics and focused tests."
  @spec phase(server()) :: State.phase()
  def phase(server), do: GenServer.call(server, :phase)

  @impl true
  @spec init(keyword()) :: {:ok, State.t(), {:continue, :recover_local_runtime}}
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :extension)
    declaration_registry = Keyword.fetch!(opts, :declaration_registry)

    declaration =
      case Minga.Extension.Registry.get(declaration_registry, name) do
        {:ok, current} -> current
        :error -> Keyword.fetch!(opts, :declaration)
      end

    state =
      State.new(
        name,
        declaration,
        declaration_registry,
        Keyword.get(opts, :instance_registry, InstanceRegistry),
        Keyword.get(opts, :collaborators, [])
      )

    :ok = InstanceRegistry.notify_waiters(state.instance_registry, :instance, state.name, self())
    {:ok, state, {:continue, :recover_local_runtime}}
  end

  @impl true
  def handle_continue(:recover_local_runtime, state), do: Recovery.recover_local_runtime(state)

  @impl true
  def handle_call({:declare, declaration, registry, opts}, _from, state),
    do: Lifecycle.declare(state, declaration, registry, opts)

  def handle_call(:phase, _from, state), do: {:reply, state.phase, state}
  def handle_call(:load_policy, _from, state), do: StartTransition.load_policy_result(state)
  def handle_call(:start, from, state), do: StartTransition.request_start(state, from)

  def handle_call({:fail_start, reason}, from, state),
    do: StartTransition.request_prerequisite_failure(state, from, reason)

  def handle_call({:start_deferred, declaration}, from, state),
    do: StartTransition.request_deferred_start(state, from, declaration)

  def handle_call(:stub, _from, state), do: StartTransition.request_stub(state)

  def handle_call({:stop, opts}, from, state),
    do: StopTransition.request_stop(State.configure(state, opts), from)

  @impl true
  def handle_info(:perform_start, state), do: StartTransition.perform_start(state)

  def handle_info({Worker, :runtime_started, id, pid}, state),
    do: StartTransition.runtime_started(state, id, pid)

  def handle_info({Worker, :done, id, result}, state),
    do: TransitionHandler.transition_done(state, id, result)

  def handle_info({Worker, :timeout, id, kind}, state),
    do: TransitionHandler.transition_timeout(state, id, kind)

  def handle_info({CodeLease, :drained, source, ref}, state),
    do: QuiescenceTransition.source_drained(state, source, ref)

  def handle_info({CodeLease, :drain_timeout, ref}, state),
    do: QuiescenceTransition.drain_timeout(state, ref)

  def handle_info({:extension_finalizer_ack, ref, family, result}, state),
    do: QuiescenceTransition.finalizer_ack(state, ref, family, result)

  def handle_info({:extension_cleanup_ack, ref, result}, state),
    do: StopTransition.cleanup_ack(state, ref, result)

  def handle_info({:DOWN, ref, :process, pid, reason}, state),
    do: TransitionHandler.process_down(state, ref, pid, reason)

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}
end
