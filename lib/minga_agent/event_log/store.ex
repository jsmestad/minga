defmodule MingaAgent.EventLog.Store do
  @moduledoc "SQLite storage backend for durable agent session events."

  @behaviour MingaAgent.EventLog.StoreBackend

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Taxonomy
  alias Exqlite.Sqlite3

  @type db :: Sqlite3.db()

  @schema_version 2

  @doc "Opens or creates the agent event database."
  @spec open(String.t()) :: {:ok, db()} | {:error, term()}
  def open(db_path) do
    with :ok <- ensure_database_directory(db_path),
         :ok <- ensure_private_database_files(db_path) do
      case Sqlite3.open(db_path) do
        {:ok, db} -> setup_opened(db, db_path)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Opens the writer connection, recreating a database that fails an integrity check."
  @impl MingaAgent.EventLog.StoreBackend
  @spec open_writer(String.t(), keyword()) :: {:ok, db()} | {:error, term()}
  def open_writer(db_path, _opts) do
    case open(db_path) do
      {:ok, db} ->
        {:ok, db}

      {:error, reason} ->
        maybe_recreate_corrupt_database(db_path, reason)
    end
  end

  @doc "Opens an in-memory database for tests."
  @spec open_memory() :: {:ok, db()} | {:error, term()}
  def open_memory do
    case Sqlite3.open(":memory:") do
      {:ok, db} -> setup_opened(db)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Closes the database connection."
  @impl MingaAgent.EventLog.StoreBackend
  @spec close(db()) :: :ok | {:error, term()}
  def close(db), do: Sqlite3.close(db)

  @doc "Inserts an append-only event record."
  @impl MingaAgent.EventLog.StoreBackend
  @spec insert(db(), EventRecord.t()) :: {:ok, pos_integer()} | {:error, term()}
  def insert(db, %EventRecord{} = record) do
    with {:ok, payload_json} <- encode_payload(record.payload) do
      insert_encoded(db, record, payload_json)
    end
  end

  @doc "Returns all events for a session with id greater than the cursor, ordered by id."
  @spec events_after(db(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  def events_after(db, session_id, last_id, limit \\ 1000)
      when is_binary(session_id) and is_integer(last_id) and last_id >= 0 and is_integer(limit) and
             limit > 0 do
    sql = """
    SELECT id, event_key, session_id, event_type, payload, wall_clock, monotonic_ts
    FROM events
    WHERE session_id = ?1 AND id > ?2
    ORDER BY id ASC
    LIMIT ?3
    """

    query_events(db, sql, [session_id, last_id, limit])
  end

  @doc "Returns the latest event id for a session, or 0 when it has no events."
  @spec latest_id(db(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def latest_id(db, session_id) when is_binary(session_id) do
    sql = "SELECT COALESCE(MAX(id), 0) FROM events WHERE session_id = ?1"

    with {:ok, stmt} <- Sqlite3.prepare(db, sql),
         :ok <- Sqlite3.bind(stmt, [session_id]),
         {:row, [latest_id]} <- Sqlite3.step(db, stmt),
         :ok <- Sqlite3.release(db, stmt) do
      {:ok, latest_id}
    end
  end

  @doc """
  Returns `:file_edit_proposed` events whose payload `path` exactly matches, most recent first.

  Used by code-provenance reads to find every agent edit that touched a file,
  across all sessions. Bounded by `limit` (newest events win).
  """
  @spec file_edits_for_path(db(), String.t(), pos_integer()) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  def file_edits_for_path(db, path, limit \\ 200)
      when is_binary(path) and is_integer(limit) and limit > 0 do
    sql = """
    SELECT id, event_key, session_id, event_type, payload, wall_clock, monotonic_ts
    FROM events
    WHERE event_type = 'file_edit_proposed' AND json_extract(payload, '$.path') = ?1
    ORDER BY id DESC
    LIMIT ?2
    """

    query_events(db, sql, [path, limit])
  end

  @doc "Returns the total number of agent events."
  @spec count(db()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(db) do
    case Sqlite3.prepare(db, "SELECT COUNT(*) FROM events") do
      {:ok, stmt} ->
        result = Sqlite3.step(db, stmt)
        Sqlite3.release(db, stmt)

        case result do
          {:row, [count]} -> {:ok, count}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_result, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Deletes events older than the given wall-clock time."
  @impl MingaAgent.EventLog.StoreBackend
  @spec delete_before(db(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_before(db, cutoff) do
    sql = "DELETE FROM events WHERE wall_clock < ?1"

    case Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        result =
          with :ok <- Sqlite3.bind(stmt, [DateTime.to_iso8601(cutoff)]),
               :done <- Sqlite3.step(db, stmt) do
            :ok
          end

        Sqlite3.release(db, stmt)

        case result do
          :ok -> changes(db)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Runs a SQLite integrity check."
  @spec integrity_check(db(), :full | :quick) :: {:ok, :healthy} | {:error, [String.t()]}
  def integrity_check(db, mode \\ :quick) do
    sql = if mode == :full, do: "PRAGMA integrity_check", else: "PRAGMA quick_check"

    with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
      rows = collect_rows(db, stmt)
      Sqlite3.release(db, stmt)

      case rows do
        [["ok"]] -> {:ok, :healthy}
        other -> {:error, List.flatten(other)}
      end
    end
  end

  @spec insert_encoded(db(), EventRecord.t(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp insert_encoded(db, record, payload_json) do
    sql = """
    INSERT INTO events (event_key, session_id, event_type, payload, wall_clock, monotonic_ts)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    ON CONFLICT(event_key) DO NOTHING
    RETURNING id
    """

    params = [
      record.event_key,
      record.session_id,
      Atom.to_string(record.event_type),
      payload_json,
      DateTime.to_iso8601(record.wall_clock),
      record.monotonic_ts
    ]

    case Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        result =
          with :ok <- Sqlite3.bind(stmt, params) do
            insert_result(db, stmt, record.event_key)
          end

        Sqlite3.release(db, stmt)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec encode_payload(map()) :: {:ok, String.t()} | {:error, term()}
  defp encode_payload(payload) do
    {:ok, JSON.encode!(payload)}
  rescue
    exception -> {:error, {:serialization_failed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:serialization_failed, kind}}
  end

  @spec insert_result(db(), Sqlite3.statement(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp insert_result(db, stmt, event_key) do
    case Sqlite3.step(db, stmt) do
      {:row, [id]} -> finish_returning_insert(db, stmt, id)
      :done -> event_id_by_key(db, event_key)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finish_returning_insert(db(), Sqlite3.statement(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp finish_returning_insert(db, stmt, id) do
    case Sqlite3.step(db, stmt) do
      :done -> {:ok, id}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_result, other}}
    end
  end

  @spec event_id_by_key(db(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  defp event_id_by_key(db, event_key) do
    with {:ok, stmt} <- Sqlite3.prepare(db, "SELECT id FROM events WHERE event_key = ?1"),
         :ok <- Sqlite3.bind(stmt, [event_key]) do
      result = Sqlite3.step(db, stmt)
      Sqlite3.release(db, stmt)
      normalize_event_id(result)
    end
  end

  @spec normalize_event_id({:row, [pos_integer()]} | :done | {:error, term()}) ::
          {:ok, pos_integer()} | {:error, term()}
  defp normalize_event_id({:row, [id]}), do: {:ok, id}
  defp normalize_event_id(:done), do: {:error, :event_not_found_after_conflict}
  defp normalize_event_id({:error, reason}), do: {:error, reason}

  @spec maybe_recreate_corrupt_database(String.t(), term()) ::
          {:ok, db()} | {:error, term()}
  defp maybe_recreate_corrupt_database(path, reason) do
    recreate_corrupt_database(path, reason, File.exists?(path) and corrupt?(path))
  end

  @spec recreate_corrupt_database(String.t(), term(), boolean()) ::
          {:ok, db()} | {:error, term()}
  defp recreate_corrupt_database(path, reason, true) do
    suffix = ".corrupt-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

    Minga.Log.warning(
      :agent,
      "[AgentEventLog] corrupt database, quarantining before recreation: #{inspect(reason)}"
    )

    with :ok <- quarantine_database_files(path, suffix) do
      open(path)
    end
  end

  defp recreate_corrupt_database(_path, reason, false), do: {:error, reason}

  @spec corrupt?(String.t()) :: boolean()
  defp corrupt?(path) do
    case Sqlite3.open(path) do
      {:ok, db} ->
        result = integrity_check(db, :quick)
        _ = close(db)
        match?({:error, _}, result)

      {:error, _reason} ->
        false
    end
  end

  @spec setup_opened(db(), String.t() | nil) :: {:ok, db()} | {:error, term()}
  defp setup_opened(db, db_path \\ nil) do
    result =
      case setup(db) do
        :ok -> ensure_private_database_files(db_path)
        {:error, _reason} = error -> error
      end

    case result do
      :ok ->
        {:ok, db}

      {:error, _reason} = error ->
        _ = close(db)
        error
    end
  end

  @spec setup(db()) :: :ok | {:error, term()}
  defp setup(db) do
    statements = [
      "PRAGMA journal_mode=WAL",
      "PRAGMA synchronous=NORMAL",
      "PRAGMA cache_size=-8000",
      "PRAGMA foreign_keys=ON",
      """
      CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_key TEXT NOT NULL,
        session_id TEXT NOT NULL,
        event_type TEXT NOT NULL,
        payload TEXT NOT NULL DEFAULT '{}',
        wall_clock TEXT NOT NULL,
        monotonic_ts INTEGER NOT NULL
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_agent_events_session_id_id ON events(session_id, id)",
      "CREATE INDEX IF NOT EXISTS idx_agent_events_event_type ON events(event_type)",
      "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)"
    ]

    with :ok <- execute_all(db, statements),
         :ok <- ensure_schema_version(db) do
      execute(
        db,
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_events_event_key ON events(event_key)"
      )
    end
  end

  @spec ensure_schema_version(db()) :: :ok | {:error, term()}
  defp ensure_schema_version(db) do
    with {:ok, stmt} <- Sqlite3.prepare(db, "SELECT version FROM schema_version LIMIT 1") do
      result = Sqlite3.step(db, stmt)
      Sqlite3.release(db, stmt)
      apply_schema_version(db, result)
    end
  end

  @spec apply_schema_version(db(), :done | {:row, [integer()]} | {:error, term()}) ::
          :ok | {:error, term()}
  defp apply_schema_version(db, :done) do
    execute(db, "INSERT INTO schema_version (version) VALUES (#{@schema_version})")
  end

  defp apply_schema_version(_db, {:row, [@schema_version]}), do: :ok
  defp apply_schema_version(db, {:row, [1]}), do: migrate_schema_v1(db)
  defp apply_schema_version(_db, {:row, [version]}), do: {:error, {:unsupported_schema, version}}
  defp apply_schema_version(_db, {:error, reason}), do: {:error, reason}

  @spec migrate_schema_v1(db()) :: :ok | {:error, term()}
  defp migrate_schema_v1(db) do
    with :ok <- execute(db, "BEGIN IMMEDIATE") do
      result =
        execute_all(db, [
          "ALTER TABLE events ADD COLUMN event_key TEXT",
          "UPDATE events SET event_key = 'legacy-' || id WHERE event_key IS NULL",
          "CREATE UNIQUE INDEX idx_agent_events_event_key ON events(event_key)",
          "UPDATE schema_version SET version = #{@schema_version}"
        ])

      finish_migration(db, result)
    end
  end

  @spec finish_migration(db(), :ok | {:error, term()}) :: :ok | {:error, term()}
  defp finish_migration(db, :ok), do: execute(db, "COMMIT")

  defp finish_migration(db, {:error, _reason} = error) do
    _ = execute(db, "ROLLBACK")
    error
  end

  @spec execute_all(db(), [String.t()]) :: :ok | {:error, term()}
  defp execute_all(db, statements) do
    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case execute(db, statement) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec execute(db(), String.t()) :: :ok | {:error, term()}
  defp execute(db, sql) do
    case Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        result = step_until_done(db, stmt)
        Sqlite3.release(db, stmt)

        case result do
          :done -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec ensure_database_directory(String.t()) :: :ok | {:error, term()}
  defp ensure_database_directory(db_path) do
    db_path
    |> Path.dirname()
    |> ensure_private_created_directory()
  end

  @spec ensure_private_created_directory(String.t()) :: :ok | {:error, term()}
  defp ensure_private_created_directory(dir) do
    expanded_dir = Path.expand(dir)
    ensure_private_created_directory(expanded_dir, File.lstat(expanded_dir))
  end

  @spec ensure_private_created_directory(
          String.t(),
          {:ok, File.Stat.t()} | {:error, term()}
        ) :: :ok | {:error, term()}
  defp ensure_private_created_directory(dir, {:ok, %File.Stat{type: :directory}}),
    do: File.chmod(dir, 0o700)

  defp ensure_private_created_directory(_dir, {:ok, %File.Stat{type: type}}),
    do: {:error, {:unsafe_database_directory, type}}

  defp ensure_private_created_directory(dir, {:error, :enoent}) do
    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, 0o700)
    end
  end

  defp ensure_private_created_directory(_dir, {:error, reason}), do: {:error, reason}

  @spec ensure_private_database_files(String.t() | nil) :: :ok | {:error, term()}
  defp ensure_private_database_files(nil), do: :ok

  defp ensure_private_database_files(path) do
    path
    |> database_file_paths()
    |> Enum.reduce_while(:ok, fn file_path, :ok -> chmod_existing_file(file_path, 0o600) end)
  end

  @spec database_file_paths(String.t()) :: [String.t()]
  defp database_file_paths(path), do: [path, path <> "-wal", path <> "-shm"]

  @spec chmod_existing_file(String.t(), non_neg_integer()) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp chmod_existing_file(path, mode) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.chmod(path, mode) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:ok, %File.Stat{type: type}} ->
        {:halt, {:error, {:unsafe_database_path, path, type}}}

      {:error, :enoent} ->
        {:cont, :ok}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  @spec quarantine_database_files(String.t(), String.t()) :: :ok | {:error, term()}
  defp quarantine_database_files(path, suffix) do
    path
    |> database_file_paths()
    |> Enum.reduce_while(:ok, fn file_path, :ok -> quarantine_existing_file(file_path, suffix) end)
  end

  @spec quarantine_existing_file(String.t(), String.t()) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp quarantine_existing_file(path, suffix) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.rename(path, path <> suffix) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:quarantine_failed, path, reason}}}
        end

      {:ok, %File.Stat{type: type}} ->
        {:halt, {:error, {:unsafe_database_path, path, type}}}

      {:error, :enoent} ->
        {:cont, :ok}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  @spec step_until_done(db(), Sqlite3.statement()) :: :done | {:error, term()}
  defp step_until_done(db, stmt) do
    case Sqlite3.step(db, stmt) do
      :done -> :done
      {:row, _row} -> step_until_done(db, stmt)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec query_events(db(), String.t(), [term()]) :: {:ok, [EventRecord.t()]} | {:error, term()}
  defp query_events(db, sql, params) do
    case Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        :ok = Sqlite3.bind(stmt, params)
        rows = collect_rows(db, stmt)
        Sqlite3.release(db, stmt)
        {:ok, rows |> Enum.map(&row_to_record/1) |> Enum.reject(&is_nil/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec collect_rows(db(), Sqlite3.statement()) :: [list()]
  defp collect_rows(db, stmt) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> [row | collect_rows(db, stmt)]
      :done -> []
    end
  end

  @spec row_to_record([term()]) :: EventRecord.t() | nil
  defp row_to_record([
         id,
         event_key,
         session_id,
         event_type,
         payload_json,
         wall_clock_iso,
         monotonic_ts
       ]) do
    case Taxonomy.from_string(event_type) do
      {:ok, atom_type} ->
        {:ok, wall_clock, _offset} = DateTime.from_iso8601(wall_clock_iso)

        %EventRecord{
          id: id,
          event_key: event_key,
          session_id: session_id,
          event_type: atom_type,
          payload: JSON.decode!(payload_json),
          wall_clock: wall_clock,
          monotonic_ts: monotonic_ts
        }

      :error ->
        nil
    end
  end

  @spec changes(db()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp changes(db) do
    case Sqlite3.prepare(db, "SELECT changes()") do
      {:ok, stmt} ->
        result = Sqlite3.step(db, stmt)
        Sqlite3.release(db, stmt)

        case result do
          {:row, [count]} -> {:ok, count}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_result, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
