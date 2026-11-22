defmodule Minga.Git.Tracker do
  @moduledoc """
  Manages git buffer lifecycle by subscribing to the event bus.

  Starts a `Git.Buffer` for a file in a repository and replaces the
  binding when the buffer adopts a different path or reloads a different
  target through the same alias. A save at the same target invalidates
  the cached HEAD version.

  Maintains an ETS table (`Minga.Git.Tracker.Registry`) mapping buffer
  pids to git buffer pids. The renderer and git commands look up git
  buffer pids from this table instead of the Editor state.

  Monitors source buffers and retires their bindings when they close.
  """

  use GenServer

  alias Minga.Buffer
  alias Minga.Events
  alias Minga.Git
  alias Minga.Git.Buffer, as: GitBuffer

  @registry_table __MODULE__.Registry

  # ── Client API ─────────────────────────────────────────────────────────

  @doc "Starts the git tracker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Looks up the git buffer pid for a buffer pid.

  Returns the git buffer pid or `nil` if the buffer has no git tracking.
  This is a direct ETS read with `:read_concurrency`, so it's safe to
  call from any process (including the renderer) without blocking.
  """
  @spec lookup(pid()) :: pid() | nil
  @spec lookup(pid(), atom()) :: pid() | nil
  def lookup(buffer_pid, registry_table \\ @registry_table) when is_pid(buffer_pid) do
    case :ets.lookup(registry_table, buffer_pid) do
      [{^buffer_pid, git_pid}] -> git_pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Returns true if the buffer has a git buffer registered.

  Same direct ETS read as `lookup/1`.
  """
  @spec tracked?(pid()) :: boolean()
  @spec tracked?(pid(), atom()) :: boolean()
  def tracked?(buffer_pid, registry_table \\ @registry_table) when is_pid(buffer_pid) do
    :ets.member(registry_table, buffer_pid)
  rescue
    ArgumentError -> false
  end

  @doc "Registers a buffer-to-git-buffer mapping directly in the registry."
  @spec put_mapping(pid(), pid(), atom()) :: true
  def put_mapping(buffer_pid, git_pid, registry_table \\ @registry_table)
      when is_pid(buffer_pid) and is_pid(git_pid) do
    if :ets.whereis(registry_table) == :undefined do
      :ets.new(registry_table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ets.insert(registry_table, {buffer_pid, git_pid})
  end

  @doc "Removes a buffer mapping from the registry."
  @spec remove_mapping(pid(), atom()) :: true
  def remove_mapping(buffer_pid, registry_table \\ @registry_table) when is_pid(buffer_pid) do
    :ets.delete(registry_table, buffer_pid)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @typep binding :: %{
           path: String.t(),
           canonical_target: String.t(),
           git_root: String.t(),
           git_pid: pid(),
           monitor: reference()
         }

  @typep tracker_state :: %{
           bindings: %{pid() => binding()},
           repo_buffer_counts: %{String.t() => pos_integer()},
           events_registry: Events.registry(),
           registry_table: atom()
         }

  @impl true
  @spec init(keyword()) :: {:ok, tracker_state()}
  def init(opts) do
    events_registry = Keyword.get(opts, :events_registry, Events.default_registry())
    registry_table = Keyword.get(opts, :registry_table, @registry_table)

    :ets.new(registry_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    Events.subscribe(:buffer_opened, events_registry)
    Events.subscribe(:buffer_saved, events_registry)
    Events.subscribe(:buffer_path_changed, events_registry)
    Events.subscribe(:buffer_changed, events_registry)
    Events.subscribe(:content_replaced, events_registry)

    {:ok,
     %{
       bindings: %{},
       repo_buffer_counts: %{},
       events_registry: events_registry,
       registry_table: registry_table
     }}
  end

  @impl true
  @spec handle_info(term(), tracker_state()) :: {:noreply, tracker_state()}
  def handle_info(
        {:minga_event, :buffer_changed, %Events.BufferChangedEvent{buffer: buf}},
        state
      )
      when is_pid(buf) do
    do_notify_change(buf, state.registry_table)
    {:noreply, state}
  end

  def handle_info({:minga_event, topic, %Events.BufferEvent{buffer: buf}}, state)
      when topic in [:buffer_opened, :buffer_path_changed, :content_replaced] and is_pid(buf) do
    {:noreply, sync_tracking(state, buf, current_path(buf))}
  end

  def handle_info({:minga_event, :buffer_saved, %Events.BufferEvent{buffer: buf}}, state)
      when is_pid(buf) do
    # The saved path may be an alias or a path the buffer just adopted.
    # Only refresh the HEAD cache for the currently bound path.
    with %{^buf => %{path: path, canonical_target: target, git_pid: git_pid}} <- state.bindings,
         ^target <- GitBuffer.canonical_target(path),
         {:ok, content} <- content_at_path(buf, path) do
      GitBuffer.invalidate_base(git_pid, content)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, buf, _reason}, state) do
    case state.bindings do
      %{^buf => %{monitor: ^ref} = binding} ->
        state = unregister_binding(state, buf)
        {:noreply, release_binding(state, binding)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ────────────────────────────────────────────────────────────

  @spec do_notify_change(pid(), atom()) :: :ok
  defp do_notify_change(buffer_pid, registry_table) do
    case lookup(buffer_pid, registry_table) do
      nil ->
        :ok

      git_pid ->
        {content, _cursor} = Buffer.content_and_cursor(buffer_pid)
        GitBuffer.update(git_pid, content)
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  @spec current_path(pid()) :: String.t() | nil
  defp current_path(buffer_pid) do
    Buffer.file_path(buffer_pid)
  catch
    :exit, _ -> nil
  end

  @spec content_at_path(pid(), String.t()) :: {:ok, binary()} | :unavailable
  defp content_at_path(buffer_pid, path) do
    case Buffer.file_observation(buffer_pid) do
      {^path, content, _cursor, _version} -> {:ok, content}
      _ -> :unavailable
    end
  catch
    :exit, _ -> :unavailable
  end

  @spec sync_tracking(tracker_state(), pid(), String.t() | nil) :: tracker_state()
  defp sync_tracking(state, _buffer_pid, nil), do: state

  defp sync_tracking(state, buffer_pid, path) do
    target = GitBuffer.canonical_target(path)

    case Map.get(state.bindings, buffer_pid) do
      %{path: ^path, canonical_target: ^target, git_pid: git_pid} ->
        with {:ok, content} <- content_at_path(buffer_pid, path) do
          GitBuffer.update(git_pid, content)
        end

        state

      nil ->
        maybe_start_git_buffer(state, buffer_pid, path, target)

      previous ->
        state = unregister_binding(state, buffer_pid)
        state = maybe_start_git_buffer(state, buffer_pid, path, target)
        # Count a same-repo replacement before retiring its predecessor.
        release_binding(state, previous)
    end
  end

  @spec maybe_start_git_buffer(tracker_state(), pid(), String.t(), String.t() | nil) ::
          tracker_state()
  defp maybe_start_git_buffer(state, _buffer_pid, _path, nil), do: state

  defp maybe_start_git_buffer(state, buffer_pid, path, target) do
    with {:ok, git_root} <- Git.root_for(target),
         {:ok, content} <- content_at_path(buffer_pid, path),
         {:ok, git_pid} <-
           DynamicSupervisor.start_child(
             Minga.Buffer.Supervisor,
             {GitBuffer,
              git_root: git_root,
              file_path: path,
              canonical_target: target,
              initial_content: content}
           ) do
      ensure_repo(git_root, state.events_registry)
      :ets.insert(state.registry_table, {buffer_pid, git_pid})

      Events.broadcast(
        :log_message,
        %Events.LogMessageEvent{
          text: "Git: tracking #{Path.relative_to(target, git_root)}",
          level: :info
        },
        state.events_registry
      )

      binding = %{
        path: path,
        canonical_target: target,
        git_root: git_root,
        git_pid: git_pid,
        monitor: Process.monitor(buffer_pid)
      }

      %{
        state
        | bindings: Map.put(state.bindings, buffer_pid, binding),
          repo_buffer_counts: Map.update(state.repo_buffer_counts, git_root, 1, &(&1 + 1))
      }
    else
      _ -> state
    end
  end

  @spec unregister_binding(tracker_state(), pid()) :: tracker_state()
  defp unregister_binding(state, buffer_pid) do
    :ets.delete(state.registry_table, buffer_pid)
    %{state | bindings: Map.delete(state.bindings, buffer_pid)}
  end

  @spec release_binding(tracker_state(), binding()) :: tracker_state()
  defp release_binding(state, binding) do
    Process.demonitor(binding.monitor, [:flush])
    DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, binding.git_pid)

    %{
      state
      | repo_buffer_counts: decrement_repo_count(state.repo_buffer_counts, binding.git_root)
    }
  end

  @spec ensure_repo(String.t(), Events.registry()) :: :ok
  defp ensure_repo(git_root, events_registry) do
    project_root =
      try do
        Minga.Project.root()
      catch
        :exit, _ -> nil
      end

    case Git.Repo.ensure_started(git_root, project_root, events_registry) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(
          :editor,
          "[Git.Tracker] failed to start Git.Repo for #{git_root}: #{inspect(reason)}"
        )

        :ok
    end
  end

  @spec decrement_repo_count(%{String.t() => pos_integer()}, String.t()) :: %{
          String.t() => pos_integer()
        }
  defp decrement_repo_count(counts, git_root) do
    case Map.fetch!(counts, git_root) do
      1 ->
        # Last buffer for this repo closed; stop Git.Repo
        stop_repo(git_root)
        Map.delete(counts, git_root)

      n ->
        Map.put(counts, git_root, n - 1)
    end
  end

  @spec stop_repo(String.t()) :: :ok
  defp stop_repo(git_root) do
    case Git.Repo.lookup(git_root) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(Minga.Git.Repo.Supervisor, pid)
        :ok
    end
  catch
    :exit, _ -> :ok
  end
end
