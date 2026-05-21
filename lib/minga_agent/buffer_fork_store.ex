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

  @doc "Merges forks and keeps failed forks alive for later conflict handling."
  @spec merge_all_keep_failed(GenServer.server()) :: [
          {String.t(), :ok | {:conflict, term()} | {:error, term()}}
        ]
  def merge_all_keep_failed(store) do
    GenServer.call(store, :merge_all_keep_failed, 30_000)
  end

  @doc "Merges only the forks whose paths are listed, keeping failed forks alive."
  @spec merge_paths_keep_failed(GenServer.server(), [String.t()]) :: [
          {String.t(), :ok | {:conflict, term()} | {:error, term()}}
        ]
  def merge_paths_keep_failed(store, paths) when is_list(paths) do
    GenServer.call(store, {:merge_paths_keep_failed, paths}, 30_000)
  end

  @doc "Discards all forks without merging."
  @spec discard_all(GenServer.server()) :: :ok
  def discard_all(store) do
    GenServer.call(store, :discard_all)
  end

  @doc "Discards only the forks whose paths are listed."
  @spec discard_paths(GenServer.server(), [String.t()]) :: :ok
  def discard_paths(store, paths) when is_list(paths) do
    GenServer.call(store, {:discard_paths, paths})
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

  def handle_call(:merge_all_keep_failed, _from, state) do
    {results, state} = merge_paths_keep_failed_state(state, Map.keys(state.forks))
    {:reply, results, state}
  end

  def handle_call({:merge_paths_keep_failed, paths}, _from, state) do
    {results, state} = merge_paths_keep_failed_state(state, paths)
    {:reply, results, state}
  end

  def handle_call(:discard_all, _from, state) do
    state = discard_paths_state(state, Map.keys(state.forks))
    {:reply, :ok, state}
  end

  def handle_call({:discard_paths, paths}, _from, state) do
    state = discard_paths_state(state, paths)
    {:reply, :ok, state}
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
        case apply_merge_to_parent(path, merged_text) do
          :ok -> {path, :ok}
          {:error, reason} -> {path, {:error, reason}}
        end

      {:conflict, hunks} ->
        {path, {:conflict, hunks}}

      {:error, reason} ->
        {path, {:error, reason}}
    end
  end

  @spec successful_merge_paths([{String.t(), :ok | {:conflict, term()} | {:error, term()}}]) ::
          MapSet.t(String.t())
  defp successful_merge_paths(results) do
    results
    |> Enum.flat_map(fn
      {path, :ok} -> [path]
      {_path, _result} -> []
    end)
    |> MapSet.new()
  end

  @spec merge_paths_keep_failed_state(state(), [String.t()]) ::
          {[{String.t(), :ok | {:conflict, term()} | {:error, term()}}], state()}
  defp merge_paths_keep_failed_state(state, paths) do
    paths_to_merge =
      paths
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn path ->
        case Map.fetch(state.forks, path) do
          {:ok, fork_pid} -> [{path, fork_pid}]
          :error -> []
        end
      end)

    results = Enum.map(paths_to_merge, fn {path, fork_pid} -> merge_fork(path, fork_pid) end)
    successful_paths = successful_merge_paths(results)
    state = stop_forks_for_paths(state, successful_paths)
    {results, state}
  end

  @spec discard_paths_state(state(), [String.t()]) :: state()
  defp discard_paths_state(state, paths) do
    stop_forks_for_paths(state, MapSet.new(paths))
  end

  @spec stop_forks_for_paths(state(), MapSet.t(String.t())) :: state()
  defp stop_forks_for_paths(state, paths) do
    {refs_to_stop, monitors} =
      split_map_by_paths(state.monitors, paths, fn {_ref, path} -> path end)

    {forks_to_stop, forks} = split_map_by_paths(state.forks, paths, fn {path, _pid} -> path end)

    Enum.each(refs_to_stop, fn {ref, _path} -> Process.demonitor(ref, [:flush]) end)

    Enum.each(forks_to_stop, fn {_path, fork_pid} ->
      if Process.alive?(fork_pid), do: GenServer.stop(fork_pid, :normal)
    end)

    %{state | forks: Map.new(forks), monitors: Map.new(monitors)}
  end

  @spec split_map_by_paths(map(), MapSet.t(String.t()), (term() -> String.t())) ::
          {[term()], [term()]}
  defp split_map_by_paths(map, paths, path_fun) do
    Enum.split_with(map, fn entry -> MapSet.member?(paths, path_fun.(entry)) end)
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
        try do
          case Minga.Buffer.replace_content(buf_pid, merged_text, :agent) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end
        catch
          :exit, _ -> {:error, :parent_unreachable}
        end

      :not_found ->
        # Buffer was closed while fork was active; write to disk
        File.write(path, merged_text)
    end
  end
end
