defmodule MingaAgent.ArtifactQuota.Ledger do
  @moduledoc "Private bounded SQLite ledger for aggregate retained-artifact admission."

  alias MingaAgent.ArtifactStorage.SQLite
  alias MingaAgent.ArtifactStore.Limits

  @type db :: SQLite.db()
  @type namespace_row :: %{
          namespace: String.t(),
          charged_bytes: non_neg_integer(),
          items: non_neg_integer(),
          artifacts: non_neg_integer(),
          open_captures: non_neg_integer(),
          session_bytes: pos_integer(),
          session_items: pos_integer(),
          session_artifacts: pos_integer(),
          session_open_captures: pos_integer()
        }
  @type mutation(value) :: SQLite.transaction_result(value)

  @schema [
    """
    CREATE TABLE IF NOT EXISTS quota_schema (
      version INTEGER NOT NULL
    )
    """,
    "INSERT INTO quota_schema(version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM quota_schema)",
    "UPDATE quota_schema SET version = version",
    """
    CREATE TABLE IF NOT EXISTS namespaces (
      namespace TEXT PRIMARY KEY,
      charged_bytes INTEGER NOT NULL CHECK(charged_bytes >= 0),
      items INTEGER NOT NULL CHECK(items >= 0),
      artifacts INTEGER NOT NULL CHECK(artifacts >= 0),
      open_captures INTEGER NOT NULL CHECK(open_captures >= 0),
      session_bytes INTEGER NOT NULL CHECK(session_bytes > 0),
      session_items INTEGER NOT NULL CHECK(session_items > 0),
      session_artifacts INTEGER NOT NULL CHECK(session_artifacts > 0),
      session_open_captures INTEGER NOT NULL CHECK(session_open_captures > 0)
    )
    """
  ]

  @doc "Opens the root quota ledger and retains its exclusive cross-BEAM lock."
  @spec open(String.t()) :: {:ok, db()} | {:error, term()}
  def open(path) do
    case SQLite.open_exclusive(path, @schema) do
      {:ok, db} -> validate_schema(db)
      {:error, _reason} = error -> error
    end
  end

  @doc "Closes the root quota ledger."
  @spec close(db()) :: :ok | {:error, term()}
  def close(db), do: SQLite.close(db)

  @doc "Loads all aggregate namespace counters."
  @spec all(db()) :: {:ok, [namespace_row()]} | {:error, term()}
  def all(db) do
    sql = """
    SELECT namespace, charged_bytes, items, artifacts, open_captures,
           session_bytes, session_items, session_artifacts, session_open_captures
    FROM namespaces
    ORDER BY namespace
    """

    with {:ok, rows} <- SQLite.query(db, sql) do
      {:ok, Enum.map(rows, &decode_row/1)}
    end
  end

  @doc "Loads one namespace counter row."
  @spec get(db(), String.t()) :: {:ok, namespace_row() | nil} | {:error, term()}
  def get(db, namespace) do
    sql = """
    SELECT namespace, charged_bytes, items, artifacts, open_captures,
           session_bytes, session_items, session_artifacts, session_open_captures
    FROM namespaces WHERE namespace = ?1
    """

    case SQLite.query(db, sql, [namespace]) do
      {:ok, [row]} -> {:ok, decode_row(row)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Durably reserves a new namespace SQLite envelope."
  @spec insert_namespace(db(), String.t(), Limits.t(), keyword()) :: mutation(:inserted)
  def insert_namespace(db, namespace, %Limits{} = limits, opts \\ []) do
    sql = """
    INSERT INTO namespaces(
      namespace, charged_bytes, items, artifacts, open_captures,
      session_bytes, session_items, session_artifacts, session_open_captures
    ) VALUES (?1, ?2, 0, 0, 0, ?3, ?4, ?5, ?6)
    """

    params = [
      namespace,
      Limits.sqlite_envelope_bytes(),
      limits.session_bytes,
      limits.session_items,
      limits.session_artifacts,
      limits.session_open_captures
    ]

    SQLite.transaction(db, fn -> mutation(db, sql, params, :inserted) end, opts)
  end

  @doc "Durably increments one namespace and aggregate reservation."
  @spec reserve(
          db(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          integer(),
          integer(),
          keyword()
        ) ::
          mutation(:reserved)
  def reserve(db, namespace, bytes, items, artifacts, open_captures, opts \\ []) do
    sql = """
    UPDATE namespaces
    SET charged_bytes = charged_bytes + ?2,
        items = items + ?3,
        artifacts = artifacts + ?4,
        open_captures = open_captures + ?5
    WHERE namespace = ?1
    """

    SQLite.transaction(
      db,
      fn -> mutation(db, sql, [namespace, bytes, items, artifacts, open_captures], :reserved) end,
      opts
    )
  end

  @doc "Durably releases counters only after owned files have been removed."
  @spec release(
          db(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) ::
          mutation(:released)
  def release(db, namespace, bytes, items, artifacts, opts \\ []) do
    sql = """
    UPDATE namespaces
    SET charged_bytes = charged_bytes - ?2,
        items = items - ?3,
        artifacts = artifacts - ?4
    WHERE namespace = ?1
      AND charged_bytes >= ?2
      AND items >= ?3
      AND artifacts >= ?4
    """

    SQLite.transaction(
      db,
      fn ->
        with :ok <- SQLite.execute(db, sql, [namespace, bytes, items, artifacts]),
             {:ok, [[changes]]} <- SQLite.query(db, "SELECT changes()"),
             true <- changes == 1 do
          {:ok, :released}
        else
          false -> {:error, :invalid_quota_release}
          {:error, _reason} = error -> error
        end
      end,
      opts
    )
  end

  @doc "Durably releases unused conservative bytes/items while retaining the artifact."
  @spec release_reservation(db(), String.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          mutation(:released)
  def release_reservation(db, namespace, bytes, items, opts \\ []) do
    release(db, namespace, bytes, items, 0, opts)
  end

  @doc "Durably decrements an open-capture reservation."
  @spec finish_capture(db(), String.t(), keyword()) :: mutation(:finished)
  def finish_capture(db, namespace, opts \\ []) do
    sql = """
    UPDATE namespaces SET open_captures = open_captures - 1
    WHERE namespace = ?1 AND open_captures > 0
    """

    SQLite.transaction(
      db,
      fn ->
        with :ok <- SQLite.execute(db, sql, [namespace]),
             {:ok, [[changes]]} <- SQLite.query(db, "SELECT changes()"),
             true <- changes == 1 do
          {:ok, :finished}
        else
          false -> {:error, :invalid_open_capture_release}
          {:error, _reason} = error -> error
        end
      end,
      opts
    )
  end

  @doc "Durably removes every counter reserved for one canceled open capture."
  @spec cancel_capture(
          db(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: mutation(:canceled)
  def cancel_capture(db, namespace, bytes, items, opts \\ []) do
    sql = """
    UPDATE namespaces
    SET charged_bytes = charged_bytes - ?2,
        items = items - ?3,
        artifacts = artifacts - 1,
        open_captures = open_captures - 1
    WHERE namespace = ?1
      AND charged_bytes >= ?2
      AND items >= ?3
      AND artifacts > 0
      AND open_captures > 0
    """

    SQLite.transaction(
      db,
      fn ->
        with :ok <- SQLite.execute(db, sql, [namespace, bytes, items]),
             {:ok, [[changes]]} <- SQLite.query(db, "SELECT changes()"),
             true <- changes == 1 do
          {:ok, :canceled}
        else
          false -> {:error, :invalid_quota_release}
          {:error, _reason} = error -> error
        end
      end,
      opts
    )
  end

  @doc "Reconciles one namespace aggregate to facts owned by its durable manifest."
  @spec reconcile(
          db(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: mutation(:reconciled)
  def reconcile(db, namespace, bytes, items, artifacts, open_captures, opts \\ []) do
    sql = """
    UPDATE namespaces
    SET charged_bytes = ?2,
        items = ?3,
        artifacts = ?4,
        open_captures = ?5
    WHERE namespace = ?1
    """

    SQLite.transaction(
      db,
      fn ->
        mutation(
          db,
          sql,
          [namespace, bytes, items, artifacts, open_captures],
          :reconciled
        )
      end,
      opts
    )
  end

  @doc "Removes a durably deleted namespace and all of its conservative reservations."
  @spec delete_namespace(db(), String.t(), keyword()) :: mutation(:deleted)
  def delete_namespace(db, namespace, opts \\ []) do
    sql = """
    DELETE FROM namespaces
    WHERE namespace = ?1 AND open_captures = 0
    """

    SQLite.transaction(
      db,
      fn ->
        with :ok <- SQLite.execute(db, sql, [namespace]),
             {:ok, [[changes]]} <- SQLite.query(db, "SELECT changes()"),
             true <- changes == 1 do
          {:ok, :deleted}
        else
          false -> {:error, :namespace_not_empty}
          {:error, _reason} = error -> error
        end
      end,
      opts
    )
  end

  @spec mutation(db(), String.t(), [term()], value) :: {:ok, value} | {:error, term()}
        when value: term()
  defp mutation(db, sql, params, value) do
    with :ok <- SQLite.execute(db, sql, params),
         {:ok, [[changes]]} <- SQLite.query(db, "SELECT changes()"),
         true <- changes == 1 do
      {:ok, value}
    else
      false -> {:error, :quota_row_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec validate_schema(db()) :: {:ok, db()} | {:error, term()}
  defp validate_schema(db) do
    case SQLite.query(db, "SELECT version FROM quota_schema") do
      {:ok, [[1]]} ->
        {:ok, db}

      {:ok, rows} ->
        _ = close(db)
        {:error, {:unsupported_artifact_quota_schema, rows}}

      {:error, reason} ->
        _ = close(db)
        {:error, reason}
    end
  end

  @spec decode_row([term()]) :: namespace_row()
  defp decode_row([
         namespace,
         charged_bytes,
         items,
         artifacts,
         open_captures,
         session_bytes,
         session_items,
         session_artifacts,
         session_open_captures
       ]) do
    %{
      namespace: namespace,
      charged_bytes: charged_bytes,
      items: items,
      artifacts: artifacts,
      open_captures: open_captures,
      session_bytes: session_bytes,
      session_items: session_items,
      session_artifacts: session_artifacts,
      session_open_captures: session_open_captures
    }
  end
end
