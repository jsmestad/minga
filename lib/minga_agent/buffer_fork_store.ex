defmodule MingaAgent.BufferForkStore do
  @moduledoc """
  Holds the mapping of file paths to Buffer.Fork pids for an agent session.

  Each agent session gets its own store. Forks are created lazily on the
  first write to a file that has an open buffer. The store monitors each
  fork and removes it if the fork process dies.

  The store is an Agent wrapping a map and a list of monitor refs. Tool
  callbacks (which run in a spawned Task) query and update it via the
  public API.

  ## Lifecycle

      {:ok, store} = BufferForkStore.start_link()
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, "/abs/path/lib/foo.ex", buffer_pid)
      forks = BufferForkStore.all(store)
      BufferForkStore.stop(store)
  """

  use GenServer

  alias Minga.Buffer.Fork

  @typedoc "The store's internal state."
  @type state :: %{
          forks: %{String.t() => pid()},
          monitors: %{reference() => String.t()}
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Starts a new empty fork store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  @doc """
  Returns the fork pid for `path`, creating one from `buffer_pid` if needed.

  If a fork already exists for this path, returns it. Otherwise creates a
  new fork from the parent buffer, stores it, and returns the pid.
  """
  @spec get_or_create(GenServer.server(), String.t(), pid()) ::
          {:ok, pid()} | {:error, term()}
  def get_or_create(store, path, buffer_pid) do
    GenServer.call(store, {:get_or_create, path, buffer_pid})
  end

  @doc "Returns the fork pid for `path`, or nil if no fork exists."
  @spec get(GenServer.server(), String.t()) :: pid() | nil
  def get(store, path) do
    GenServer.call(store, {:get, path})
  end

  @doc "Returns all forks as a `%{path => fork_pid}` map."
  @spec all(GenServer.server()) :: %{String.t() => pid()}
  def all(store) do
    GenServer.call(store, :all)
  end

  @doc "Merges all dirty forks back to their parent buffers. Returns results per path."
  @spec merge_all(GenServer.server()) :: [
          {String.t(), :ok | {:conflict, term()} | {:error, term()}}
        ]
  def merge_all(store) do
    GenServer.call(store, :merge_all, 30_000)
  end

  @doc "Discards all forks without merging."
  @spec discard_all(GenServer.server()) :: :ok
  def discard_all(store) do
    GenServer.call(store, :discard_all)
  end

  @doc "Stops the store, cleaning up all forks."
  @spec stop(GenServer.server()) :: :ok
  def stop(store) do
    GenServer.stop(store)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    {:ok, %{forks: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:get_or_create, path, buffer_pid}, _from, state) do
    case Map.get(state.forks, path) do
      nil ->
        case Fork.create(buffer_pid) do
          {:ok, fork_pid} ->
            ref = Process.monitor(fork_pid)

            new_state = %{
              state
              | forks: Map.put(state.forks, path, fork_pid),
                monitors: Map.put(state.monitors, ref, path)
            }

            {:reply, {:ok, fork_pid}, new_state}

          {:error, _} = err ->
            {:reply, err, state}
        end

      fork_pid ->
        {:reply, {:ok, fork_pid}, state}
    end
  end

  def handle_call({:get, path}, _from, state) do
    {:reply, Map.get(state.forks, path), state}
  end

  def handle_call(:all, _from, state) do
    {:reply, state.forks, state}
  end

  def handle_call(:merge_all, _from, state) do
    results = Enum.map(state.forks, fn {path, fork_pid} -> merge_fork(path, fork_pid) end)

    stop_all_forks(state)
    {:reply, results, %{state | forks: %{}, monitors: %{}}}
  end

  def handle_call(:discard_all, _from, state) do
    stop_all_forks(state)
    {:reply, :ok, %{state | forks: %{}, monitors: %{}}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {path, monitors} ->
        {:noreply, %{state | forks: Map.delete(state.forks, path), monitors: monitors}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_all_forks(state)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec merge_fork(String.t(), pid()) ::
          {String.t(), :ok | {:conflict, term()} | {:error, term()}}
  defp merge_fork(path, fork_pid) do
    if Fork.dirty?(fork_pid), do: do_merge_fork(path, fork_pid), else: {path, :ok}
  end

  @spec do_merge_fork(String.t(), pid()) ::
          {String.t(), :ok | {:conflict, term()} | {:error, term()}}
  defp do_merge_fork(path, fork_pid) do
    case Fork.merge(fork_pid) do
      {:ok, merged_text} ->
        apply_merge_to_parent(path, merged_text)
        {path, :ok}

      {:conflict, hunks} ->
        {path, {:conflict, hunks}}

      {:error, reason} ->
        {path, {:error, reason}}
    end
  end

  @spec stop_all_forks(state()) :: :ok
  defp stop_all_forks(state) do
    Enum.each(state.monitors, fn {ref, _path} ->
      Process.demonitor(ref, [:flush])
    end)

    Enum.each(state.forks, fn {_path, fork_pid} ->
      if Process.alive?(fork_pid), do: GenServer.stop(fork_pid, :normal)
    end)

    :ok
  end

  @spec apply_merge_to_parent(String.t(), String.t()) :: :ok | {:error, term()}
  defp apply_merge_to_parent(path, merged_text) do
    case Minga.Buffer.pid_for_path(path) do
      {:ok, buf_pid} ->
        Minga.Buffer.Server.replace_content(buf_pid, merged_text, :agent)
        :ok

      :not_found ->
        # Buffer was closed while fork was active; write to disk
        File.write(path, merged_text)
        :ok
    end
  rescue
    _ -> {:error, :parent_unreachable}
  end
end
