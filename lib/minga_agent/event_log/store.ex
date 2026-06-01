defmodule MingaAgent.EventLog.Store do
  @moduledoc "SQLite storage backend for durable agent session events."

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Taxonomy

  @type db :: Exqlite.Sqlite3.db()

  @schema_version 1

  @doc "Opens or creates the agent event database."
  @spec open(String.t()) :: {:ok, db()} | {:error, term()}
  def open(db_path) do
    with :ok <- ensure_database_directory(db_path) do
      case Exqlite.Sqlite3.open(db_path) do
        {:ok, db} -> setup_opened(db, db_path)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Opens an in-memory database for tests."
  @spec open_memory() :: {:ok, db()} | {:error, term()}
  def open_memory do
    case Exqlite.Sqlite3.open(":memory:") do
      {:ok, db} -> setup_opened(db)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Closes the database connection."
  @spec close(db()) :: :ok | {:error, term()}
  def close(db), do: Exqlite.Sqlite3.close(db)

  @doc "Inserts an append-only event record."
  @spec insert(db(), EventRecord.t()) :: {:ok, pos_integer()} | {:error, term()}
  def insert(db, %EventRecord{} = record) do
    sql = """
    INSERT INTO events (session_id, event_type, payload, wall_clock, monotonic_ts)
    VALUES (?1, ?2, ?3, ?4, ?5)
    """

    params = [
      record.session_id,
      Atom.to_string(record.event_type),
      JSON.encode!(record.payload),
      DateTime.to_iso8601(record.wall_clock),
      record.monotonic_ts
    ]

    case Exqlite.Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        result =
          with :ok <- Exqlite.Sqlite3.bind(stmt, params),
               :done <- Exqlite.Sqlite3.step(db, stmt) do
            :ok
          end

        Exqlite.Sqlite3.release(db, stmt)

        case result do
          :ok -> private_last_insert_rowid(db)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns all events for a session with id greater than the cursor, ordered by id."
  @spec events_after(db(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [EventRecord.t()]} | {:error, term()}
  def events_after(db, session_id, last_id, limit \\ 1000)
      when is_binary(session_id) and is_integer(last_id) and last_id >= 0 and is_integer(limit) and
             limit > 0 do
    sql = """
    SELECT id, session_id, event_type, payload, wall_clock, monotonic_ts
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

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [session_id]),
         {:row, [latest_id]} <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      {:ok, latest_id}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the total number of agent events."
  @spec count(db()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(db) do
    case Exqlite.Sqlite3.prepare(db, "SELECT COUNT(*) FROM events") do
      {:ok, stmt} ->
        result = Exqlite.Sqlite3.step(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)

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
  @spec delete_before(db(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_before(db, cutoff) do
    sql = "DELETE FROM events WHERE wall_clock < ?1"

    case Exqlite.Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        result =
          with :ok <- Exqlite.Sqlite3.bind(stmt, [DateTime.to_iso8601(cutoff)]),
               :done <- Exqlite.Sqlite3.step(db, stmt) do
            :ok
          end

        Exqlite.Sqlite3.release(db, stmt)

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

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql) do
      rows = collect_rows(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)

      case rows do
        [["ok"]] -> {:ok, :healthy}
        other -> {:error, List.flatten(other)}
      end
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

    with :ok <- execute_all(db, statements), do: ensure_schema_version(db)
  end

  @spec ensure_schema_version(db()) :: :ok | {:error, term()}
  defp ensure_schema_version(db) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, "SELECT version FROM schema_version LIMIT 1") do
      result = Exqlite.Sqlite3.step(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)

      case result do
        :done -> execute(db, "INSERT INTO schema_version (version) VALUES (#{@schema_version})")
        {:row, [@schema_version]} -> :ok
        {:row, [_old_version]} -> :ok
      end
    end
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
    case Exqlite.Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        result = step_until_done(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)

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
    ensure_private_created_directory(expanded_dir, File.cwd!(), File.stat(expanded_dir))
  end

  @spec ensure_private_created_directory(
          String.t(),
          String.t(),
          {:ok, File.Stat.t()} | {:error, term()}
        ) ::
          :ok | {:error, term()}
  defp ensure_private_created_directory(dir, dir, _stat), do: :ok

  defp ensure_private_created_directory(_dir, _cwd, {:ok, %File.Stat{type: :directory}}), do: :ok

  defp ensure_private_created_directory(_dir, _cwd, {:ok, %File.Stat{}}), do: {:error, :enotdir}

  defp ensure_private_created_directory(dir, _cwd, {:error, :enoent}) do
    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, 0o700)
    end
  end

  defp ensure_private_created_directory(_dir, _cwd, {:error, reason}), do: {:error, reason}

  @spec private_last_insert_rowid(db()) :: {:ok, pos_integer()} | {:error, term()}
  defp private_last_insert_rowid(db) do
    with {:ok, id} <- last_insert_rowid(db),
         :ok <- ensure_private_open_database_files(db) do
      {:ok, id}
    end
  end

  @spec ensure_private_open_database_files(db()) :: :ok | {:error, term()}
  defp ensure_private_open_database_files(db) do
    case database_path(db) do
      {:ok, path} -> ensure_private_database_files(path)
      {:error, _reason} = error -> error
    end
  end

  @spec database_path(db()) :: {:ok, String.t() | nil} | {:error, term()}
  defp database_path(db) do
    case Exqlite.Sqlite3.prepare(db, "PRAGMA database_list") do
      {:ok, stmt} ->
        result = Exqlite.Sqlite3.step(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)

        case result do
          {:row, [_seq, "main", ""]} -> {:ok, nil}
          {:row, [_seq, "main", path]} when is_binary(path) -> {:ok, path}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_result, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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
    case File.exists?(path) do
      true ->
        case File.chmod(path, mode) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      false ->
        {:cont, :ok}
    end
  end

  @spec step_until_done(db(), Exqlite.Sqlite3.statement()) :: :done | {:error, term()}
  defp step_until_done(db, stmt) do
    case Exqlite.Sqlite3.step(db, stmt) do
      :done -> :done
      {:row, _row} -> step_until_done(db, stmt)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec query_events(db(), String.t(), [term()]) :: {:ok, [EventRecord.t()]} | {:error, term()}
  defp query_events(db, sql, params) do
    case Exqlite.Sqlite3.prepare(db, sql) do
      {:ok, stmt} ->
        :ok = Exqlite.Sqlite3.bind(stmt, params)
        rows = collect_rows(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)
        {:ok, rows |> Enum.map(&row_to_record/1) |> Enum.reject(&is_nil/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec collect_rows(db(), Exqlite.Sqlite3.statement()) :: [list()]
  defp collect_rows(db, stmt) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> [row | collect_rows(db, stmt)]
      :done -> []
    end
  end

  @spec row_to_record([term()]) :: EventRecord.t() | nil
  defp row_to_record([id, session_id, event_type, payload_json, wall_clock_iso, monotonic_ts]) do
    case Taxonomy.from_string(event_type) do
      {:ok, atom_type} ->
        {:ok, wall_clock, _offset} = DateTime.from_iso8601(wall_clock_iso)

        %EventRecord{
          id: id,
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

  @spec last_insert_rowid(db()) :: {:ok, pos_integer()} | {:error, term()}
  defp last_insert_rowid(db) do
    case Exqlite.Sqlite3.prepare(db, "SELECT last_insert_rowid()") do
      {:ok, stmt} ->
        result = Exqlite.Sqlite3.step(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)

        case result do
          {:row, [id]} -> {:ok, id}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_result, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec changes(db()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp changes(db) do
    case Exqlite.Sqlite3.prepare(db, "SELECT changes()") do
      {:ok, stmt} ->
        result = Exqlite.Sqlite3.step(db, stmt)
        Exqlite.Sqlite3.release(db, stmt)

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
