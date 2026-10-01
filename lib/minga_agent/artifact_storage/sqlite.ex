defmodule MingaAgent.ArtifactStorage.SQLite do
  @moduledoc "Single-writer SQLite setup with a fixed main/WAL/SHM logical envelope."

  alias MingaAgent.ArtifactStorage.Files
  alias Exqlite.Sqlite3

  @type db :: %__MODULE__{connection: Sqlite3.db(), path: String.t()}

  @enforce_keys [:connection, :path]
  defstruct [:connection, :path]
  @type transaction_result(value) ::
          {:ok, value}
          | {:error, term()}
          | {:error, {:checkpoint_failed, term()}, {:committed, value}}

  @doc "Opens a private bounded database, installs schema, and truncates its WAL."
  @spec open(String.t(), [String.t()]) :: {:ok, db()} | {:error, term()}
  def open(path, schema) when is_binary(path) and is_list(schema) do
    open_with_lock(path, schema, :normal)
  end

  @doc "Opens a database under a retained exclusive SQLite lock."
  @spec open_exclusive(String.t(), [String.t()]) :: {:ok, db()} | {:error, term()}
  def open_exclusive(path, schema) when is_binary(path) and is_list(schema) do
    case open_with_lock(path, schema, :exclusive) do
      {:error, reason} ->
        if lock_conflict?(reason),
          do: {:error, :artifact_root_in_use},
          else: {:error, reason}

      {:ok, _db} = ok ->
        ok
    end
  end

  @spec open_with_lock(String.t(), [String.t()], :normal | :exclusive) ::
          {:ok, db()} | {:error, term()}
  defp open_with_lock(path, schema, lock) do
    with :ok <- Files.ensure_private_directory(Path.dirname(path)),
         :ok <- ensure_private_files(path),
         {:ok, connection} <- Sqlite3.open(path) do
      setup_opened(connection, path, schema, lock)
    else
      {:error, reason} -> {:error, normalize_reason(reason)}
    end
  end

  @doc "Closes the sole database connection."
  @spec close(db()) :: :ok | {:error, term()}
  def close(%__MODULE__{connection: connection}), do: Sqlite3.close(connection)

  @doc "Executes a statement to completion."
  @spec execute(db(), String.t(), [term()]) :: :ok | {:error, term()}
  def execute(%__MODULE__{connection: connection}, sql, params \\ [])
      when is_binary(sql) and is_list(params) do
    case Sqlite3.prepare(connection, sql) do
      {:ok, statement} ->
        result = execute_prepared(connection, statement, params)
        _ = Sqlite3.release(connection, statement)
        normalize_result(result)

      {:error, reason} ->
        {:error, normalize_reason(reason)}
    end
  end

  @doc "Returns all rows for a bounded query."
  @spec query(db(), String.t(), [term()]) :: {:ok, [[term()]]} | {:error, term()}
  def query(%__MODULE__{connection: connection}, sql, params \\ [])
      when is_binary(sql) and is_list(params) do
    case Sqlite3.prepare(connection, sql) do
      {:ok, statement} ->
        result =
          with :ok <- Sqlite3.bind(statement, params) do
            collect_rows(connection, statement, [])
          end

        _ = Sqlite3.release(connection, statement)
        normalize_result(result)

      {:error, reason} ->
        {:error, normalize_reason(reason)}
    end
  end

  @doc "Commits one immediate transaction and requires a successful TRUNCATE checkpoint."
  @spec transaction(db(), (-> {:ok, value} | {:error, term()}), keyword()) ::
          transaction_result(value)
        when value: term()
  def transaction(db, callback, opts \\ []) when is_function(callback, 0) and is_list(opts) do
    fault = Keyword.get(opts, :before_checkpoint, fn -> :ok end)

    with :ok <- execute(db, "BEGIN IMMEDIATE") do
      finish_transaction(db, callback.(), fault)
    end
  end

  @doc "Runs a blocking TRUNCATE checkpoint and rejects busy or residual WAL pages."
  @spec checkpoint(db()) :: :ok | {:error, term()}
  def checkpoint(db) do
    case query(db, "PRAGMA wal_checkpoint(TRUNCATE)") do
      {:ok, [[0, 0, 0]]} -> :ok
      {:ok, [[busy, log_pages, checkpointed]]} ->
        {:error, {:wal_not_truncated, busy, log_pages, checkpointed}}

      {:ok, rows} ->
        {:error, {:unexpected_checkpoint_result, rows}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Makes SQLite main, WAL, and SHM files private and rejects special files."
  @spec ensure_private_files(String.t()) :: :ok | {:error, term()}
  def ensure_private_files(path) when is_binary(path) do
    [path, path <> "-wal", path <> "-shm"]
    |> Enum.reduce_while(:ok, fn candidate, :ok ->
      case Files.ensure_regular_or_missing(candidate) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec setup_opened(Sqlite3.db(), String.t(), [String.t()], :normal | :exclusive) ::
          {:ok, db()} | {:error, term()}
  defp setup_opened(connection, path, schema, lock) do
    db = %__MODULE__{connection: connection, path: path}
    statements = [
      "PRAGMA page_size=4096",
      "PRAGMA journal_mode=WAL",
      "PRAGMA synchronous=FULL",
      "PRAGMA max_page_count=1024",
      "PRAGMA foreign_keys=ON",
      "PRAGMA cache_spill=OFF",
      "PRAGMA wal_autocheckpoint=0"
    ]

    result =
      with :ok <- acquire_lock(db, lock),
           :ok <- execute_all(db, statements),
           :ok <- execute_all(db, schema),
           :ok <- checkpoint(db),
           :ok <- ensure_private_files(path) do
        {:ok, db}
      end

    case result do
      {:ok, _db} = ok -> ok
      {:error, _reason} = error ->
        _ = close(db)
        error
    end
  end

  @spec acquire_lock(db(), :normal | :exclusive) :: :ok | {:error, term()}
  defp acquire_lock(_db, :normal), do: :ok

  defp acquire_lock(db, :exclusive) do
    with {:ok, [["exclusive"]]} <- query(db, "PRAGMA locking_mode=EXCLUSIVE"),
         :ok <- execute(db, "BEGIN EXCLUSIVE"),
         :ok <- execute(db, "COMMIT") do
      :ok
    else
      {:ok, result} -> {:error, {:exclusive_lock_rejected, result}}
      {:error, _reason} = error -> error
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

  @spec execute_prepared(Sqlite3.db(), Sqlite3.statement(), [term()]) ::
          :ok | {:error, term()}
  defp execute_prepared(db, statement, params) do
    with :ok <- Sqlite3.bind(statement, params) do
      step_until_done(db, statement)
    end
  end

  @spec step_until_done(Sqlite3.db(), Sqlite3.statement()) :: :ok | {:error, term()}
  defp step_until_done(db, statement) do
    case Sqlite3.step(db, statement) do
      :done -> :ok
      {:row, _row} -> step_until_done(db, statement)
      :busy -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec collect_rows(Sqlite3.db(), Sqlite3.statement(), [[term()]]) ::
          {:ok, [[term()]]} | {:error, term()}
  defp collect_rows(db, statement, rows) do
    case Sqlite3.step(db, statement) do
      {:row, row} -> collect_rows(db, statement, [row | rows])
      :done -> {:ok, Enum.reverse(rows)}
      :busy -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec finish_transaction(db(), {:ok, value} | {:error, term()}, (-> :ok | {:error, term()})) ::
          transaction_result(value)
        when value: term()
  defp finish_transaction(db, {:ok, value}, before_checkpoint) do
    case execute(db, "COMMIT") do
      :ok -> checkpoint_committed(db, value, before_checkpoint.())
      {:error, reason} ->
        _ = execute(db, "ROLLBACK")
        {:error, reason}
    end
  end

  defp finish_transaction(db, {:error, _reason} = error, _before_checkpoint) do
    _ = execute(db, "ROLLBACK")
    error
  end

  @spec normalize_result(:ok | {:ok, term()} | {:error, term()}) ::
          :ok | {:ok, term()} | {:error, term()}
  defp normalize_result({:error, reason}), do: {:error, normalize_reason(reason)}
  defp normalize_result(result), do: result

  @spec normalize_reason(term()) :: term()
  defp normalize_reason(:full), do: :disk_full
  defp normalize_reason(:enospc), do: :disk_full

  defp normalize_reason(reason) when is_binary(reason) do
    if String.contains?(String.downcase(reason), "database or disk is full"),
      do: :disk_full,
      else: reason
  end

  defp normalize_reason(reason), do: reason

  @spec lock_conflict?(term()) :: boolean()
  defp lock_conflict?(:busy), do: true
  defp lock_conflict?(:locked), do: true

  defp lock_conflict?(reason) when is_binary(reason) do
    normalized = String.downcase(reason)
    String.contains?(normalized, "database is locked") or
      String.contains?(normalized, "database table is locked") or
      String.contains?(normalized, "database is busy")
  end

  defp lock_conflict?(_reason), do: false

  @spec checkpoint_committed(db(), value, :ok | {:error, term()}) :: transaction_result(value)
        when value: term()
  defp checkpoint_committed(%__MODULE__{path: path} = db, value, :ok) do
    with :ok <- checkpoint(db),
         :ok <- ensure_private_files(path) do
      {:ok, value}
    else
      {:error, reason} -> {:error, {:checkpoint_failed, reason}, {:committed, value}}
    end
  end

  defp checkpoint_committed(%__MODULE__{path: path}, value, {:error, reason}) do
    _ = ensure_private_files(path)
    {:error, {:checkpoint_failed, reason}, {:committed, value}}
  end
end
