defmodule MingaAgent.ArtifactStore.Metadata do
  @moduledoc "Bounded per-namespace SQLite manifests, pin sets, and expiration tombstones."

  alias MingaAgent.ArtifactStorage.SQLite
  alias MingaAgent.ArtifactStore.Integrity
  alias MingaAgent.ArtifactStore.Limits

  @type db :: SQLite.db()
  @type row :: %{
          id: String.t(),
          delivery_key: String.t(),
          media_type: String.t(),
          mode: :bytes | :items,
          state: :open | :terminal,
          capture: :complete | {:incomplete, atom()} | nil,
          bytes: non_neg_integer(),
          items: non_neg_integer(),
          sha256: String.t() | nil,
          charged_bytes: non_neg_integer(),
          reserved_data: non_neg_integer(),
          limit_reason: atom() | nil
        }
  @type mutation(value) :: SQLite.transaction_result(value)

  @bootstrap_schema [
    "CREATE TABLE IF NOT EXISTS artifact_schema (version INTEGER NOT NULL)",
    "INSERT INTO artifact_schema(version) SELECT 2 WHERE NOT EXISTS (SELECT 1 FROM artifact_schema)"
  ]

  @schema [
    """
    CREATE TABLE IF NOT EXISTS artifacts (
      id TEXT PRIMARY KEY,
      delivery_key TEXT NOT NULL UNIQUE,
      media_type TEXT NOT NULL,
      mode TEXT NOT NULL CHECK(mode IN ('bytes', 'items')),
      state TEXT NOT NULL CHECK(state IN ('open', 'terminal')),
      capture_status TEXT CHECK(capture_status IN ('complete', 'incomplete')),
      incomplete_reason TEXT,
      bytes INTEGER NOT NULL CHECK(bytes >= 0),
      items INTEGER NOT NULL CHECK(items >= 0),
      sha256 TEXT,
      charged_bytes INTEGER NOT NULL CHECK(charged_bytes >= 0),
      reserved_data INTEGER NOT NULL CHECK(reserved_data >= 0),
      limit_reason TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS artifact_blocks (
      artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
      file_kind INTEGER NOT NULL CHECK(file_kind IN (0, 1)),
      block_number INTEGER NOT NULL CHECK(block_number >= 0),
      sha256 BLOB NOT NULL CHECK(length(sha256) = 32),
      PRIMARY KEY(artifact_id, file_kind, block_number)
    ) WITHOUT ROWID
    """,
    """
    CREATE TABLE IF NOT EXISTS pin_sets (
      pin_key TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK(kind IN ('delivery', 'snapshot', 'task'))
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS pin_refs (
      pin_key TEXT NOT NULL REFERENCES pin_sets(pin_key) ON DELETE CASCADE,
      artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE CASCADE,
      pin_kind TEXT NOT NULL CHECK(pin_kind IN ('delivery', 'snapshot', 'task')),
      PRIMARY KEY(pin_key, artifact_id)
    )
    """,
    "CREATE INDEX IF NOT EXISTS artifact_pin_refs_artifact ON pin_refs(artifact_id)",
    """
    CREATE TABLE IF NOT EXISTS tombstones (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      artifact_id TEXT NOT NULL UNIQUE
    )
    """
  ]

  @doc "Opens one private namespace manifest under its retained single-writer lock."
  @spec open(String.t()) :: {:ok, db()} | {:error, term()}
  def open(path) do
    case SQLite.open_exclusive(path, @bootstrap_schema) do
      {:ok, db} -> open_validated(db)
      {:error, :artifact_root_in_use} -> {:error, :artifact_namespace_in_use}
      {:error, _reason} = error -> error
    end
  end

  @doc "Closes one namespace manifest database."
  @spec close(db()) :: :ok | {:error, term()}
  def close(db), do: SQLite.close(db)

  @doc "Inserts an admitted open capture before capture files are created."
  @spec insert_capture(db(), row(), keyword()) :: mutation(:inserted)
  def insert_capture(db, row, opts \\ []) do
    sql = """
    INSERT INTO artifacts(
      id, delivery_key, media_type, mode, state, capture_status, incomplete_reason,
      bytes, items, sha256, charged_bytes, reserved_data, limit_reason
    ) VALUES (?1, ?2, ?3, ?4, 'open', NULL, NULL, 0, 0, NULL, ?5, ?6, NULL)
    """

    params = [
      row.id,
      row.delivery_key,
      row.media_type,
      Atom.to_string(row.mode),
      row.charged_bytes,
      row.reserved_data
    ]

    transaction_execute(db, sql, params, :inserted, opts)
  end

  @doc "Loads a capture by its stable delivery key."
  @spec by_delivery(db(), String.t()) :: {:ok, row() | nil} | {:error, term()}
  def by_delivery(db, delivery_key) do
    query_one(db, "#{select_columns()} WHERE delivery_key = ?1", [delivery_key])
  end

  @doc "Loads an artifact by random scoped identifier."
  @spec get(db(), String.t()) :: {:ok, row() | nil} | {:error, term()}
  def get(db, id), do: query_one(db, "#{select_columns()} WHERE id = ?1", [id])

  @doc "Loads every interrupted open manifest for startup recovery."
  @spec open_captures(db()) :: {:ok, [row()]} | {:error, term()}
  def open_captures(db) do
    with {:ok, rows} <- SQLite.query(db, "#{select_columns()} WHERE state = 'open' ORDER BY id") do
      {:ok, Enum.map(rows, &decode_row/1)}
    end
  end

  @doc "Durably records progress and every newly sealed full block in one mutation."
  @spec update_progress(
          db(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [Integrity.block_row()],
          keyword()
        ) :: mutation(:updated)
  def update_progress(db, id, bytes, items, charged_bytes, rows, opts \\ []) do
    SQLite.transaction(db, fn ->
      with :ok <-
             SQLite.execute(
               db,
               """
               UPDATE artifacts SET bytes = ?2, items = ?3, charged_bytes = ?4
               WHERE id = ?1 AND state = 'open'
               """,
               [id, bytes, items, charged_bytes]
             ),
           :ok <- require_one_change(db),
           :ok <- validate_progress_rows(rows, bytes, items),
           :ok <- insert_block_rows(db, id, rows) do
        {:ok, :updated}
      end
    end, opts)
  end

  @doc "Marks an open capture so it can no longer claim complete status."
  @spec mark_limit(db(), String.t(), atom(), keyword()) :: mutation(:marked)
  def mark_limit(db, id, reason, opts \\ []) when is_atom(reason) do
    sql = "UPDATE artifacts SET limit_reason = ?2 WHERE id = ?1 AND state = 'open'"
    transaction_execute(db, sql, [id, Atom.to_string(reason)], :marked, opts)
  end

  @doc "Atomically seals clean integrity coverage, terminal status, and its delivery pin."
  @spec finish(
          db(),
          String.t(),
          :complete | {:incomplete, atom()},
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          String.t(),
          [Integrity.block_row()],
          keyword()
        ) :: mutation(:finished)
  def finish(
        db,
        id,
        capture,
        bytes,
        items,
        sha256,
        charged_bytes,
        delivery_key,
        rows,
        opts \\ []
      ) do
    SQLite.transaction(db, fn ->
      with :ok <- validate_terminal_rows(rows, bytes, items),
           :ok <- insert_block_rows(db, id, rows),
           :ok <- require_exact_coverage(db, id, bytes, items),
           :ok <-
             terminalize(
               db,
               id,
               capture,
               bytes,
               items,
               sha256,
               charged_bytes,
               delivery_key
             ) do
        {:ok, :finished}
      end
    end, opts)
  end

  @doc "Atomically replaces provisional rows with rebuilt prefix coverage and terminalizes it."
  @spec finish_recovered(
          db(),
          String.t(),
          :complete | {:incomplete, atom()},
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          String.t(),
          [Integrity.block_row()],
          keyword()
        ) :: mutation(:finished)
  def finish_recovered(
        db,
        id,
        capture,
        bytes,
        items,
        sha256,
        charged_bytes,
        delivery_key,
        rows,
        opts \\ []
      ) do
    SQLite.transaction(db, fn ->
      with :ok <-
             SQLite.execute(
               db,
               "DELETE FROM artifact_blocks WHERE artifact_id = ?1",
               [id]
             ),
           :ok <- validate_terminal_rows(rows, bytes, items),
           :ok <- insert_block_rows(db, id, rows),
           :ok <- require_exact_coverage(db, id, bytes, items),
           :ok <-
             terminalize(
               db,
               id,
               capture,
               bytes,
               items,
               sha256,
               charged_bytes,
               delivery_key
             ) do
        {:ok, :finished}
      end
    end, opts)
  end

  @doc "Returns every requested trusted block hash in block order or reports corruption."
  @spec block_hashes(
          db(),
          String.t(),
          Integrity.file_kind(),
          [non_neg_integer()]
        ) :: {:ok, [{non_neg_integer(), binary()}]} | {:error, term()}
  def block_hashes(_db, _id, _kind, []), do: {:ok, []}

  def block_hashes(db, id, kind, block_numbers) do
    requested = Enum.sort(Enum.uniq(block_numbers))
    placeholders = Enum.map_join(2..(length(requested) + 1), ",", &"?#{&1}")
    sql = """
    SELECT block_number, sha256 FROM artifact_blocks
    WHERE artifact_id = ?1 AND file_kind = ?#{length(requested) + 2}
      AND block_number IN (#{placeholders})
    ORDER BY block_number
    """
    params = [id | requested] ++ [encode_file_kind(kind)]

    case SQLite.query(db, sql, params) do
      {:ok, rows} -> verify_hash_rows(rows, requested)
      {:error, _reason} = error -> error
    end
  end

  @doc "Replaces one snapshot/task pin set atomically and optionally transfers delivery pins."
  @spec replace_pin_set(db(), String.t(), :snapshot | :task, [String.t()], boolean(), pos_integer(), pos_integer(), keyword()) ::
          mutation(:replaced)
  def replace_pin_set(db, pin_key, kind, artifact_ids, transfer_delivery, max_sets, max_refs, opts \\ []) do
    SQLite.transaction(db, fn ->
      with {:ok, [[set_count]]} <-
             SQLite.query(db, "SELECT COUNT(*) FROM pin_sets WHERE kind != 'delivery'"),
           {:ok, [[existing_set]]} <-
             SQLite.query(
               db,
               "SELECT COUNT(*) FROM pin_sets WHERE pin_key = ?1 AND kind != 'delivery'",
               [pin_key]
             ),
           :ok <- ensure_pin_set_limit(set_count, existing_set, max_sets),
           {:ok, [[ref_count]]} <- SQLite.query(db, "SELECT COUNT(*) FROM pin_refs"),
           {:ok, [[old_refs]]} <-
             SQLite.query(db, "SELECT COUNT(*) FROM pin_refs WHERE pin_key = ?1", [pin_key]),
           {:ok, delivery_refs} <-
             delivery_ref_count(db, artifact_ids, transfer_delivery),
           :ok <-
             ensure_pin_ref_limit(
               ref_count,
               old_refs,
               delivery_refs,
               length(artifact_ids),
               max_refs
             ),
           :ok <- maybe_transfer_delivery(db, artifact_ids, transfer_delivery),
           :ok <- SQLite.execute(db, "DELETE FROM pin_sets WHERE pin_key = ?1", [pin_key]),
           :ok <-
             SQLite.execute(db, "INSERT INTO pin_sets(pin_key, kind) VALUES (?1, ?2)", [
               pin_key,
               Atom.to_string(kind)
             ]),
           :ok <- insert_pin_refs(db, pin_key, kind, artifact_ids) do
        {:ok, :replaced}
      else
        {:error, _reason} = error -> error
      end
    end, opts)
  end

  @doc "Idempotently releases one complete pin set."
  @spec release_pin_set(db(), String.t(), keyword()) :: mutation(:released)
  def release_pin_set(db, pin_key, opts \\ []) do
    transaction_execute(db, "DELETE FROM pin_sets WHERE pin_key = ?1", [pin_key], :released, opts,
      require_change?: false
    )
  end

  @doc "Lists terminal artifacts with no pin, bounded by the session artifact limit."
  @spec unreferenced(db(), pos_integer()) :: {:ok, [row()]} | {:error, term()}
  def unreferenced(db, limit) do
    sql = """
    #{select_columns("a")}
    LEFT JOIN pin_refs p ON p.artifact_id = a.id
    WHERE a.state = 'terminal' AND p.artifact_id IS NULL
    ORDER BY a.id LIMIT ?1
    """

    with {:ok, rows} <- SQLite.query(db, sql, [limit]) do
      {:ok, Enum.map(rows, &decode_row/1)}
    end
  end

  @doc "Deletes one still-unpinned artifact and records a bounded expiration tombstone."
  @spec expire_unreferenced(db(), String.t(), pos_integer(), keyword()) :: mutation(:expired)
  def expire_unreferenced(db, id, max_tombstones, opts \\ []) do
    SQLite.transaction(db, fn ->
      with :ok <-
             SQLite.execute(
               db,
               "DELETE FROM artifacts WHERE id = ?1 AND NOT EXISTS (SELECT 1 FROM pin_refs WHERE artifact_id = ?1)",
               [id]
             ),
           :ok <- require_one_change(db),
           :ok <-
             SQLite.execute(
               db,
               "INSERT INTO tombstones(artifact_id) VALUES (?1) ON CONFLICT(artifact_id) DO NOTHING",
               [id]
             ),
           :ok <- trim_tombstones(db, max_tombstones) do
        {:ok, :expired}
      end
    end, opts)
  end

  @doc "Returns whether explicit cleanup previously expired an identifier."
  @spec expired?(db(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def expired?(db, id) do
    case SQLite.query(db, "SELECT 1 FROM tombstones WHERE artifact_id = ?1", [id]) do
      {:ok, [[1]]} -> {:ok, true}
      {:ok, []} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns whether any pin still protects an artifact."
  @spec pinned?(db(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def pinned?(db, id) do
    case SQLite.query(db, "SELECT 1 FROM pin_refs WHERE artifact_id = ?1 LIMIT 1", [id]) do
      {:ok, [[1]]} -> {:ok, true}
      {:ok, []} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec open_validated(db()) :: {:ok, db()} | {:error, term()}
  defp open_validated(db) do
    case validate_schema(db) do
      {:ok, validated} ->
        case install_schema(validated) do
          :ok -> {:ok, validated}
          {:error, reason} ->
            _ = close(validated)
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec install_schema(db()) :: :ok | {:error, term()}
  defp install_schema(db) do
    result =
      Enum.reduce_while(@schema, :ok, fn statement, :ok ->
        case SQLite.execute(db, statement) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        with :ok <- SQLite.checkpoint(db),
             :ok <- SQLite.ensure_private_files(db.path) do
          :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec validate_schema(db()) :: {:ok, db()} | {:error, term()}
  defp validate_schema(db) do
    case SQLite.query(db, "SELECT version FROM artifact_schema") do
      {:ok, [[2]]} ->
        {:ok, db}

      {:ok, rows} ->
        _ = close(db)
        {:error, {:unsupported_artifact_schema, rows}}

      {:error, reason} ->
        _ = close(db)
        {:error, reason}
    end
  end

  @spec select_columns() :: String.t()
  defp select_columns, do: select_columns(nil)

  @spec select_columns(String.t() | nil) :: String.t()
  defp select_columns(nil) do
    """
    SELECT id, delivery_key, media_type, mode, state, capture_status,
           incomplete_reason, bytes, items, sha256, charged_bytes, reserved_data, limit_reason
    FROM artifacts
    """
  end

  defp select_columns(_alias_name) do
    """
    SELECT a.id, a.delivery_key, a.media_type, a.mode, a.state, a.capture_status,
           a.incomplete_reason, a.bytes, a.items, a.sha256, a.charged_bytes,
           a.reserved_data, a.limit_reason
    FROM artifacts a
    """
  end

  @spec query_one(db(), String.t(), [term()]) :: {:ok, row() | nil} | {:error, term()}
  defp query_one(db, sql, params) do
    case SQLite.query(db, sql, params) do
      {:ok, [row]} -> {:ok, decode_row(row)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec transaction_execute(db(), String.t(), [term()], value, keyword()) :: mutation(value)
        when value: term()
  defp transaction_execute(db, sql, params, value, opts) do
    transaction_execute(db, sql, params, value, opts, require_change?: true)
  end

  @spec transaction_execute(db(), String.t(), [term()], value, keyword(), keyword()) :: mutation(value)
        when value: term()
  defp transaction_execute(db, sql, params, value, opts, execute_opts) do
    SQLite.transaction(db, fn ->
      with :ok <- SQLite.execute(db, sql, params),
           :ok <- maybe_require_change(db, Keyword.fetch!(execute_opts, :require_change?)) do
        {:ok, value}
      end
    end, opts)
  end

  @spec maybe_require_change(db(), boolean()) :: :ok | {:error, term()}
  defp maybe_require_change(_db, false), do: :ok
  defp maybe_require_change(db, true), do: require_one_change(db)

  @spec require_one_change(db()) :: :ok | {:error, term()}
  defp require_one_change(db) do
    case SQLite.query(db, "SELECT changes()") do
      {:ok, [[1]]} -> :ok
      {:ok, [[_changes]]} -> {:error, :artifact_row_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_progress_rows(
          [Integrity.block_row()],
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok | {:error, :invalid_integrity_rows}
  defp validate_progress_rows(rows, bytes, items) do
    index_bytes = items * 8

    if Enum.all?(rows, &valid_progress_row?(&1, bytes, index_bytes)),
      do: :ok,
      else: {:error, :invalid_integrity_rows}
  end

  @spec valid_progress_row?(
          Integrity.block_row(),
          non_neg_integer(),
          non_neg_integer()
        ) :: boolean()
  defp valid_progress_row?({:blob, number, digest}, bytes, _index_bytes),
    do: valid_full_row?(number, digest, bytes)

  defp valid_progress_row?({:index, number, digest}, _bytes, index_bytes),
    do: valid_full_row?(number, digest, index_bytes)

  defp valid_progress_row?(_row, _bytes, _index_bytes), do: false

  @spec valid_full_row?(term(), term(), non_neg_integer()) :: boolean()
  defp valid_full_row?(number, digest, total) do
    is_integer(number) and number >= 0 and is_binary(digest) and byte_size(digest) == 32 and
      (number + 1) * Limits.integrity_block_bytes() <= total
  end

  @spec validate_terminal_rows(
          [Integrity.block_row()],
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok | {:error, :invalid_integrity_rows}
  defp validate_terminal_rows(rows, bytes, items) do
    blob_blocks = block_count(bytes)
    index_blocks = block_count(items * 8)

    if Enum.all?(rows, &valid_terminal_row?(&1, blob_blocks, index_blocks)),
      do: :ok,
      else: {:error, :invalid_integrity_rows}
  end

  @spec valid_terminal_row?(
          Integrity.block_row(),
          non_neg_integer(),
          non_neg_integer()
        ) :: boolean()
  defp valid_terminal_row?({:blob, number, digest}, blob_blocks, _index_blocks),
    do: valid_bounded_row?(number, digest, blob_blocks)

  defp valid_terminal_row?({:index, number, digest}, _blob_blocks, index_blocks),
    do: valid_bounded_row?(number, digest, index_blocks)

  defp valid_terminal_row?(_row, _blob_blocks, _index_blocks), do: false

  @spec valid_bounded_row?(term(), term(), non_neg_integer()) :: boolean()
  defp valid_bounded_row?(number, digest, block_count) do
    is_integer(number) and number >= 0 and number < block_count and is_binary(digest) and
      byte_size(digest) == 32
  end

  @spec insert_block_rows(db(), String.t(), [Integrity.block_row()]) :: :ok | {:error, term()}
  defp insert_block_rows(db, artifact_id, rows) do
    Enum.reduce_while(rows, :ok, fn {kind, number, digest}, :ok ->
      result =
        SQLite.execute(
          db,
          """
          INSERT INTO artifact_blocks(artifact_id, file_kind, block_number, sha256)
          VALUES (?1, ?2, ?3, ?4)
          """,
          [artifact_id, encode_file_kind(kind), number, {:blob, digest}]
        )

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec require_exact_coverage(
          db(),
          String.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok | {:error, :artifact_corrupt | term()}
  defp require_exact_coverage(db, artifact_id, bytes, items) do
    with :ok <- require_file_coverage(db, artifact_id, :blob, block_count(bytes)),
         :ok <- require_file_coverage(db, artifact_id, :index, block_count(items * 8)) do
      :ok
    end
  end

  @spec require_file_coverage(
          db(),
          String.t(),
          Integrity.file_kind(),
          non_neg_integer()
        ) :: :ok | {:error, :artifact_corrupt | term()}
  defp require_file_coverage(db, artifact_id, kind, expected_count) do
    result =
      SQLite.query(
        db,
        """
        SELECT COUNT(*), MIN(block_number), MAX(block_number)
        FROM artifact_blocks WHERE artifact_id = ?1 AND file_kind = ?2
        """,
        [artifact_id, encode_file_kind(kind)]
      )

    coverage_result(result, expected_count)
  end

  @spec coverage_result(
          {:ok, [[term()]]} | {:error, term()},
          non_neg_integer()
        ) :: :ok | {:error, :artifact_corrupt | term()}
  defp coverage_result({:ok, [[0, nil, nil]]}, 0), do: :ok
  defp coverage_result({:ok, [[count, 0, maximum]]}, count) when maximum == count - 1, do: :ok
  defp coverage_result({:ok, _rows}, _expected), do: {:error, :artifact_corrupt}
  defp coverage_result({:error, _reason} = error, _expected), do: error

  @spec terminalize(
          db(),
          String.t(),
          :complete | {:incomplete, atom()},
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          String.t()
        ) :: :ok | {:error, term()}
  defp terminalize(
         db,
         id,
         capture,
         bytes,
         items,
         sha256,
         charged_bytes,
         delivery_key
       ) do
    {status, reason} = encode_capture(capture)

    with :ok <-
           SQLite.execute(
             db,
             """
             UPDATE artifacts
             SET state = 'terminal', capture_status = ?2, incomplete_reason = ?3,
                 bytes = ?4, items = ?5, sha256 = ?6, charged_bytes = ?7,
                 limit_reason = NULL
             WHERE id = ?1 AND state = 'open'
             """,
             [id, status, reason, bytes, items, sha256, charged_bytes]
           ),
         :ok <- require_one_change(db),
         :ok <-
           SQLite.execute(
             db,
             "INSERT INTO pin_sets(pin_key, kind) VALUES (?1, 'delivery') ON CONFLICT(pin_key) DO NOTHING",
             [delivery_key]
           ),
         :ok <-
           SQLite.execute(
             db,
             "INSERT INTO pin_refs(pin_key, artifact_id, pin_kind) VALUES (?1, ?2, 'delivery') ON CONFLICT(pin_key, artifact_id) DO NOTHING",
             [delivery_key, id]
           ) do
      :ok
    end
  end

  @spec block_count(non_neg_integer()) :: non_neg_integer()
  defp block_count(0), do: 0

  defp block_count(bytes),
    do: div(bytes + Limits.integrity_block_bytes() - 1, Limits.integrity_block_bytes())

  @spec verify_hash_rows([[term()]], [non_neg_integer()]) ::
          {:ok, [{non_neg_integer(), binary()}]} | {:error, :artifact_corrupt}
  defp verify_hash_rows(rows, requested) do
    valid =
      Enum.all?(rows, fn
        [number, digest] -> is_integer(number) and is_binary(digest) and byte_size(digest) == 32
        _other -> false
      end)

    numbers = Enum.map(rows, fn [number, _digest] -> number end)

    if valid and numbers == requested,
      do: {:ok, Enum.map(rows, fn [number, digest] -> {number, digest} end)},
      else: {:error, :artifact_corrupt}
  end

  @spec encode_file_kind(Integrity.file_kind()) :: 0 | 1
  defp encode_file_kind(:blob), do: 0
  defp encode_file_kind(:index), do: 1

  @spec encode_capture(:complete | {:incomplete, atom()}) :: {String.t(), String.t() | nil}
  defp encode_capture(:complete), do: {"complete", nil}
  defp encode_capture({:incomplete, reason}), do: {"incomplete", Atom.to_string(reason)}

  @spec decode_row([term()]) :: row()
  defp decode_row([
         id,
         delivery_key,
         media_type,
         mode,
         state,
         capture_status,
         incomplete_reason,
         bytes,
         items,
         sha256,
         charged_bytes,
         reserved_data,
         limit_reason
       ]) do
    %{
      id: id,
      delivery_key: delivery_key,
      media_type: media_type,
      mode: decode_mode(mode),
      state: decode_state(state),
      capture: decode_capture(capture_status, incomplete_reason),
      bytes: bytes,
      items: items,
      sha256: sha256,
      charged_bytes: charged_bytes,
      reserved_data: reserved_data,
      limit_reason: decode_optional_atom(limit_reason)
    }
  end

  @spec decode_mode(String.t()) :: :bytes | :items
  defp decode_mode("bytes"), do: :bytes
  defp decode_mode("items"), do: :items

  @spec decode_state(String.t()) :: :open | :terminal
  defp decode_state("open"), do: :open
  defp decode_state("terminal"), do: :terminal

  @spec decode_capture(String.t() | nil, String.t() | nil) ::
          :complete | {:incomplete, atom()} | nil
  defp decode_capture(nil, nil), do: nil
  defp decode_capture("complete", nil), do: :complete
  defp decode_capture("incomplete", reason), do: {:incomplete, decode_reason(reason)}

  @spec decode_optional_atom(String.t() | nil) :: atom() | nil
  defp decode_optional_atom(nil), do: nil
  defp decode_optional_atom(reason), do: decode_reason(reason)

  @spec decode_reason(String.t()) :: atom()
  defp decode_reason("capture_byte_limit"), do: :capture_byte_limit
  defp decode_reason("session_disk_quota"), do: :session_disk_quota
  defp decode_reason("root_disk_quota"), do: :root_disk_quota
  defp decode_reason("session_item_quota"), do: :session_item_quota
  defp decode_reason("root_item_quota"), do: :root_item_quota
  defp decode_reason("disk_full"), do: :disk_full
  defp decode_reason("interrupted"), do: :interrupted
  defp decode_reason("source_changed"), do: :source_changed
  defp decode_reason("legacy_unclassified"), do: :legacy_unclassified
  defp decode_reason("timeout"), do: :timeout
  defp decode_reason("capture_failed"), do: :capture_failed

  @spec insert_pin_refs(db(), String.t(), :snapshot | :task, [String.t()]) :: :ok | {:error, term()}
  defp insert_pin_refs(db, pin_key, kind, artifact_ids) do
    Enum.reduce_while(artifact_ids, :ok, fn artifact_id, :ok ->
      case SQLite.execute(
             db,
             "INSERT INTO pin_refs(pin_key, artifact_id, pin_kind) VALUES (?1, ?2, ?3)",
             [pin_key, artifact_id, Atom.to_string(kind)]
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec ensure_pin_set_limit(non_neg_integer(), 0 | 1, pos_integer()) ::
          :ok | {:error, :pin_set_limit}
  defp ensure_pin_set_limit(set_count, existing_set, max_sets) do
    if set_count - existing_set + 1 <= max_sets,
      do: :ok,
      else: {:error, :pin_set_limit}
  end

  @spec ensure_pin_ref_limit(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, :pin_ref_limit}
  defp ensure_pin_ref_limit(ref_count, old_refs, delivery_refs, new_refs, max_refs) do
    if ref_count - old_refs - delivery_refs + new_refs <= max_refs,
      do: :ok,
      else: {:error, :pin_ref_limit}
  end

  @spec delivery_ref_count(db(), [String.t()], boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp delivery_ref_count(_db, _artifact_ids, false), do: {:ok, 0}
  defp delivery_ref_count(_db, [], true), do: {:ok, 0}

  defp delivery_ref_count(db, artifact_ids, true) do
    placeholders = Enum.map_join(1..length(artifact_ids), ",", &"?#{&1}")

    case SQLite.query(
           db,
           "SELECT COUNT(*) FROM pin_refs WHERE pin_kind = 'delivery' AND artifact_id IN (#{placeholders})",
           artifact_ids
         ) do
      {:ok, [[count]]} -> {:ok, count}
      {:error, _reason} = error -> error
    end
  end

  @spec maybe_transfer_delivery(db(), [String.t()], boolean()) :: :ok | {:error, term()}
  defp maybe_transfer_delivery(_db, _artifact_ids, false), do: :ok
  defp maybe_transfer_delivery(_db, [], true), do: :ok

  defp maybe_transfer_delivery(db, artifact_ids, true) do
    placeholders = Enum.map_join(1..length(artifact_ids), ",", &"?#{&1}")

    with :ok <-
           SQLite.execute(
             db,
             "DELETE FROM pin_refs WHERE pin_kind = 'delivery' AND artifact_id IN (#{placeholders})",
             artifact_ids
           ) do
      SQLite.execute(
        db,
        "DELETE FROM pin_sets WHERE kind = 'delivery' AND NOT EXISTS (SELECT 1 FROM pin_refs WHERE pin_refs.pin_key = pin_sets.pin_key)"
      )
    end
  end


  @spec trim_tombstones(db(), pos_integer()) :: :ok | {:error, term()}
  defp trim_tombstones(db, max_tombstones) do
    SQLite.execute(
      db,
      """
      DELETE FROM tombstones
      WHERE sequence IN (
        SELECT sequence FROM tombstones ORDER BY sequence ASC
        LIMIT MAX(0, (SELECT COUNT(*) FROM tombstones) - ?1)
      )
      """,
      [max_tombstones]
    )
  end
end
