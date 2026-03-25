defmodule Minga.Session.EventRecorder.Store do
  @moduledoc """
  SQLite storage backend for the event recording system.

  Wraps an exqlite connection with prepared statements for event
  persistence and querying. The database uses WAL mode for concurrent
  read access: the recorder holds the write connection, and downstream
  features can open separate read connections without blocking writes.

  Schema evolution uses a simple version table checked at startup.
  No Ecto, no migration framework.
  """

  alias Minga.Session.EventRecorder.EventRecord

  @type db :: Exqlite.Sqlite3.db()

  @schema_version 1

  # ── Connection lifecycle ──────────────────────────────────────────────

  @doc """
  Opens (or creates) the event database at the given path.

  Enables WAL mode and creates tables if they don't exist. Returns the
  raw exqlite connection handle.
  """
  @spec open(String.t()) :: {:ok, db()} | {:error, term()}
  def open(db_path) do
    File.mkdir_p!(Path.dirname(db_path))

    case Exqlite.Sqlite3.open(db_path) do
      {:ok, db} ->
        case setup(db) do
          :ok -> {:ok, db}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Opens an in-memory database for testing.
  """
  @spec open_memory() :: {:ok, db()} | {:error, term()}
  def open_memory do
    case Exqlite.Sqlite3.open(":memory:") do
      {:ok, db} ->
        case setup(db) do
          :ok -> {:ok, db}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Closes the database connection.
  """
  @spec close(db()) :: :ok | {:error, term()}
  def close(db) do
    Exqlite.Sqlite3.close(db)
  end

  # ── Write operations ──────────────────────────────────────────────────

  @doc """
  Inserts a single event record into the database.

  The payload map is serialized to JSON. Returns `:ok` on success.
  """
  @spec insert(db(), EventRecord.t()) :: :ok | {:error, term()}
  def insert(db, %EventRecord{} = record) do
    sql = """
    INSERT INTO events (timestamp, wall_clock, source, scope, event_type, payload)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    """

    wall_clock_iso = DateTime.to_iso8601(record.wall_clock)
    event_type_str = Atom.to_string(record.event_type)
    scope_str = EventRecord.encode_scope(record.scope)
    payload_json = encode_json(record.payload)

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <-
           Exqlite.Sqlite3.bind(stmt, [
             record.timestamp,
             wall_clock_iso,
             record.source,
             scope_str,
             event_type_str,
             payload_json
           ]),
         :done <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Query operations ──────────────────────────────────────────────────

  @doc """
  Queries events within a time range (wall clock, ISO 8601 strings).

  Options:
  - `:event_type` - filter by event type atom
  - `:source` - filter by source string (exact match)
  - `:scope` - filter by scope string (exact match)
  - `:limit` - max results (default 1000)
  - `:order` - `:asc` or `:desc` (default `:asc`)
  """
  @spec events_in_range(db(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  def events_in_range(db, from, to, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)
    order = if Keyword.get(opts, :order, :asc) == :desc, do: "DESC", else: "ASC"
    event_type = Keyword.get(opts, :event_type)
    source = Keyword.get(opts, :source)
    scope = Keyword.get(opts, :scope)

    {where_clauses, params} =
      build_filters(
        [
          {"wall_clock >= ?", DateTime.to_iso8601(from)},
          {"wall_clock <= ?", DateTime.to_iso8601(to)}
        ],
        event_type: event_type,
        source: source,
        scope: scope
      )

    sql = """
    SELECT id, timestamp, wall_clock, source, scope, event_type, payload
    FROM events
    WHERE #{Enum.join(where_clauses, " AND ")}
    ORDER BY wall_clock #{order}
    LIMIT ?
    """

    params = params ++ [limit]
    query_events(db, sql, params)
  end

  @doc """
  Queries all events for a specific source (e.g., agent session).
  """
  @spec events_by_source(db(), String.t(), keyword()) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  def events_by_source(db, source, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)
    order = if Keyword.get(opts, :order, :asc) == :desc, do: "DESC", else: "ASC"

    sql = """
    SELECT id, timestamp, wall_clock, source, scope, event_type, payload
    FROM events
    WHERE source = ?1
    ORDER BY wall_clock #{order}
    LIMIT ?2
    """

    query_events(db, sql, [source, limit])
  end

  @doc """
  Queries all events for a specific scope (e.g., a buffer path).
  """
  @spec events_by_scope(db(), String.t(), keyword()) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  def events_by_scope(db, scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)
    order = if Keyword.get(opts, :order, :asc) == :desc, do: "DESC", else: "ASC"

    sql = """
    SELECT id, timestamp, wall_clock, source, scope, event_type, payload
    FROM events
    WHERE scope = ?1
    ORDER BY wall_clock #{order}
    LIMIT ?2
    """

    query_events(db, sql, [scope, limit])
  end

  @doc """
  Queries events by type.
  """
  @spec events_by_type(db(), atom(), keyword()) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  def events_by_type(db, event_type, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)
    order = if Keyword.get(opts, :order, :asc) == :desc, do: "DESC", else: "ASC"

    sql = """
    SELECT id, timestamp, wall_clock, source, scope, event_type, payload
    FROM events
    WHERE event_type = ?1
    ORDER BY wall_clock #{order}
    LIMIT ?2
    """

    query_events(db, sql, [Atom.to_string(event_type), limit])
  end

  @doc """
  Returns the total number of events in the database.
  """
  @spec count(db()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(db) do
    sql = "SELECT COUNT(*) FROM events"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         {:row, [count]} <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      {:ok, count}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Retention ─────────────────────────────────────────────────────────

  @doc """
  Deletes events older than the given DateTime.

  Returns the number of deleted rows.
  """
  @spec delete_before(db(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_before(db, cutoff) do
    sql = "DELETE FROM events WHERE wall_clock < ?1"
    cutoff_iso = DateTime.to_iso8601(cutoff)

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [cutoff_iso]),
         :done <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      {:ok, changes(db)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs `PRAGMA integrity_check` and returns the result.

  Returns `{:ok, :healthy}` if the database is intact, or
  `{:error, messages}` with the integrity check output.
  """
  @spec integrity_check(db()) :: {:ok, :healthy} | {:error, [String.t()]}
  def integrity_check(db) do
    sql = "PRAGMA integrity_check"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql) do
      results = collect_rows(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)

      case results do
        [["ok"]] -> {:ok, :healthy}
        rows -> {:error, List.flatten(rows)}
      end
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────

  @spec setup(db()) :: :ok | {:error, term()}
  defp setup(db) do
    pragmas = [
      "PRAGMA journal_mode=WAL",
      "PRAGMA synchronous=NORMAL",
      "PRAGMA cache_size=-8000",
      "PRAGMA foreign_keys=ON"
    ]

    create_sql = """
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp INTEGER NOT NULL,
      wall_clock TEXT NOT NULL,
      source TEXT NOT NULL,
      scope TEXT NOT NULL,
      event_type TEXT NOT NULL,
      payload TEXT NOT NULL DEFAULT '{}'
    )
    """

    indexes = [
      "CREATE INDEX IF NOT EXISTS idx_events_wall_clock ON events(wall_clock)",
      "CREATE INDEX IF NOT EXISTS idx_events_event_type ON events(event_type)",
      "CREATE INDEX IF NOT EXISTS idx_events_source ON events(source)",
      "CREATE INDEX IF NOT EXISTS idx_events_scope ON events(scope)"
    ]

    version_sql = """
    CREATE TABLE IF NOT EXISTS schema_version (
      version INTEGER NOT NULL
    )
    """

    statements = pragmas ++ [create_sql] ++ indexes ++ [version_sql]

    result =
      Enum.reduce_while(statements, :ok, fn sql, :ok ->
        case execute(db, sql) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok -> ensure_schema_version(db)
      error -> error
    end
  end

  @spec ensure_schema_version(db()) :: :ok | {:error, term()}
  defp ensure_schema_version(db) do
    sql = "SELECT version FROM schema_version LIMIT 1"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql) do
      result = Exqlite.Sqlite3.step(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)

      case result do
        :done ->
          # No version row yet, insert the current version
          execute(db, "INSERT INTO schema_version (version) VALUES (#{@schema_version})")

        {:row, [@schema_version]} ->
          :ok

        {:row, [_old_version]} ->
          # Future: run migrations here
          :ok
      end
    end
  end

  @spec execute(db(), String.t()) :: :ok | {:error, term()}
  defp execute(db, sql) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :done <- step_until_done(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec step_until_done(db(), Exqlite.Sqlite3.statement()) :: :done | {:error, term()}
  defp step_until_done(db, stmt) do
    case Exqlite.Sqlite3.step(db, stmt) do
      :done -> :done
      {:row, _} -> step_until_done(db, stmt)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec query_events(db(), String.t(), [term()]) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  defp query_events(db, sql, params) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, params) do
      rows = collect_rows(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)
      {:ok, Enum.map(rows, &row_to_record/1)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec collect_rows(db(), Exqlite.Sqlite3.statement()) :: [list()]
  defp collect_rows(db, stmt) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> [row | collect_rows(db, stmt)]
      :done -> []
    end
  end

  @spec row_to_record([term()]) :: EventRecord.t()
  defp row_to_record([id, timestamp, wall_clock_iso, source, scope, event_type, payload_json]) do
    {:ok, wall_clock, _offset} = DateTime.from_iso8601(wall_clock_iso)
    payload = decode_json(payload_json)

    %EventRecord{
      id: id,
      timestamp: timestamp,
      wall_clock: wall_clock,
      source: source,
      scope: EventRecord.decode_scope(scope),
      event_type: String.to_existing_atom(event_type),
      payload: payload
    }
  end

  @spec build_filters([{String.t(), term()}], keyword()) :: {[String.t()], [term()]}
  defp build_filters(base_filters, opts) do
    extra =
      Enum.flat_map(opts, fn
        {:event_type, nil} -> []
        {:event_type, val} -> [{"event_type = ?", Atom.to_string(val)}]
        {:source, nil} -> []
        {:source, val} -> [{"source = ?", val}]
        {:scope, nil} -> []
        {:scope, val} -> [{"scope = ?", val}]
      end)

    all = base_filters ++ extra

    {clauses, params} =
      all
      |> Enum.with_index(1)
      |> Enum.map(fn {{clause_template, value}, idx} ->
        # Replace the ? placeholder with a numbered parameter
        clause = String.replace(clause_template, "?", "?#{idx}", global: false)
        {clause, value}
      end)
      |> Enum.unzip()

    {clauses, params}
  end

  @spec changes(db()) :: non_neg_integer()
  defp changes(db) do
    sql = "SELECT changes()"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         {:row, [count]} <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      count
    else
      _ -> 0
    end
  end

  @spec encode_json(map()) :: String.t()
  defp encode_json(map) when map_size(map) == 0, do: "{}"
  defp encode_json(map), do: Jason.encode!(map)

  @spec decode_json(String.t()) :: map()
  defp decode_json("{}"), do: %{}
  defp decode_json(json), do: Jason.decode!(json)
end
