defmodule MingaAgent.ModelCatalog do
  @moduledoc """
  Runs the one model catalog load and lets every caller share it.

  `llm_db` loads its packaged catalog lazily, and the first load takes seconds. Concurrent loaders serialize on a `:global` lock whose retry backoff can add seconds to a caller that arrives while another load runs. This owner starts at most one load at a time in a low-priority task and replies to every waiter when it finishes, so a session start that arrives during the launch preload waits only for the remainder of that load.

  `preload/1` starts a load without waiting. `load/2` waits for the current or a new load. Neither ever runs the load in the caller's process.
  """

  use GenServer

  @typedoc "Why a load began; recorded on the `[:minga, :agent, :catalog_load]` span."
  @type trigger :: :preload | :start

  @type result :: {:ok, :ready} | {:error, :model_catalog_unavailable}

  @typep state :: %{
           task_supervisor: GenServer.server(),
           load: {reference(), [GenServer.from()]} | nil,
           loader: (-> result()),
           loaded?: (-> boolean())
         }

  @doc """
  Starts the catalog load owner.

  Options: `:name`, `:task_supervisor`, `:loader` (the load function) and `:loaded?` (the readiness probe the owner checks before starting a load).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Tells whether the catalog is loaded. Reads only the catalog's load epoch."
  @spec loaded?() :: boolean()
  def loaded?, do: LLMDB.epoch() != 0

  @doc "Starts a background load unless the catalog is loaded or already loading."
  @spec preload(GenServer.server()) :: :ok
  def preload(server \\ __MODULE__) do
    if loaded?(), do: :ok, else: GenServer.cast(server, :preload)
  end

  @doc "Waits for the catalog, joining a load in progress. Call it off the Editor."
  @spec load(GenServer.server(), timeout()) :: result()
  def load(server \\ __MODULE__, timeout \\ :infinity) do
    if loaded?(), do: {:ok, :ready}, else: GenServer.call(server, :load, timeout)
  catch
    :exit, reason ->
      Minga.Log.warning(:agent, fn ->
        "[Agent] Model catalog owner unavailable: #{inspect(reason)}"
      end)

      {:error, :model_catalog_unavailable}
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    {:ok,
     %{
       task_supervisor: Keyword.get(opts, :task_supervisor, Minga.Eval.TaskSupervisor),
       load: nil,
       loader: Keyword.get(opts, :loader, &load_packaged_catalog/0),
       loaded?: Keyword.get(opts, :loaded?, &loaded?/0)
     }}
  end

  @impl GenServer
  def handle_cast(:preload, state), do: {:noreply, begin_load(state, :preload, nil)}

  @impl GenServer
  def handle_call(:load, from, state) do
    if state.loaded?.(),
      do: {:reply, {:ok, :ready}, state},
      else: {:noreply, begin_load(state, :start, from)}
  end

  @impl GenServer
  def handle_info({ref, result}, %{load: {ref, waiters}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, waiters, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{load: {ref, waiters}} = state) do
    Minga.Log.error(:agent, fn -> "[Agent] Model catalog load crashed: #{inspect(reason)}" end)
    {:noreply, finish(state, waiters, {:error, :model_catalog_unavailable})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec begin_load(state(), trigger(), GenServer.from() | nil) :: state()
  defp begin_load(%{load: {ref, waiters}} = state, _trigger, from),
    do: %{state | load: {ref, add_waiter(waiters, from)}}

  defp begin_load(%{load: nil} = state, trigger, from) do
    loader = state.loader

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        # Background work: the Editor, renderer and input keep their priority.
        Process.flag(:priority, :low)

        Minga.Telemetry.span([:minga, :agent, :catalog_load], %{trigger: trigger}, fn ->
          run_loader(loader)
        end)
      end)

    %{state | load: {task.ref, add_waiter([], from)}}
  end

  @spec add_waiter([GenServer.from()], GenServer.from() | nil) :: [GenServer.from()]
  defp add_waiter(waiters, nil), do: waiters
  defp add_waiter(waiters, from), do: [from | waiters]

  @spec finish(state(), [GenServer.from()], result()) :: state()
  defp finish(state, waiters, result) do
    Enum.each(waiters, &GenServer.reply(&1, result))
    %{state | load: nil}
  end

  # llm_db raises its load failure on the first query. Callers see only the
  # public error; the cause goes to the log.
  @spec run_loader((-> result())) :: result()
  defp run_loader(loader) do
    loader.()
  rescue
    error in LLMDB.LoadError ->
      Minga.Log.error(:agent, fn ->
        "[Agent] Model catalog load failed: #{Exception.message(error)}"
      end)

      {:error, :model_catalog_unavailable}
  end

  @spec load_packaged_catalog() :: result()
  defp load_packaged_catalog do
    _providers = LLMDB.providers()
    {:ok, :ready}
  end
end
