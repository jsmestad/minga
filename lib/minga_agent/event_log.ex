defmodule MingaAgent.EventLog do
  @moduledoc """
  Durable append-only event log for agent sessions.

  Agent sessions call `record/3`, which is a cast to this writer process, so session execution never waits on SQLite I/O. Readers open their own connections through `open_read_connection/1` and query by cursor with `events_after/4`; WAL mode lets those reads proceed without blocking the writer.
  """

  use GenServer

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Store

  @default_db_dir Path.expand("~/.local/share/minga")
  @db_filename "agent_events.db"
  @retention_sweep_interval_ms :timer.hours(1)
  @initial_retention_sweep_delay_ms :timer.seconds(5)
  @health_check_delay_ms :timer.seconds(10)
  @default_health_check :quick

  defmodule State do
    @moduledoc false
    @enforce_keys [:db, :path, :retention_days]
    defstruct [:db, :path, :retention_days, :sweep_ref]

    @type t :: %__MODULE__{
            db: Store.db(),
            path: String.t(),
            retention_days: pos_integer(),
            sweep_ref: reference() | nil
          }
  end

  @doc "Starts the event log writer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the configured event-log database path."
  @spec db_path(keyword()) :: String.t()
  def db_path(opts \\ []) do
    dir = Keyword.get(opts, :db_dir, @default_db_dir)
    Path.join(dir, @db_filename)
  end

  @doc "Opens a read connection to the agent event database."
  @spec open_read_connection(keyword()) :: {:ok, Store.db()} | {:error, term()}
  def open_read_connection(opts \\ []) do
    path = db_path(opts)

    if File.exists?(path) do
      Store.open(path)
    else
      {:error, :database_not_found}
    end
  end

  @doc "Records an agent event asynchronously."
  @spec record(String.t(), EventRecord.event_type(), map(), GenServer.server()) :: :ok
  def record(session_id, event_type, payload \\ %{}, server \\ __MODULE__)
      when is_binary(session_id) and is_atom(event_type) and is_map(payload) do
    GenServer.cast(server, {:record, session_id, event_type, sanitize_payload(payload)})
  catch
    :exit, _ -> :ok
  end

  @doc "Queries events for a session after the given cursor."
  @spec events_after(Store.db(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  defdelegate events_after(db, session_id, last_id, limit \\ 1000), to: Store

  @impl true
  @spec init(keyword()) :: {:ok, State.t()} | {:stop, term()}
  def init(opts) do
    path = db_path(opts)

    retention_days =
      Keyword.get_lazy(opts, :retention_days, fn -> Minga.Config.get(:event_retention_days) end)

    case open_or_recreate(path) do
      {:ok, db} ->
        sweep_ref = schedule_initial_retention_sweep(opts)
        schedule_health_check(Keyword.get(opts, :health_check, @default_health_check), opts)
        Minga.Log.info(:agent, "[AgentEventLog] started, logging to #{path}")
        {:ok, %State{db: db, path: path, retention_days: retention_days, sweep_ref: sweep_ref}}

      {:error, reason} ->
        Minga.Log.warning(:agent, "[AgentEventLog] failed to open database: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:record, session_id, event_type, payload}, state) do
    record = EventRecord.new(session_id, event_type, payload)

    case Store.insert(state.db, record) do
      {:ok, _id} ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(:agent, "[AgentEventLog] failed to write event: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:retention_sweep, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -state.retention_days, :day)

    case Store.delete_before(state.db, cutoff) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Minga.Log.info(:agent, "[AgentEventLog] retention sweep deleted #{count} events")

      {:error, reason} ->
        Minga.Log.warning(:agent, "[AgentEventLog] retention sweep failed: #{inspect(reason)}")
    end

    {:noreply, %{state | sweep_ref: schedule_retention_sweep()}}
  end

  def handle_info({:health_check_result, result}, state) do
    handle_health_check_result(result, state)
  end

  def handle_info({:run_health_check, parent, path, mode}, state) do
    Task.start(fn -> send(parent, {:health_check_result, run_health_check(path, mode)}) end)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Store.close(state.db)
    :ok
  end

  @spec open_or_recreate(String.t()) :: {:ok, Store.db()} | {:error, term()}
  defp open_or_recreate(path) do
    case Store.open(path) do
      {:ok, db} ->
        {:ok, db}

      {:error, reason} ->
        if File.exists?(path) and corrupt?(path) do
          Minga.Log.warning(
            :agent,
            "[AgentEventLog] corrupt database, recreating: #{inspect(reason)}"
          )

          recreate_database(path)
        else
          {:error, reason}
        end
    end
  end

  @spec corrupt?(String.t()) :: boolean()
  defp corrupt?(path) do
    case Exqlite.Sqlite3.open(path) do
      {:ok, db} ->
        result = Store.integrity_check(db, :quick)
        Store.close(db)
        match?({:error, _}, result)

      {:error, _} ->
        false
    end
  end

  @spec recreate_database(String.t()) :: {:ok, Store.db()} | {:error, term()}
  defp recreate_database(path) do
    _ = File.rm(path)
    _ = File.rm(path <> "-wal")
    _ = File.rm(path <> "-shm")
    Store.open(path)
  end

  @spec schedule_initial_retention_sweep(keyword()) :: reference() | nil
  defp schedule_initial_retention_sweep(opts) do
    if Keyword.get(opts, :retention_sweep?, true) do
      Process.send_after(self(), :retention_sweep, @initial_retention_sweep_delay_ms)
    end
  end

  @spec schedule_retention_sweep() :: reference()
  defp schedule_retention_sweep do
    Process.send_after(self(), :retention_sweep, @retention_sweep_interval_ms)
  end

  @spec schedule_health_check(:none | :quick | :full, keyword()) :: :ok
  defp schedule_health_check(:none, _opts), do: :ok

  defp schedule_health_check(mode, opts) when mode in [:quick, :full] do
    parent = self()
    path = db_path(opts)

    Process.send_after(
      self(),
      {:run_health_check, parent, path, mode},
      Keyword.get(opts, :health_check_delay_ms, @health_check_delay_ms)
    )

    :ok
  end

  @spec run_health_check(String.t(), :quick | :full) :: :ok | {:error, term()}
  defp run_health_check(path, mode) do
    with {:ok, db} <- Store.open(path),
         result <- Store.integrity_check(db, mode),
         :ok <- Store.close(db) do
      case result do
        {:ok, :healthy} -> :ok
        {:error, messages} -> {:error, {:corrupt, messages}}
      end
    end
  end

  @spec handle_health_check_result(:ok | {:error, term()}, State.t()) :: {:noreply, State.t()}
  defp handle_health_check_result(:ok, state), do: {:noreply, state}

  defp handle_health_check_result({:error, reason}, state) do
    Minga.Log.warning(:agent, "[AgentEventLog] health check failed: #{inspect(reason)}")
    {:noreply, state}
  end

  @secret_keys MapSet.new(
                 ~w(api_key apikey token access_token refresh_token secret password credential credentials authorization remote_token)
               )

  @spec sanitize_payload(term()) :: term()
  defp sanitize_payload(%_{} = struct), do: sanitize_payload(Map.from_struct(struct))

  defp sanitize_payload(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      string_key = to_string(key)
      sanitized = if secret_key?(string_key), do: "[REDACTED]", else: sanitize_payload(value)
      {string_key, sanitized}
    end)
  end

  defp sanitize_payload(list) when is_list(list), do: Enum.map(list, &sanitize_payload/1)
  defp sanitize_payload(pid) when is_pid(pid), do: "[PID]"
  defp sanitize_payload(ref) when is_reference(ref), do: "[REFERENCE]"
  defp sanitize_payload(boolean) when is_boolean(boolean), do: boolean
  defp sanitize_payload(nil), do: nil
  defp sanitize_payload(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp sanitize_payload(binary) when is_binary(binary), do: binary
  defp sanitize_payload(number) when is_number(number), do: number
  defp sanitize_payload(other), do: inspect(other)

  @spec secret_key?(String.t()) :: boolean()
  defp secret_key?(key) do
    normalized = normalize_secret_key(key)

    MapSet.member?(@secret_keys, normalized) or
      String.ends_with?(normalized, "_token") or
      String.ends_with?(normalized, "_secret") or
      String.contains?(normalized, "api_key") or
      String.contains?(normalized, "password") or
      String.contains?(normalized, "credential") or
      String.contains?(normalized, "authorization")
  end

  @spec normalize_secret_key(String.t()) :: String.t()
  defp normalize_secret_key(key) do
    key
    |> Macro.underscore()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
