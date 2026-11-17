# credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry

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

  @type owner :: {:fork, pid()} | {:changeset, pid()}

  @typedoc "The store's internal state."
  @type state :: %{
          forks: %{String.t() => pid()},
          claims: %{String.t() => owner()},
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

  @doc """
  Pins a path to its first selected writer for this store's lifetime.

  Existing claims survive owner death and never fall back to another writer.
  Discarding a path releases its claim. Without candidates, leaves it unclaimed.
  """
  @spec claim_owner(GenServer.server(), String.t(), pid() | nil, pid() | nil) ::
          {:ok, owner()} | :not_found | {:error, term()}
  def claim_owner(store, path, buffer_pid, changeset_pid) do
    GenServer.call(store, {:claim_owner, path, buffer_pid, changeset_pid}, :infinity)
  end

  @doc "Atomically transfers a sealed fork claim to the changeset containing its published draft."
  @spec transfer_to_changeset(GenServer.server(), String.t(), pid(), pid()) ::
          :ok | {:error, term()}
  def transfer_to_changeset(store, path, expected_fork, changeset_pid) do
    GenServer.call(
      store,
      {:transfer_to_changeset, path, expected_fork, changeset_pid},
      :infinity
    )
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

  @doc "Merges all dirty forks back to their parent buffers. Failed and conflicting forks stay in the store for follow-up."
  @spec merge_all(GenServer.server()) :: [
          {String.t(), :ok | {:conflict, term()} | {:error, term()}}
        ]
  def merge_all(store) do
    GenServer.call(store, :merge_all, :infinity)
  end

  @doc "Merges forks and keeps failed forks alive for later conflict handling."
  @spec merge_all_keep_failed(GenServer.server()) :: [
          {String.t(), :ok | {:conflict, term()} | {:error, term()}}
        ]
  def merge_all_keep_failed(store) do
    GenServer.call(store, :merge_all_keep_failed, :infinity)
  end

  @doc "Discards one fork without merging."
  @spec discard(GenServer.server(), String.t()) :: :ok
  def discard(store, path) when is_binary(path) do
    GenServer.call(store, {:discard, path})
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
    Process.flag(:trap_exit, true)
    {:ok, %{forks: %{}, claims: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:get_or_create, path, buffer_pid}, _from, state) do
    {result, state} = claim_path(state, path, buffer_pid, nil)

    reply =
      case result do
        {:ok, {:fork, fork_pid}} -> {:ok, fork_pid}
        {:ok, {:changeset, _pid}} -> {:error, :owner_claimed_by_changeset}
        {:error, _reason} = error -> error
        :not_found -> {:error, :owner_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call({:claim_owner, path, buffer_pid, changeset_pid}, _from, state) do
    {result, state} = claim_path(state, path, buffer_pid, changeset_pid)
    {:reply, result, state}
  end

  def handle_call(
        {:transfer_to_changeset, path, expected_fork, changeset_pid},
        _from,
        state
      ) do
    case Map.get(state.claims, path) do
      {:fork, ^expected_fork} ->
        with {:ok, owner} <- available_owner({:changeset, changeset_pid}),
             :ok <- ensure_published(expected_fork) do
          state = stop_forks_for_paths(state, MapSet.new([path]))
          {:reply, :ok, %{state | claims: Map.put(state.claims, path, owner)}}
        else
          {:error, _reason} = error -> {:reply, error, state}
        end

      _other_owner ->
        {:reply, {:error, :owner_mismatch}, state}
    end
  end

  # credo:disable-for-next-line ExSlop.Check.Warning.GenserverAsKvStore
  def handle_call({:get, path}, _from, state) do
    {:reply, Map.get(state.forks, path), state}
  end

  def handle_call(:all, _from, state) do
    {:reply, state.forks, state}
  end

  def handle_call(:merge_all, _from, state) do
    merge_results(state)
  end

  def handle_call(:merge_all_keep_failed, _from, state) do
    merge_results(state)
  end

  def handle_call({:discard, path}, _from, state) do
    state = stop_forks_for_paths(state, MapSet.new([path]))
    {:reply, :ok, state}
  end

  def handle_call(:discard_all, _from, state) do
    stop_all_forks(state)
    {:reply, :ok, %{state | forks: %{}, claims: %{}, monitors: %{}}}
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

  @spec claim_path(state(), String.t(), pid() | nil, pid() | nil) ::
          {{:ok, owner()} | :not_found | {:error, term()}, state()}
  defp claim_path(state, path, buffer_pid, changeset_pid) do
    case Map.get(state.claims, path) do
      nil ->
        case Map.get(state.forks, path) do
          nil -> select_owner(state, path, buffer_pid, changeset_pid)
          fork -> retain_claim(state, path, {:fork, fork})
        end

      owner ->
        {available_owner(owner), state}
    end
  end

  @spec select_owner(state(), String.t(), pid() | nil, pid() | nil) ::
          {{:ok, owner()} | :not_found | {:error, term()}, state()}
  defp select_owner(state, path, buffer_pid, _changeset_pid) when is_pid(buffer_pid) do
    case create_fork(buffer_pid) do
      {:ok, fork_pid} ->
        ref = Process.monitor(fork_pid)

        state = %{
          state
          | forks: Map.put(state.forks, path, fork_pid),
            monitors: Map.put(state.monitors, ref, path)
        }

        retain_claim(state, path, {:fork, fork_pid})

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp select_owner(state, path, nil, changeset_pid) when is_pid(changeset_pid),
    do: retain_claim(state, path, {:changeset, changeset_pid})

  defp select_owner(state, _path, nil, nil), do: {:not_found, state}

  @spec retain_claim(state(), String.t(), owner()) :: {{:ok, owner()} | {:error, term()}, state()}
  defp retain_claim(state, path, owner) do
    case available_owner(owner) do
      {:ok, _owner} = result -> {result, %{state | claims: Map.put(state.claims, path, owner)}}
      {:error, _reason} = error -> {error, state}
    end
  end

  @spec available_owner(owner()) :: {:ok, owner()} | {:error, :owner_unavailable}
  defp available_owner({_kind, pid} = owner) do
    if Process.alive?(pid), do: {:ok, owner}, else: {:error, :owner_unavailable}
  end

  @spec create_fork(pid()) :: {:ok, pid()} | {:error, term()}
  defp create_fork(buffer_pid) do
    Fork.create(buffer_pid)
  catch
    :exit, reason -> {:error, {:fork_creation_failed, reason}}
  end

  @spec ensure_published(pid()) :: :ok | {:error, :fork_not_published | :owner_unavailable}
  defp ensure_published(fork) do
    if Fork.published?(fork), do: :ok, else: {:error, :fork_not_published}
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec merge_fork(String.t(), pid()) ::
          {String.t(), :ok | {:conflict, term()} | {:error, term()}}
  defp merge_fork(path, fork_pid) do
    case safe_fork_merge(fork_pid) do
      {:ok, _merged_text} ->
        {path, :ok}

      {:conflict, hunks} ->
        {path, {:conflict, hunks}}

      {:error, reason} ->
        {path, {:error, reason}}
    end
  end

  @spec safe_fork_merge(pid()) :: {:ok, String.t()} | {:conflict, term()} | {:error, term()}
  defp safe_fork_merge(fork_pid) do
    try do
      Fork.publish(fork_pid)
    catch
      :exit, reason -> {:error, {:fork_merge_failed, reason}}
    end
  end

  @spec merge_results(state()) :: {:reply, [tuple()], state()}
  defp merge_results(state) do
    results = Enum.map(state.forks, fn {path, fork_pid} -> merge_fork(path, fork_pid) end)
    successful_paths = successful_merge_paths(results)
    state = stop_forks_for_paths(state, successful_paths)
    {:reply, results, state}
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

  @spec stop_forks_for_paths(state(), MapSet.t(String.t())) :: state()
  defp stop_forks_for_paths(state, paths) do
    {refs_to_stop, monitors} =
      split_map_by_paths(state.monitors, paths, fn {_ref, path} -> path end)

    {forks_to_stop, forks} = split_map_by_paths(state.forks, paths, fn {path, _pid} -> path end)

    Enum.each(refs_to_stop, fn {ref, _path} -> Process.demonitor(ref, [:flush]) end)

    Enum.each(forks_to_stop, fn {_path, fork_pid} -> stop_fork(fork_pid) end)

    claims = Map.drop(state.claims, MapSet.to_list(paths))

    %{
      state
      | forks: Map.new(forks),
        claims: claims,
        monitors: Map.new(monitors)
    }
  end

  @spec stop_fork(pid()) :: :ok
  defp stop_fork(fork_pid) do
    GenServer.stop(fork_pid, :normal)
  catch
    :exit, _reason -> :ok
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
end
