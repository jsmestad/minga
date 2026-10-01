defmodule MingaAgent.ArtifactQuota.State do
  @moduledoc "State owner and admission transitions for the aggregate artifact quota."

  alias MingaAgent.ArtifactQuota.Ledger
  alias MingaAgent.ArtifactQuota.Usage
  alias MingaAgent.ArtifactStorage.FaultInjector
  alias MingaAgent.ArtifactStorage.Files
  alias MingaAgent.ArtifactStore.Limits

  @type storage :: :cold | {:open, Ledger.db()}
  @type t :: %__MODULE__{
          root: String.t(),
          storage: storage(),
          limits: Limits.t(),
          rows: %{optional(String.t()) => Ledger.namespace_row()},
          total_bytes: non_neg_integer(),
          total_items: non_neg_integer(),
          total_artifacts: non_neg_integer(),
          total_open_captures: non_neg_integer(),
          blocked: boolean(),
          fault_injector: FaultInjector.t()
        }

  @enforce_keys [
    :root,
    :storage,
    :limits,
    :rows,
    :total_bytes,
    :total_items,
    :total_artifacts,
    :total_open_captures,
    :blocked,
    :fault_injector
  ]
  defstruct @enforce_keys

  @doc "Builds cold quota state without touching the filesystem or taking the root lock."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    root = Keyword.get(opts, :root)

    with true <- is_binary(root) and String.trim(root) != "",
         {:ok, limits} <- normalize_limits(Keyword.get(opts, :limits)),
         true <- limits.root_bytes >= Limits.sqlite_envelope_bytes() do
      {:ok,
       %__MODULE__{
         root: Path.expand(root),
         storage: :cold,
         limits: limits,
         rows: %{},
         total_bytes: 0,
         total_items: 0,
         total_artifacts: 0,
         total_open_captures: 0,
         blocked: false,
         fault_injector: Keyword.get(opts, :fault_injector)
       }}
    else
      false -> {:error, :invalid_quota_root}
      {:error, _reason} = error -> error
    end
  end

  @spec normalize_limits(term()) :: {:ok, Limits.t()} | {:error, :invalid_limits}
  defp normalize_limits(%Limits{} = limits), do: {:ok, limits}
  defp normalize_limits(values), do: Limits.new(values || %{})

  @doc "Closes the durable ledger when this cold-started actor acquired it."
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{storage: :cold}), do: :ok

  def close(%__MODULE__{storage: {:open, db}}), do: Ledger.close(db)

  @doc "Reserves one namespace envelope before namespace files are created."
  @spec register_namespace(t(), String.t(), String.t(), keyword() | map()) ::
          {{:ok, Limits.t()} | {:error, term()}, t()}
  def register_namespace(%__MODULE__{} = state, root, namespace, overrides) do
    with :ok <- validate_root(state, root),
         :ok <- validate_namespace(namespace),
         {:ok, effective_limits} <- Limits.restrict(state.limits, overrides),
         {:ok, opened} <- ensure_open(state) do
      register_valid_namespace(opened, namespace, effective_limits)
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Reports whether a valid namespace has a durable quota row."
  @spec namespace_registered(t(), String.t(), String.t()) ::
          {{:ok, boolean()} | {:error, term()}, t()}
  def namespace_registered(%__MODULE__{} = state, root, namespace) do
    with :ok <- validate_root(state, root),
         :ok <- validate_namespace(namespace),
         {:ok, opened} <- ensure_open(state) do
      {{:ok, Map.has_key?(opened.rows, namespace)}, opened}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Reserves artifact/open counts and fixed or expected bytes before capture files exist."
  @spec reserve_capture(t(), String.t(), non_neg_integer()) ::
          {:ok | {:error, term()}, t()}
  def reserve_capture(%__MODULE__{storage: :cold} = state, _namespace, _bytes),
    do: {{:error, :storage_unavailable}, state}

  def reserve_capture(%__MODULE__{blocked: true} = state, _namespace, _bytes),
    do: {{:error, :storage_unavailable}, state}

  def reserve_capture(%__MODULE__{} = state, namespace, bytes)
      when is_integer(bytes) and bytes >= 0 do
    with {:ok, row} <- fetch_row(state, namespace),
         :ok <- check_capture_counts(state, row),
         :ok <- check_bytes(state, row, bytes) do
      mutation = Ledger.reserve(opened_db(state), namespace, bytes, 0, 1, 1, fault_opts(state))
      apply_reservation(state, row, bytes, 0, 1, 1, mutation)
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Reserves appended data and index offsets before either file write."
  @spec reserve_append(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok | {:error, term()}, t()}
  def reserve_append(%__MODULE__{storage: :cold} = state, _namespace, _bytes, _items),
    do: {{:error, :storage_unavailable}, state}

  def reserve_append(%__MODULE__{blocked: true} = state, _namespace, _bytes, _items),
    do: {{:error, :storage_unavailable}, state}

  def reserve_append(%__MODULE__{} = state, namespace, bytes, items)
      when is_integer(bytes) and bytes >= 0 and is_integer(items) and items >= 0 do
    with {:ok, row} <- fetch_row(state, namespace),
         :ok <- check_bytes(state, row, bytes),
         :ok <- check_items(state, row, items) do
      mutation =
        Ledger.reserve(opened_db(state), namespace, bytes, items, 0, 0, fault_opts(state))

      apply_reservation(state, row, bytes, items, 0, 0, mutation)
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Releases only the open-capture count after a terminal manifest is durable."
  @spec finish_capture(t(), String.t()) :: {:ok | {:error, term()}, t()}
  def finish_capture(%__MODULE__{storage: :cold} = state, _namespace),
    do: {{:error, :storage_unavailable}, state}

  def finish_capture(%__MODULE__{blocked: true} = state, _namespace),
    do: {{:error, :storage_unavailable}, state}

  def finish_capture(%__MODULE__{} = state, namespace) do
    with {:ok, row} <- fetch_row(state, namespace),
         true <- row.open_captures > 0 do
      mutation = Ledger.finish_capture(opened_db(state), namespace, fault_opts(state))
      apply_finish(state, row, mutation)
    else
      false -> {{:error, :invalid_open_capture_release}, state}
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Releases every reservation for one durably canceled open capture."
  @spec cancel_capture(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok | {:error, term()}, t()}
  def cancel_capture(%__MODULE__{storage: :cold} = state, _namespace, _bytes, _items),
    do: {{:error, :storage_unavailable}, state}

  def cancel_capture(%__MODULE__{blocked: true} = state, _namespace, _bytes, _items),
    do: {{:error, :storage_unavailable}, state}

  def cancel_capture(%__MODULE__{} = state, namespace, bytes, items)
      when is_integer(bytes) and bytes >= 0 and is_integer(items) and items >= 0 do
    with {:ok, row} <- fetch_row(state, namespace),
         true <-
           row.charged_bytes >= bytes and row.items >= items and row.artifacts > 0 and
             row.open_captures > 0 do
      mutation =
        Ledger.cancel_capture(opened_db(state), namespace, bytes, items, fault_opts(state))

      apply_capture_cancel(state, row, bytes, items, mutation)
    else
      false -> {{:error, :invalid_quota_release}, state}
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Releases unused conservative append reservations while retaining the artifact."
  @spec release_reservation(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok | {:error, term()}, t()}
  def release_reservation(%__MODULE__{storage: :cold} = state, _namespace, _bytes, _items),
    do: {{:error, :storage_unavailable}, state}

  def release_reservation(%__MODULE__{blocked: true} = state, _namespace, _bytes, _items),
    do: {{:error, :storage_unavailable}, state}

  def release_reservation(%__MODULE__{} = state, namespace, bytes, items)
      when is_integer(bytes) and bytes >= 0 and is_integer(items) and items >= 0 do
    with {:ok, row} <- fetch_row(state, namespace),
         true <- row.charged_bytes >= bytes and row.items >= items do
      mutation =
        Ledger.release_reservation(opened_db(state), namespace, bytes, items, fault_opts(state))

      apply_reservation_release(state, row, bytes, items, mutation)
    else
      false -> {{:error, :invalid_quota_release}, state}
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Releases a deleted artifact's conservative bytes, items, and count."
  @spec release_artifact(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok | {:error, term()}, t()}
  def release_artifact(%__MODULE__{storage: :cold} = state, _namespace, _bytes, _items),
    do: {{:error, :storage_unavailable}, state}

  def release_artifact(%__MODULE__{blocked: true} = state, _namespace, _bytes, _items),
    do: {{:error, :storage_unavailable}, state}

  def release_artifact(%__MODULE__{} = state, namespace, bytes, items)
      when is_integer(bytes) and bytes >= 0 and is_integer(items) and items >= 0 do
    with {:ok, row} <- fetch_row(state, namespace),
         true <- row.artifacts > 0 and row.charged_bytes >= bytes and row.items >= items do
      mutation = Ledger.release(opened_db(state), namespace, bytes, items, 1, fault_opts(state))
      apply_release(state, row, bytes, items, mutation)
    else
      false -> {{:error, :invalid_quota_release}, state}
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Reconciles aggregate counters to one manifest's exact durable accounting."
  @spec reconcile_namespace(
          t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok | {:error, term()}, t()}
  def reconcile_namespace(
        %__MODULE__{storage: :cold} = state,
        _namespace,
        _bytes,
        _items,
        _artifacts,
        _open
      ),
      do: {{:error, :storage_unavailable}, state}

  def reconcile_namespace(
        %__MODULE__{blocked: true} = state,
        _namespace,
        _bytes,
        _items,
        _artifacts,
        _open
      ),
      do: {{:error, :storage_unavailable}, state}

  def reconcile_namespace(state, namespace, artifact_bytes, items, artifacts, open)
      when is_integer(artifact_bytes) and artifact_bytes >= 0 and is_integer(items) and
             items >= 0 and is_integer(artifacts) and artifacts >= 0 and is_integer(open) and
             open >= 0 do
    with {:ok, row} <- fetch_row(state, namespace),
         charged_bytes = Limits.sqlite_envelope_bytes() + artifact_bytes,
         :ok <- validate_reconciliation(state, row, charged_bytes, items, artifacts, open) do
      mutation =
        Ledger.reconcile(
          opened_db(state),
          namespace,
          charged_bytes,
          items,
          artifacts,
          open,
          fault_opts(state)
        )

      apply_reconciliation(
        state,
        row,
        charged_bytes,
        items,
        artifacts,
        open,
        mutation
      )
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Decharges one explicitly deleted record after all owned files are durably absent."
  @spec delete_namespace(t(), String.t()) :: {:ok | {:error, term()}, t()}
  def delete_namespace(%__MODULE__{storage: :cold} = state, _namespace),
    do: {{:error, :storage_unavailable}, state}

  def delete_namespace(%__MODULE__{blocked: true} = state, _namespace),
    do: {{:error, :storage_unavailable}, state}

  def delete_namespace(%__MODULE__{} = state, namespace) do
    case Map.fetch(state.rows, namespace) do
      :error ->
        {:ok, state}

      {:ok, %{open_captures: 0} = row} ->
        case File.lstat(Path.join([state.root, "namespaces", namespace])) do
          {:error, :enoent} ->
            mutation = Ledger.delete_namespace(opened_db(state), namespace, fault_opts(state))
            apply_namespace_release(state, row, mutation)

          {:ok, _exists} ->
            {{:error, :namespace_not_empty}, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      {:ok, _row} ->
        {{:error, :record_in_use}, state}
    end
  end

  @doc "Returns aggregate counters without exposing namespace identities."
  @spec usage(t()) :: Usage.t()
  def usage(%__MODULE__{} = state) do
    Usage.new(
      state.total_bytes,
      state.total_items,
      state.total_artifacts,
      state.total_open_captures,
      map_size(state.rows),
      state.limits.root_bytes
    )
  end

  @spec validate_root(t(), term()) :: :ok | {:error, :invalid_artifact_root}
  defp validate_root(%__MODULE__{root: root}, candidate) when is_binary(candidate) do
    if String.trim(candidate) != "" and Path.expand(candidate) == root,
      do: :ok,
      else: {:error, :invalid_artifact_root}
  end

  defp validate_root(_state, _candidate), do: {:error, :invalid_artifact_root}

  @spec validate_namespace(term()) :: :ok | {:error, :invalid_namespace}
  defp validate_namespace(namespace) do
    if valid_namespace?(namespace), do: :ok, else: {:error, :invalid_namespace}
  end

  @spec ensure_open(t()) :: {:ok, t()} | {:error, term()}
  defp ensure_open(%__MODULE__{blocked: true}), do: {:error, :storage_unavailable}
  defp ensure_open(%__MODULE__{storage: {:open, _db}} = state), do: {:ok, state}

  defp ensure_open(%__MODULE__{storage: :cold} = state) do
    ledger_path = Path.join(state.root, "artifact_quota.sqlite3")

    with :ok <- Files.ensure_private_directory(state.root),
         :ok <- validate_ledger_presence(state.root, ledger_path),
         {:ok, db} <- Ledger.open(ledger_path) do
      load_opened(state, db)
    end
  end

  @spec validate_ledger_presence(String.t(), String.t()) :: :ok | {:error, term()}
  defp validate_ledger_presence(root, ledger_path) do
    case File.lstat(ledger_path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_artifact_file, ledger_path, type}}

      {:error, :enoent} ->
        reject_orphaned_namespaces(Path.join(root, "namespaces"))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reject_orphaned_namespaces(String.t()) :: :ok | {:error, term()}
  defp reject_orphaned_namespaces(namespaces_path) do
    case File.lstat(namespaces_path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        {:error, :missing_artifact_quota_ledger}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_artifact_directory, namespaces_path, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec load_opened(t(), Ledger.db()) :: {:ok, t()} | {:error, term()}
  defp load_opened(state, db) do
    case Ledger.all(db) do
      {:ok, rows} ->
        {:ok, from_rows(state, db, rows)}

      {:error, reason} ->
        _ = Ledger.close(db)
        {:error, reason}
    end
  end

  @spec from_rows(t(), Ledger.db(), [Ledger.namespace_row()]) :: t()
  defp from_rows(%__MODULE__{} = state, db, rows) do
    by_namespace = Map.new(rows, &{&1.namespace, &1})

    %__MODULE__{
      state
      | storage: {:open, db},
        rows: by_namespace,
        total_bytes:
          Limits.sqlite_envelope_bytes() + Enum.sum(Enum.map(rows, & &1.charged_bytes)),
        total_items: Enum.sum(Enum.map(rows, & &1.items)),
        total_artifacts: Enum.sum(Enum.map(rows, & &1.artifacts)),
        total_open_captures: Enum.sum(Enum.map(rows, & &1.open_captures))
    }
  end

  @spec register_valid_namespace(t(), String.t(), Limits.t()) ::
          {{:ok, Limits.t()} | {:error, term()}, t()}
  defp register_valid_namespace(state, namespace, limits) do
    case Map.fetch(state.rows, namespace) do
      {:ok, row} -> cap_existing_namespace(state, row, limits)
      :error -> admit_new_namespace(state, namespace, limits)
    end
  end

  @spec cap_existing_namespace(t(), Ledger.namespace_row(), Limits.t()) ::
          {{:ok, Limits.t()}, t()}
  defp cap_existing_namespace(%__MODULE__{} = state, row, limits) do
    capped =
      Limits.cap_session(
        limits,
        row.session_bytes,
        row.session_items,
        row.session_artifacts,
        row.session_open_captures
      )

    capped_row = %{
      row
      | session_bytes: capped.session_bytes,
        session_items: capped.session_items,
        session_artifacts: capped.session_artifacts,
        session_open_captures: capped.session_open_captures
    }

    next_state = %__MODULE__{state | rows: Map.put(state.rows, row.namespace, capped_row)}
    {{:ok, capped}, next_state}
  end

  @spec admit_new_namespace(t(), String.t(), Limits.t()) ::
          {{:ok, Limits.t()} | {:error, term()}, t()}
  defp admit_new_namespace(state, namespace, limits) do
    envelope = Limits.sqlite_envelope_bytes()

    with true <- map_size(state.rows) < state.limits.root_namespaces,
         true <- state.total_bytes + envelope <= state.limits.root_bytes do
      mutation = Ledger.insert_namespace(opened_db(state), namespace, limits, fault_opts(state))
      row = new_row(namespace, limits)
      apply_namespace_insert(state, row, limits, mutation)
    else
      false ->
        reason =
          if map_size(state.rows) >= state.limits.root_namespaces,
            do: :root_namespace_limit,
            else: :root_disk_quota

        {{:error, reason}, state}
    end
  end

  @spec check_capture_counts(t(), Ledger.namespace_row()) :: :ok | {:error, atom()}
  defp check_capture_counts(state, row) do
    checks = [
      {row.artifacts < row.session_artifacts, :session_artifact_limit},
      {state.total_artifacts < state.limits.root_artifacts, :root_artifact_limit},
      {row.open_captures < row.session_open_captures, :session_open_capture_limit},
      {state.total_open_captures < state.limits.root_open_captures, :root_open_capture_limit}
    ]

    first_failed_check(checks)
  end

  @spec check_bytes(t(), Ledger.namespace_row(), non_neg_integer()) :: :ok | {:error, atom()}
  defp check_bytes(_state, _row, 0), do: :ok

  defp check_bytes(state, row, bytes) do
    checks = [
      {row.charged_bytes + bytes <= row.session_bytes, :session_disk_quota},
      {state.total_bytes + bytes <= state.limits.root_bytes, :root_disk_quota}
    ]

    first_failed_check(checks)
  end

  @spec check_items(t(), Ledger.namespace_row(), non_neg_integer()) :: :ok | {:error, atom()}
  defp check_items(_state, _row, 0), do: :ok

  defp check_items(state, row, items) do
    checks = [
      {row.items + items <= row.session_items, :session_item_quota},
      {state.total_items + items <= state.limits.root_items, :root_item_quota}
    ]

    first_failed_check(checks)
  end

  @spec first_failed_check([{boolean(), atom()}]) :: :ok | {:error, atom()}
  defp first_failed_check(checks) do
    case Enum.find(checks, fn {allowed, _reason} -> not allowed end) do
      nil -> :ok
      {_allowed, reason} -> {:error, reason}
    end
  end

  @spec validate_reconciliation(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok | {:error, atom()}
  defp validate_reconciliation(_state, _row, _bytes, _items, artifacts, open) do
    if open <= artifacts, do: :ok, else: {:error, :invalid_quota_reconciliation}
  end

  @spec fetch_row(t(), String.t()) :: {:ok, Ledger.namespace_row()} | {:error, :unknown_namespace}
  defp fetch_row(state, namespace) do
    case Map.fetch(state.rows, namespace) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :unknown_namespace}
    end
  end

  @spec fault_opts(t()) :: keyword()
  defp fault_opts(state) do
    [
      before_checkpoint: fn ->
        FaultInjector.run(state.fault_injector, :before_quota_checkpoint)
      end
    ]
  end

  @spec apply_namespace_insert(
          t(),
          Ledger.namespace_row(),
          Limits.t(),
          Ledger.mutation(:inserted)
        ) ::
          {{:ok, Limits.t()} | {:error, term()}, t()}
  defp apply_namespace_insert(state, row, limits, {:ok, :inserted}) do
    {{:ok, limits}, put_new_row(state, row)}
  end

  defp apply_namespace_insert(
         state,
         row,
         _limits,
         {:error, {:checkpoint_failed, _}, {:committed, :inserted}}
       ) do
    {{:error, :storage_unavailable}, block(put_new_row(state, row))}
  end

  defp apply_namespace_insert(state, _row, _limits, {:error, reason}),
    do: {{:error, reason}, state}

  @spec apply_reservation(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer(),
          integer(),
          integer(),
          Ledger.mutation(:reserved)
        ) ::
          {:ok | {:error, term()}, t()}
  defp apply_reservation(state, row, bytes, items, artifacts, open, {:ok, :reserved}) do
    {:ok, reserve_counters(state, row, bytes, items, artifacts, open)}
  end

  defp apply_reservation(
         state,
         row,
         bytes,
         items,
         artifacts,
         open,
         {:error, {:checkpoint_failed, _}, {:committed, :reserved}}
       ) do
    updated = reserve_counters(state, row, bytes, items, artifacts, open)
    {{:error, :storage_unavailable}, block(updated)}
  end

  defp apply_reservation(state, _row, _bytes, _items, _artifacts, _open, {:error, reason}),
    do: {{:error, reason}, state}

  @spec apply_finish(t(), Ledger.namespace_row(), Ledger.mutation(:finished)) ::
          {:ok | {:error, term()}, t()}
  defp apply_finish(state, row, {:ok, :finished}), do: {:ok, finish_counters(state, row)}

  defp apply_finish(state, row, {:error, {:checkpoint_failed, _}, {:committed, :finished}}),
    do: {{:error, :storage_unavailable}, block(finish_counters(state, row))}

  defp apply_finish(state, _row, {:error, reason}), do: {{:error, reason}, state}

  @spec apply_reservation_release(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer(),
          Ledger.mutation(:released)
        ) ::
          {:ok | {:error, term()}, t()}
  defp apply_reservation_release(state, row, bytes, items, {:ok, :released}),
    do: {:ok, release_reservation_counters(state, row, bytes, items)}

  defp apply_reservation_release(
         state,
         row,
         bytes,
         items,
         {:error, {:checkpoint_failed, _}, {:committed, :released}}
       ),
       do:
         {{:error, :storage_unavailable},
          block(release_reservation_counters(state, row, bytes, items))}

  defp apply_reservation_release(state, _row, _bytes, _items, {:error, reason}),
    do: {{:error, reason}, state}

  @spec apply_release(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer(),
          Ledger.mutation(:released)
        ) ::
          {:ok | {:error, term()}, t()}
  defp apply_release(state, row, bytes, items, {:ok, :released}),
    do: {:ok, release_counters(state, row, bytes, items)}

  defp apply_release(
         state,
         row,
         bytes,
         items,
         {:error, {:checkpoint_failed, _}, {:committed, :released}}
       ),
       do: {{:error, :storage_unavailable}, block(release_counters(state, row, bytes, items))}

  defp apply_release(state, _row, _bytes, _items, {:error, reason}),
    do: {{:error, reason}, state}

  @spec apply_capture_cancel(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer(),
          Ledger.mutation(:canceled)
        ) :: {:ok | {:error, term()}, t()}
  defp apply_capture_cancel(state, row, bytes, items, {:ok, :canceled}),
    do: {:ok, cancel_capture_counters(state, row, bytes, items)}

  defp apply_capture_cancel(
         state,
         row,
         bytes,
         items,
         {:error, {:checkpoint_failed, _}, {:committed, :canceled}}
       ),
       do:
         {{:error, :storage_unavailable},
          block(cancel_capture_counters(state, row, bytes, items))}

  defp apply_capture_cancel(state, _row, _bytes, _items, {:error, reason}),
    do: {{:error, reason}, state}

  @spec apply_reconciliation(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Ledger.mutation(:reconciled)
        ) :: {:ok | {:error, term()}, t()}
  defp apply_reconciliation(state, row, bytes, items, artifacts, open, {:ok, :reconciled}) do
    {:ok, reconcile_counters(state, row, bytes, items, artifacts, open)}
  end

  defp apply_reconciliation(
         state,
         row,
         bytes,
         items,
         artifacts,
         open,
         {:error, {:checkpoint_failed, _}, {:committed, :reconciled}}
       ) do
    updated = reconcile_counters(state, row, bytes, items, artifacts, open)
    {{:error, :storage_unavailable}, block(updated)}
  end

  defp apply_reconciliation(
         state,
         _row,
         _bytes,
         _items,
         _artifacts,
         _open,
         {:error, reason}
       ),
       do: {{:error, reason}, state}

  @spec apply_namespace_release(t(), Ledger.namespace_row(), Ledger.mutation(:deleted)) ::
          {:ok | {:error, term()}, t()}
  defp apply_namespace_release(state, row, {:ok, :deleted}),
    do: {:ok, drop_row(state, row)}

  defp apply_namespace_release(
         state,
         row,
         {:error, {:checkpoint_failed, _}, {:committed, :deleted}}
       ),
       do: {{:error, :storage_unavailable}, block(drop_row(state, row))}

  defp apply_namespace_release(state, _row, {:error, reason}),
    do: {{:error, reason}, state}

  @spec new_row(String.t(), Limits.t()) :: Ledger.namespace_row()
  defp new_row(namespace, limits) do
    %{
      namespace: namespace,
      charged_bytes: Limits.sqlite_envelope_bytes(),
      items: 0,
      artifacts: 0,
      open_captures: 0,
      session_bytes: limits.session_bytes,
      session_items: limits.session_items,
      session_artifacts: limits.session_artifacts,
      session_open_captures: limits.session_open_captures
    }
  end

  @spec put_new_row(t(), Ledger.namespace_row()) :: t()
  defp put_new_row(%__MODULE__{} = state, row) do
    %__MODULE__{
      state
      | rows: Map.put(state.rows, row.namespace, row),
        total_bytes: state.total_bytes + row.charged_bytes
    }
  end

  @spec reserve_counters(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer(),
          integer(),
          integer()
        ) :: t()
  defp reserve_counters(%__MODULE__{} = state, row, bytes, items, artifacts, open) do
    updated_row = %{
      row
      | charged_bytes: row.charged_bytes + bytes,
        items: row.items + items,
        artifacts: row.artifacts + artifacts,
        open_captures: row.open_captures + open
    }

    %__MODULE__{
      state
      | rows: Map.put(state.rows, row.namespace, updated_row),
        total_bytes: state.total_bytes + bytes,
        total_items: state.total_items + items,
        total_artifacts: state.total_artifacts + artifacts,
        total_open_captures: state.total_open_captures + open
    }
  end

  @spec finish_counters(t(), Ledger.namespace_row()) :: t()
  defp finish_counters(%__MODULE__{} = state, row) do
    updated_row = %{row | open_captures: row.open_captures - 1}

    %__MODULE__{
      state
      | rows: Map.put(state.rows, row.namespace, updated_row),
        total_open_captures: state.total_open_captures - 1
    }
  end

  @spec release_reservation_counters(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  defp release_reservation_counters(%__MODULE__{} = state, row, bytes, items) do
    updated_row = %{
      row
      | charged_bytes: row.charged_bytes - bytes,
        items: row.items - items
    }

    %__MODULE__{
      state
      | rows: Map.put(state.rows, row.namespace, updated_row),
        total_bytes: state.total_bytes - bytes,
        total_items: state.total_items - items
    }
  end

  @spec release_counters(t(), Ledger.namespace_row(), non_neg_integer(), non_neg_integer()) :: t()
  defp release_counters(%__MODULE__{} = state, row, bytes, items) do
    updated_row = %{
      row
      | charged_bytes: row.charged_bytes - bytes,
        items: row.items - items,
        artifacts: row.artifacts - 1
    }

    %__MODULE__{
      state
      | rows: Map.put(state.rows, row.namespace, updated_row),
        total_bytes: state.total_bytes - bytes,
        total_items: state.total_items - items,
        total_artifacts: state.total_artifacts - 1
    }
  end

  @spec cancel_capture_counters(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  defp cancel_capture_counters(%__MODULE__{} = state, row, bytes, items) do
    updated_row = %{
      row
      | charged_bytes: row.charged_bytes - bytes,
        items: row.items - items,
        artifacts: row.artifacts - 1,
        open_captures: row.open_captures - 1
    }

    %__MODULE__{
      state
      | rows: Map.put(state.rows, row.namespace, updated_row),
        total_bytes: state.total_bytes - bytes,
        total_items: state.total_items - items,
        total_artifacts: state.total_artifacts - 1,
        total_open_captures: state.total_open_captures - 1
    }
  end

  @spec reconcile_counters(
          t(),
          Ledger.namespace_row(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  defp reconcile_counters(%__MODULE__{} = state, row, bytes, items, artifacts, open) do
    updated_row = %{
      row
      | charged_bytes: bytes,
        items: items,
        artifacts: artifacts,
        open_captures: open
    }

    %__MODULE__{
      state
      | rows: Map.put(state.rows, row.namespace, updated_row),
        total_bytes: state.total_bytes - row.charged_bytes + bytes,
        total_items: state.total_items - row.items + items,
        total_artifacts: state.total_artifacts - row.artifacts + artifacts,
        total_open_captures: state.total_open_captures - row.open_captures + open
    }
  end

  @spec drop_row(t(), Ledger.namespace_row()) :: t()
  defp drop_row(%__MODULE__{} = state, row) do
    %__MODULE__{
      state
      | rows: Map.delete(state.rows, row.namespace),
        total_bytes: state.total_bytes - row.charged_bytes,
        total_items: state.total_items - row.items,
        total_artifacts: state.total_artifacts - row.artifacts,
        total_open_captures: state.total_open_captures - row.open_captures
    }
  end

  @spec opened_db(t()) :: Ledger.db()
  defp opened_db(%__MODULE__{storage: {:open, db}}), do: db

  @spec block(t()) :: t()
  defp block(%__MODULE__{} = state), do: %__MODULE__{state | blocked: true}

  @spec valid_namespace?(term()) :: boolean()
  defp valid_namespace?(namespace) when is_binary(namespace),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, namespace)

  defp valid_namespace?(_namespace), do: false
end
