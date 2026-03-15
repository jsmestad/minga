defmodule Minga.Git.Tracker do
  @moduledoc """
  Manages git buffer lifecycle by subscribing to the event bus.

  Listens for `:buffer_opened` and `:buffer_saved` events. When a file
  buffer is opened in a git repository, starts a `Git.Buffer` GenServer
  to track diffs. When a buffer is saved, invalidates the cached HEAD
  version so the diff reflects the new base.

  Maintains an ETS table (`Minga.Git.Tracker.Registry`) mapping buffer
  pids to git buffer pids. The renderer and git commands look up git
  buffer pids from this table instead of the Editor state.

  Monitors buffer pids so entries are cleaned up when buffers are killed.
  """

  use GenServer

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Git
  alias Minga.Git.Buffer, as: GitBuffer

  @registry_table __MODULE__.Registry

  # ── Client API ─────────────────────────────────────────────────────────

  @doc "Starts the git tracker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @doc """
  Looks up the git buffer pid for a buffer pid.

  Returns the git buffer pid or `nil` if the buffer has no git tracking.
  This is a direct ETS read with `:read_concurrency`, so it's safe to
  call from any process (including the renderer) without blocking.
  """
  @spec lookup(pid()) :: pid() | nil
  def lookup(buffer_pid) when is_pid(buffer_pid) do
    case :ets.lookup(@registry_table, buffer_pid) do
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
  def tracked?(buffer_pid) when is_pid(buffer_pid) do
    :ets.member(@registry_table, buffer_pid)
  rescue
    ArgumentError -> false
  end

  @doc """
  Notifies the git buffer that tracked content has changed.

  Reads the current buffer content and sends it to the `Git.Buffer` for
  diff recomputation. No-op if the buffer has no git tracking. Safe to
  call from any process.
  """
  @spec notify_change(term()) :: :ok
  def notify_change(buffer_pid) when not is_pid(buffer_pid) do
    Minga.Log.warning(
      :editor,
      "[Git.Tracker] notify_change called with non-pid: #{inspect(buffer_pid)}"
    )

    :ok
  end

  def notify_change(buffer_pid) when is_pid(buffer_pid) do
    case lookup(buffer_pid) do
      nil ->
        :ok

      git_pid ->
        if Process.alive?(git_pid) do
          {content, _cursor} = BufferServer.content_and_cursor(buffer_pid)
          GitBuffer.update(git_pid, content)
        end

        :ok
    end
  catch
    :exit, _ -> :ok
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, %{monitors: %{reference() => pid()}}}
  def init(_opts) do
    :ets.new(@registry_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    Minga.Events.subscribe(:buffer_opened)
    Minga.Events.subscribe(:buffer_saved)

    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_info(
        {:minga_event, :buffer_opened, %Minga.Events.BufferEvent{buffer: buf, path: path}},
        state
      )
      when is_pid(buf) do
    state = maybe_start_git_buffer(state, buf, path)
    {:noreply, state}
  end

  def handle_info(
        {:minga_event, :buffer_saved, %Minga.Events.BufferEvent{buffer: buf}},
        state
      )
      when is_pid(buf) do
    invalidate_on_save(buf)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {buffer_pid, monitors} ->
        :ets.delete(@registry_table, buffer_pid)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ────────────────────────────────────────────────────────────

  @spec maybe_start_git_buffer(map(), pid(), String.t()) :: map()
  defp maybe_start_git_buffer(state, buffer_pid, path) do
    with {:ok, git_root} <- Git.root_for(path),
         {content, _cursor} <- BufferServer.content_and_cursor(buffer_pid),
         {:ok, git_pid} <-
           DynamicSupervisor.start_child(
             Minga.Buffer.Supervisor,
             {GitBuffer, git_root: git_root, file_path: path, initial_content: content}
           ) do
      :ets.insert(@registry_table, {buffer_pid, git_pid})
      ref = Process.monitor(buffer_pid)
      rel_path = Path.relative_to(path, git_root)
      Minga.Editor.log_to_messages("Git: tracking #{rel_path}")
      %{state | monitors: Map.put(state.monitors, ref, buffer_pid)}
    else
      _ -> state
    end
  catch
    :exit, _ -> state
  end

  @spec invalidate_on_save(pid()) :: :ok
  defp invalidate_on_save(buf) do
    case lookup(buf) do
      nil ->
        :ok

      git_pid ->
        if Process.alive?(git_pid) do
          {content, _cursor} = BufferServer.content_and_cursor(buf)
          GitBuffer.invalidate_base(git_pid, content)
        end

        :ok
    end
  catch
    :exit, _ -> :ok
  end
end
