defmodule Minga.Session.EventRecorder do
  @moduledoc """
  Persistent event recorder for the editor's event stream.

  Subscribes to `Minga.Events` topics and writes every event to an
  append-only SQLite database via exqlite. The recorder is a write-only
  GenServer: it receives events via cast (never blocking the broadcaster)
  and writes them to the database synchronously within its own process.

  Downstream features query the database through `Minga.Session.EventRecorder.Store`
  using separate read connections, which WAL mode supports without blocking
  the writer.

  ## Retention

  A periodic sweep deletes events older than the configured retention
  window (default: 7 days). The sweep runs once per hour.

  ## Supervision

  Lives in `Services.Independent` under `one_for_one`. A crash restarts
  only the recorder, which re-subscribes to Events and reconnects to
  SQLite in `init/1`.
  """

  use GenServer

  alias Minga.Events
  alias Minga.Session.EventRecorder.EventRecord
  alias Minga.Session.EventRecorder.Store

  @default_db_dir Path.expand("~/.local/share/minga")
  @db_filename "events.db"
  @retention_sweep_interval_ms :timer.hours(1)

  @subscribed_topics [
    :buffer_saved,
    :buffer_opened,
    :buffer_closed,
    :buffer_changed,
    :mode_changed,
    :git_status_changed,
    :project_rebuilt,
    :command_done
  ]

  # ── State ─────────────────────────────────────────────────────────────

  defmodule State do
    @moduledoc false
    @enforce_keys [:db]
    defstruct [:db, :retention_days, :sweep_ref]

    @type t :: %__MODULE__{
            db: Exqlite.Sqlite3.db(),
            retention_days: pos_integer(),
            sweep_ref: reference() | nil
          }
  end

  # ── Client API ────────────────────────────────────────────────────────

  @doc "Starts the event recorder."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the database path for the given options.

  Used by downstream features to open read connections.
  """
  @spec db_path(keyword()) :: String.t()
  def db_path(opts \\ []) do
    dir = Keyword.get(opts, :db_dir, @default_db_dir)
    Path.join(dir, @db_filename)
  end

  @doc """
  Opens a read-only connection to the event database.

  Downstream features use this to query events without going through
  the recorder GenServer. WAL mode allows concurrent reads.
  """
  @spec open_read_connection(keyword()) :: {:ok, Store.db()} | {:error, term()}
  def open_read_connection(opts \\ []) do
    path = db_path(opts)

    if File.exists?(path) do
      Store.open(path)
    else
      {:error, :database_not_found}
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, State.t()} | {:stop, term()}
  def init(opts) do
    db_dir = Keyword.get(opts, :db_dir, @default_db_dir)

    retention_days =
      Keyword.get_lazy(opts, :retention_days, fn ->
        Minga.Config.Options.get(:event_retention_days)
      end)

    path = Path.join(db_dir, @db_filename)

    case open_or_recreate(path) do
      {:ok, db} ->
        if Keyword.get(opts, :subscribe, true), do: subscribe_to_events()
        sweep_ref = schedule_retention_sweep()

        Minga.Log.info(:editor, "[EventRecorder] started, logging to #{path}")

        {:ok,
         %State{
           db: db,
           retention_days: retention_days,
           sweep_ref: sweep_ref
         }}

      {:error, reason} ->
        Minga.Log.warning(:editor, "[EventRecorder] failed to open database: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:minga_event, topic, payload}, state) do
    record = build_record(topic, payload)

    case Store.insert(state.db, record) do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(
          :editor,
          "[EventRecorder] failed to write event: #{inspect(reason)}"
        )
    end

    {:noreply, state}
  end

  def handle_info(:retention_sweep, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -state.retention_days, :day)

    case Store.delete_before(state.db, cutoff) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Minga.Log.info(:editor, "[EventRecorder] retention sweep deleted #{count} events")

      {:error, reason} ->
        Minga.Log.warning(
          :editor,
          "[EventRecorder] retention sweep failed: #{inspect(reason)}"
        )
    end

    sweep_ref = schedule_retention_sweep()
    {:noreply, %{state | sweep_ref: sweep_ref}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Store.close(state.db)
    :ok
  end

  # ── Private helpers ───────────────────────────────────────────────────

  @spec subscribe_to_events() :: :ok
  defp subscribe_to_events do
    Enum.each(@subscribed_topics, &Events.subscribe/1)
  end

  @spec schedule_retention_sweep() :: reference()
  defp schedule_retention_sweep do
    Process.send_after(self(), :retention_sweep, @retention_sweep_interval_ms)
  end

  @spec open_or_recreate(String.t()) :: {:ok, Store.db()} | {:error, term()}
  defp open_or_recreate(path) do
    case Store.open(path) do
      {:ok, db} ->
        case Store.integrity_check(db) do
          {:ok, :healthy} ->
            {:ok, db}

          {:error, messages} ->
            Minga.Log.warning(
              :editor,
              "[EventRecorder] database corrupt: #{inspect(messages)}, recreating"
            )

            Store.close(db)
            recreate(path)
        end

      {:error, reason} when is_binary(path) ->
        # The file exists but can't be opened (e.g., garbage data that
        # isn't a valid SQLite header). Delete and try fresh.
        if File.exists?(path) do
          Minga.Log.warning(
            :editor,
            "[EventRecorder] database unreadable: #{inspect(reason)}, recreating"
          )

          recreate(path)
        else
          {:error, reason}
        end
    end
  end

  @spec recreate(String.t()) :: {:ok, Store.db()} | {:error, term()}
  defp recreate(path) do
    File.rm(path)
    File.rm(path <> "-wal")
    File.rm(path <> "-shm")
    Store.open(path)
  end

  @spec build_record(Events.topic(), Events.payload()) :: EventRecord.t()
  defp build_record(topic, payload) do
    now_mono = System.monotonic_time(:microsecond)
    now_wall = DateTime.utc_now()

    {source, scope, extra} = extract_event_data(topic, payload)

    %EventRecord{
      timestamp: now_mono,
      wall_clock: now_wall,
      source: source,
      scope: scope,
      event_type: topic,
      payload: extra
    }
  end

  @spec extract_event_data(Events.topic(), Events.payload()) ::
          {String.t(), EventRecord.scope(), map()}
  defp extract_event_data(:buffer_saved, %Events.BufferEvent{path: path}) do
    {"user", {:buffer, path}, %{"path" => path}}
  end

  defp extract_event_data(:buffer_opened, %Events.BufferEvent{path: path}) do
    {"user", {:buffer, path}, %{"path" => path}}
  end

  defp extract_event_data(:buffer_closed, %Events.BufferClosedEvent{path: path}) do
    path_str = if is_binary(path), do: path, else: inspect(path)
    {"user", {:buffer, path_str}, %{"path" => path_str}}
  end

  defp extract_event_data(:buffer_changed, %Events.BufferChangedEvent{
         buffer: buffer,
         source: source
       }) do
    source_str = EventRecord.encode_source(source)
    # Scope is the buffer, but we don't have the path readily here.
    # Use the pid as a string identifier for now; downstream features
    # that need the path can join with buffer_opened events.
    scope = {:buffer, inspect(buffer)}
    {source_str, scope, %{}}
  end

  defp extract_event_data(:mode_changed, %Events.ModeEvent{old: old, new: new}) do
    {"user", :global, %{"old" => Atom.to_string(old), "new" => Atom.to_string(new)}}
  end

  defp extract_event_data(:git_status_changed, %Events.GitStatusEvent{
         git_root: root,
         branch: branch
       }) do
    {"system", :global, %{"git_root" => root, "branch" => branch}}
  end

  defp extract_event_data(:project_rebuilt, %Events.ProjectRebuiltEvent{root: root}) do
    {"system", :global, %{"root" => root}}
  end

  defp extract_event_data(:command_done, %Events.CommandDoneEvent{
         name: name,
         exit_code: exit_code
       }) do
    {"system", :global, %{"command" => name, "exit_code" => exit_code}}
  end

  defp extract_event_data(topic, _payload) do
    {"unknown", :global, %{"topic" => Atom.to_string(topic)}}
  end
end
