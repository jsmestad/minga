defmodule MingaAgent.ArtifactStore.State do
  @moduledoc "State owner and durable workflows for one session artifact namespace."

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStorage.FaultInjector
  alias MingaAgent.ArtifactStorage.Files
  alias MingaAgent.ArtifactStore.ActiveCapture
  alias MingaAgent.ArtifactStore.Blob
  alias MingaAgent.ArtifactStore.Capture
  alias MingaAgent.ArtifactStore.CaptureProgress
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.ArtifactStore.Fetched
  alias MingaAgent.ArtifactStore.Limits
  alias MingaAgent.ArtifactStore.Integrity
  alias MingaAgent.ArtifactStore.Metadata
  alias MingaAgent.ArtifactStore.Paths
  alias MingaAgent.ArtifactStore.PinKey
  alias MingaAgent.ArtifactStore.Stored
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference

  @incomplete_reasons [
    :capture_byte_limit,
    :session_disk_quota,
    :root_disk_quota,
    :session_item_quota,
    :root_item_quota,
    :disk_full,
    :interrupted,
    :source_changed,
    :legacy_unclassified,
    :timeout,
    :capture_failed
  ]

  @type t :: %__MODULE__{
          namespace: String.t(),
          directory: String.t(),
          db: Metadata.db() | nil,
          quota: GenServer.server(),
          limits: Limits.t(),
          active: %{optional(String.t()) => ActiveCapture.t()},
          monitors: %{optional(reference()) => String.t()},
          blocked: boolean(),
          fault_injector: FaultInjector.t()
        }

  @enforce_keys [
    :namespace,
    :directory,
    :db,
    :quota,
    :limits,
    :active,
    :monitors,
    :blocked,
    :fault_injector
  ]
  defstruct @enforce_keys

  @doc "Admits the namespace envelope, opens metadata, and recovers interrupted captures."
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) when is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    root = Keyword.get(opts, :root)
    quota = Keyword.get(opts, :quota)
    requested_limits = Keyword.get(opts, :limits, [])

    with true <- is_binary(session_id) and byte_size(session_id) > 0,
         true <- is_binary(root),
         true <- valid_quota_server?(quota),
         namespace = Reference.namespace(session_id),
         {:ok, limits} <-
           ArtifactQuota.register_namespace(quota, root, namespace, requested_limits),
         directory = Path.join([root, "namespaces", namespace]),
         :ok <- Files.ensure_private_directory(Path.dirname(directory)),
         :ok <- Files.ensure_private_directory(directory),
         {:ok, db} <- Metadata.open(Path.join(directory, "artifacts.sqlite3")),
         state = %__MODULE__{
           namespace: namespace,
           directory: directory,
           db: db,
           quota: quota,
           limits: limits,
           active: %{},
           monitors: %{},
           blocked: false,
           fault_injector: Keyword.get(opts, :fault_injector)
         },
         {:ok, recovered} <- recover_opened_state(state) do
      {:ok, recovered}
    else
      false -> {:error, :invalid_artifact_store_options}
      {:error, _reason} = error -> error
    end
  end

  @doc "Closes handles and metadata without expiring or cleaning retained artifacts."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = state) do
    Enum.each(state.active, fn {_id, active} -> ActiveCapture.close(active) end)

    if state.db != nil do
      _ = Metadata.close(state.db)
    end

    :ok
  end

  @doc "Begins or resumes the capture identified by a stable delivery key."
  @spec begin_capture(t(), CaptureSpec.t()) ::
          {{:ok, Capture.t()} | {:error, term()}, t()}
  def begin_capture(%__MODULE__{blocked: true} = state, _spec),
    do: {{:error, :storage_unavailable}, state}

  def begin_capture(%__MODULE__{} = state, %CaptureSpec{} = spec) do
    delivery_key = PinKey.encode(spec.delivery_key)

    case Metadata.by_delivery(state.db, delivery_key) do
      {:ok, nil} -> begin_new_capture(state, spec, delivery_key)
      {:ok, row} -> begin_existing_capture(state, spec, row)
      {:error, reason} -> {{:error, {:io, reason}}, state}
    end
  end

  @doc "Appends one bounded binary chunk after durable quota admission."
  @spec append(t(), Capture.t(), binary(), keyword()) ::
          {{:ok, CaptureProgress.t()} | {:error, term()}, t()}
  def append(%__MODULE__{blocked: true} = state, _capture, _chunk, _opts),
    do: {{:error, :storage_unavailable}, state}

  def append(%__MODULE__{} = state, %Capture{} = capture, chunk, opts)
      when is_binary(chunk) and is_list(opts) do
    with :ok <- authorize_capture(state, capture),
         {:ok, active} <- fetch_active(state, capture.id),
         :ok <- validate_append(active, chunk, opts, state.limits),
         item_ends = Keyword.get(opts, :item_ends, []),
         item_count = length(item_ends),
         :ok <- validate_capture_totals(active, chunk, item_count, state.limits) do
      admitted_append(state, active, chunk, item_ends, item_count)
    else
      {:limit, reason, active} -> mark_refused_append(state, active, reason)
      {:error, _reason} = error -> {error, state}
    end
  end

  def append(state, _capture, _chunk, _opts), do: {{:error, :invalid_append}, state}

  @doc "Finishes a capture and exposes its reference only after files, status, and delivery pin are durable."
  @spec finish(t(), Capture.t(), :complete | {:incomplete, atom()}) ::
          {{:ok, Stored.t()} | {:error, term()}, t()}
  def finish(%__MODULE__{blocked: true} = state, _capture, _status),
    do: {{:error, :storage_unavailable}, state}

  def finish(%__MODULE__{} = state, %Capture{} = capture, status) do
    with :ok <- authorize_capture(state, capture),
         :ok <- validate_requested_status(status),
         {:ok, row} <- Metadata.get(state.db, capture.id) do
      finish_row(state, row, status)
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Fetches an exact bounded byte or item range from immutable captured files."
  @spec fetch(t(), Reference.t(), Range.t()) ::
          {{:ok, Fetched.t()} | {:error, term()}, t()}
  def fetch(%__MODULE__{} = state, %Reference{} = reference, %Range{} = range) do
    with {:ok, id} <- authorize_reference(state, reference),
         {:ok, row} <- fetch_terminal_row(state, id),
         :ok <- verify_reference(reference, row),
         {:ok, selection, _total} <- validate_range(range, row),
         {:ok, paths} <- Paths.new(state.directory, id),
         {:ok, bytes} <- read_range(state, paths, selection, row) do
      fetched = Fetched.new(bytes, selection, reference, row.capture)
      {{:ok, fetched}, state}
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  def fetch(state, _reference, _range), do: {{:error, :invalid_range}, state}

  @doc "Looks up a capture only by its canonical stable delivery key."
  @spec lookup_delivery(t(), {:delivery, PinKey.component(), PinKey.component()}) ::
          {{:ok, Stored.t()} | {:error, term()}, t()}
  def lookup_delivery(%__MODULE__{} = state, {:delivery, _checkpoint, _call_id} = delivery_key) do
    with {:ok, %PinKey{kind: :delivery} = key} <- PinKey.new(delivery_key) do
      case Metadata.by_delivery(state.db, PinKey.encode(key)) do
        {:ok, nil} -> {{:error, :unknown_delivery}, state}
        {:ok, %{state: :terminal} = row} -> stored_reply(state, row)
        {:ok, %{state: :open} = row} -> lookup_open_delivery(state, row)
        {:error, reason} -> {{:error, {:io, reason}}, state}
      end
    else
      {:error, _reason} -> {{:error, :unknown_delivery}, state}
    end
  end

  def lookup_delivery(%__MODULE__{} = state, _delivery_key),
    do: {{:error, :unknown_delivery}, state}

  @doc "Atomically replaces one snapshot/task pin set."
  @spec pin(t(), PinKey.t() | tuple(), [Reference.t()], keyword()) ::
          {:ok | {:error, term()}, t()}
  def pin(%__MODULE__{blocked: true} = state, _pin_key, _references, _opts),
    do: {{:error, :storage_unavailable}, state}

  def pin(%__MODULE__{} = state, pin_key, references, opts)
      when is_list(references) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) -- [:transfer_delivery] == [],
         {:ok, %PinKey{kind: kind} = key} <- PinKey.new(pin_key),
         true <- kind in [:snapshot, :task],
         true <- length(references) <= state.limits.session_pin_refs,
         {:ok, artifact_ids} <- validate_pin_references(state, references),
         transfer when is_boolean(transfer) <- Keyword.get(opts, :transfer_delivery, false) do
      mutation =
        Metadata.replace_pin_set(
          state.db,
          PinKey.encode(key),
          kind,
          artifact_ids,
          transfer,
          state.limits.session_pin_sets,
          state.limits.session_pin_refs,
          metadata_fault_opts(state)
        )

      metadata_reply(state, mutation, :ok)
    else
      false -> {{:error, :invalid_pin_set}, state}
      {:error, _reason} = error -> {error, state}
      _ -> {{:error, :invalid_pin_set}, state}
    end
  end

  @doc "Idempotently releases one durable pin set, making artifacts eligible for explicit cleanup."
  @spec release(t(), PinKey.t() | tuple()) :: {:ok | {:error, term()}, t()}
  def release(%__MODULE__{blocked: true} = state, _pin_key),
    do: {{:error, :storage_unavailable}, state}

  def release(%__MODULE__{} = state, pin_key) do
    with {:ok, key} <- PinKey.new(pin_key) do
      mutation = Metadata.release_pin_set(state.db, PinKey.encode(key), metadata_fault_opts(state))
      metadata_reply(state, mutation, :ok)
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  @doc "Explicitly deletes only artifacts with no pins, then releases their quota."
  @spec cleanup_unreferenced(t()) :: {{:ok, non_neg_integer()} | {:error, term()}, t()}
  def cleanup_unreferenced(%__MODULE__{blocked: true} = state),
    do: {{:error, :storage_unavailable}, state}

  def cleanup_unreferenced(%__MODULE__{} = state) do
    case Metadata.unreferenced(state.db, state.limits.session_artifacts) do
      {:ok, rows} -> cleanup_rows(state, rows, 0)
      {:error, reason} -> {{:error, {:io, reason}}, state}
    end
  end

  @doc "Explicitly removes this complete record namespace and then decharges its quota row."
  @spec delete_record(t()) :: {:ok | {:error, term()}, t(), :keep | :stop}
  def delete_record(%__MODULE__{active: active} = state) when map_size(active) > 0,
    do: {{:error, :record_in_use}, state, :keep}

  def delete_record(%__MODULE__{} = state) do
    close_result = Metadata.close(state.db)
    closed = %__MODULE__{state | db: nil, blocked: true}

    result =
      with :ok <- close_result,
           :ok <- FaultInjector.run(state.fault_injector, :before_namespace_delete),
           :ok <- Files.remove_private_directory(state.directory),
           :ok <- FaultInjector.run(state.fault_injector, :after_namespace_delete),
           :ok <- ArtifactQuota.delete_namespace(state.quota, state.namespace) do
        :ok
      else
        {:error, reason} -> {:error, normalize_write_error(reason)}
      end

    {result, closed, :stop}
  end

  @doc "Finalizes an owner-abandoned capture as an interrupted retained prefix."
  @spec owner_down(t(), reference(), pid()) :: t()
  def owner_down(%__MODULE__{} = state, monitor, owner_pid) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, id} -> finish_owner_down(state, id, owner_pid)
      :error -> state
    end
  end

  @spec begin_new_capture(t(), CaptureSpec.t(), String.t()) ::
          {{:ok, Capture.t()} | {:error, term()}, t()}
  defp begin_new_capture(state, spec, delivery_key) do
    with :ok <- validate_expected(spec, state.limits),
         id = random_id(),
         initial_charge = Limits.capture_header_bytes() + (spec.expected_bytes || 0),
         :ok <- ArtifactQuota.reserve_capture(state.quota, state.namespace, initial_charge),
         row = new_open_row(id, delivery_key, spec, initial_charge),
         {:ok, :inserted} <-
           Metadata.insert_capture(state.db, row, metadata_fault_opts(state)),
         {:ok, paths} <- Paths.new(state.directory, id),
         :ok <- FaultInjector.run(state.fault_injector, :before_capture_files),
         {:ok, data_io, index_io} <- Blob.create(paths) do
      monitor = Process.monitor(spec.owner_pid)

      active =
        ActiveCapture.new(
          id: id,
          media_type: spec.media_type,
          mode: spec.mode,
          data_io: data_io,
          index_io: index_io,
          owner_pid: spec.owner_pid,
          monitor: monitor,
          bytes: 0,
          items: 0,
          charged_bytes: initial_charge,
          charged_items: 0,
          reserved_data: spec.expected_bytes || 0,
          integrity: Integrity.new()
        )

      next_state = put_active(state, active)
      {{:ok, Capture.new(id, state.namespace)}, next_state}
    else
      {:error, {:checkpoint_failed, _reason}, {:committed, :inserted}} ->
        {{:error, :storage_unavailable}, block(state)}

      {:error, reason} ->
        {{:error, normalize_write_error(reason)}, state}
    end
  end

  @spec begin_existing_capture(t(), CaptureSpec.t(), Metadata.row()) ::
          {{:ok, Capture.t()} | {:error, term()}, t()}
  defp begin_existing_capture(state, spec, row) do
    if row.media_type == spec.media_type and row.mode == spec.mode do
      resume_existing_capture(state, spec, row)
    else
      {{:error, :delivery_conflict}, state}
    end
  end

  @spec resume_existing_capture(t(), CaptureSpec.t(), Metadata.row()) ::
          {{:ok, Capture.t()} | {:error, term()}, t()}
  defp resume_existing_capture(state, _spec, %{state: :terminal} = row),
    do: {{:ok, Capture.new(row.id, state.namespace)}, state}

  defp resume_existing_capture(state, spec, %{state: :open} = row) do
    case Map.has_key?(state.active, row.id) do
      true ->
        {{:ok, Capture.new(row.id, state.namespace)}, state}

      false ->
        resume_recovered_capture(state, spec, row)
    end
  end

  @spec resume_recovered_capture(t(), CaptureSpec.t(), Metadata.row()) ::
          {{:ok, Capture.t()} | {:error, term()}, t()}
  defp resume_recovered_capture(state, spec, row) do
    case recover_row(state, row) do
      {:ok, recovered} ->
        case Metadata.get(recovered.db, row.id) do
          {:ok, %{state: :terminal}} ->
            {{:ok, Capture.new(row.id, state.namespace)}, recovered}

          {:ok, nil} ->
            begin_new_capture(recovered, spec, PinKey.encode(spec.delivery_key))

          {:error, reason} ->
            {{:error, {:io, reason}}, recovered}
        end

      {:error, reason, recovered} ->
        {{:error, reason}, recovered}
    end
  end
  @spec admitted_append(t(), ActiveCapture.t(), binary(), [pos_integer()], non_neg_integer()) ::
          {{:ok, CaptureProgress.t()} | {:error, term()}, t()}
  defp admitted_append(state, active, <<>>, [], 0) do
    {{:ok, CaptureProgress.new(active.bytes, active.items)}, state}
  end

  defp admitted_append(state, active, chunk, item_ends, item_count) do
    resulting_bytes = active.bytes + byte_size(chunk)
    resulting_items = active.items + item_count

    desired_charge =
      Limits.capture_header_bytes() + max(active.reserved_data, resulting_bytes) +
        resulting_items * 8

    newly_charged = desired_charge - active.charged_bytes

    case ArtifactQuota.reserve_append(state.quota, state.namespace, newly_charged, item_count) do
      :ok ->
        write_admitted_append(state, active, chunk, item_ends, item_count, newly_charged)
      {:error, reason} when reason in @incomplete_reasons -> mark_refused_append(state, active, reason)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @spec write_admitted_append(
          t(),
          ActiveCapture.t(),
          binary(),
          [pos_integer()],
          non_neg_integer(),
          non_neg_integer()
        ) :: {{:ok, CaptureProgress.t()} | {:error, term()}, t()}
  defp write_admitted_append(
         state,
         active,
         chunk,
         item_ends,
         item_count,
         newly_charged
       ) do
    reserved = ActiveCapture.reserve(active, newly_charged, item_count)

    case FaultInjector.run(state.fault_injector, :before_blob_write) do
      :ok ->
        write_append_files(state, active, reserved, chunk, item_ends, item_count, newly_charged)

      {:error, reason} ->
        mark_failed_write(state, reserved, normalize_write_error(reason))
    end
  end

  @spec write_append_files(
          t(),
          ActiveCapture.t(),
          ActiveCapture.t(),
          binary(),
          [pos_integer()],
          non_neg_integer(),
          non_neg_integer()
        ) :: {{:ok, CaptureProgress.t()} | {:error, term()}, t()}
  defp write_append_files(
         state,
         active,
         reserved,
         chunk,
         item_ends,
         item_count,
         newly_charged
       ) do
    case Blob.append(active, chunk, item_ends, state.fault_injector) do
      {:ok, encoded_offsets} ->
        accepted =
          ActiveCapture.record_append(
            active,
            chunk,
            encoded_offsets,
            newly_charged,
            item_count
          )

        mutation =
          Metadata.update_progress(
            state.db,
            active.id,
            accepted.bytes,
            accepted.items,
            accepted.charged_bytes,
            ActiveCapture.pending_integrity_rows(accepted),
            metadata_fault_opts(state)
          )

        apply_progress_mutation(state, accepted, mutation)

      {:error, reason} ->
        rebuilding = ActiveCapture.mark_integrity_rebuild(reserved)
        mark_failed_write(state, rebuilding, normalize_write_error(reason))
    end
  end

  @spec apply_progress_mutation(t(), ActiveCapture.t(), Metadata.mutation(:updated)) ::
          {{:ok, CaptureProgress.t()} | {:error, term()}, t()}
  defp apply_progress_mutation(state, accepted, {:ok, :updated}) do
    committed = ActiveCapture.commit_integrity_rows(accepted)
    next_state = replace_active(state, committed)
    {{:ok, CaptureProgress.new(committed.bytes, committed.items)}, next_state}
  end

  defp apply_progress_mutation(
         state,
         accepted,
         {:error, {:checkpoint_failed, _}, {:committed, :updated}}
       ) do
    rebuilding = ActiveCapture.mark_integrity_rebuild(accepted)
    next_state = state |> replace_active(rebuilding) |> block()
    {{:error, :storage_unavailable}, next_state}
  end

  defp apply_progress_mutation(state, accepted, {:error, reason}) do
    rebuilding = ActiveCapture.mark_integrity_rebuild(accepted)
    next_state = state |> replace_active(rebuilding) |> block()
    error = normalize_write_error(reason)
    reply = if error == :disk_full, do: :disk_full, else: :storage_unavailable
    {{:error, reply}, next_state}
  end

  @spec mark_refused_append(t(), ActiveCapture.t(), atom()) ::
          {{:error, term()}, t()}
  defp mark_refused_append(state, active, reason) do
    marked = ActiveCapture.mark(active, reason)
    mutation = Metadata.mark_limit(state.db, active.id, reason, metadata_fault_opts(state))

    case mutation do
      {:ok, :marked} -> {{:error, reason}, replace_active(state, marked)}
      {:error, {:checkpoint_failed, _}, {:committed, :marked}} ->
        {{:error, :storage_unavailable}, state |> replace_active(marked) |> block()}

      {:error, _reason} ->
        {{:error, :storage_unavailable}, state |> replace_active(marked) |> block()}
    end
  end

  @spec mark_failed_write(t(), ActiveCapture.t(), term()) :: {{:error, term()}, t()}
  defp mark_failed_write(state, active, error) do
    reason = if error == :disk_full, do: :disk_full, else: :capture_failed
    {reply, next_state} = mark_refused_append(state, active, reason)

    case reply do
      {:error, :storage_unavailable} -> {reply, next_state}
      {:error, _marked_reason} -> {{:error, error}, next_state}
    end
  end

  @spec finish_row(t(), Metadata.row() | nil, :complete | {:incomplete, atom()}) ::
          {{:ok, Stored.t()} | {:error, term()}, t()}
  defp finish_row(state, nil, _status), do: {{:error, :unknown_capture}, state}

  defp finish_row(state, %{state: :terminal} = row, status) do
    if row.capture == status do
      case stored(state, row) do
        {:ok, value} -> {{:ok, value}, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    else
      {{:error, :contradictory_finish}, state}
    end
  end

  defp finish_row(state, %{state: :open} = row, status) do
    case Map.fetch(state.active, row.id) do
      {:ok, active} -> finish_active(state, row, active, status, false)
      :error -> finish_dormant(state, row, status)
    end
  end

  @spec finish_active(
          t(),
          Metadata.row(),
          ActiveCapture.t(),
          :complete | {:incomplete, atom()},
          boolean()
        ) :: {{:ok, Stored.t()} | {:error, term()}, t()}
  defp finish_active(state, row, active, requested_status, owner_down?) do
    case effective_status(active.marked, requested_status) do
      {:ok, status} ->
        result = sync_active(active, owner_down?)
        next_state = drop_active(state, active)

        case result do
          :ok -> finish_synced_active(next_state, row, active, status)
          {:error, reason} -> {{:error, normalize_write_error(reason)}, next_state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  @spec finish_synced_active(
          t(),
          Metadata.row(),
          ActiveCapture.t(),
          :complete | {:incomplete, atom()}
        ) :: {{:ok, Stored.t()} | {:error, term()}, t()}
  defp finish_synced_active(state, row, active, status) do
    case ActiveCapture.integrity_rebuild?(active) do
      true ->
        recovered_finish_reply(
          finalize_recovered_open_row(
            state,
            row,
            status,
            active.charged_bytes,
            active.charged_items
          )
        )

      false ->
        clean_finish_reply(finalize_clean_open_row(state, row, status, active))
    end
  end

  @spec finish_dormant(t(), Metadata.row(), :complete | {:incomplete, atom()}) ::
          {{:ok, Stored.t()} | {:error, term()}, t()}
  defp finish_dormant(state, row, requested_status) do
    case effective_status(row.limit_reason, requested_status) do
      {:ok, effective} ->
        recovered_finish_reply(
          finalize_recovered_open_row(
            state,
            row,
            effective,
            row.charged_bytes,
            row.items
          )
        )

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  @spec clean_finish_reply(
          {:ok, Stored.t(), t()} | {:error, term(), t()}
        ) :: {{:ok, Stored.t()} | {:error, term()}, t()}
  defp clean_finish_reply({:ok, stored, state}), do: {{:ok, stored}, state}
  defp clean_finish_reply({:error, reason, state}), do: {{:error, reason}, state}

  @spec recovered_finish_reply(
          {:ok, Stored.t(), t()} | {:error, term(), t()}
        ) :: {{:ok, Stored.t()} | {:error, term()}, t()}
  defp recovered_finish_reply({:ok, stored, state}), do: {{:ok, stored}, state}
  defp recovered_finish_reply({:error, reason, state}), do: {{:error, reason}, state}

  @spec finalize_clean_open_row(
          t(),
          Metadata.row(),
          :complete | {:incomplete, atom()},
          ActiveCapture.t()
        ) :: {:ok, Stored.t(), t()} | {:error, term(), t()}
  defp finalize_clean_open_row(state, row, status, active) do
    with {:ok, paths} <- Paths.new(state.directory, row.id),
         :ok <- FaultInjector.run(state.fault_injector, :before_blob_rename),
         :ok <- Blob.promote(paths, state.directory),
         :ok <- Blob.validate_final(paths, active.mode, active.bytes, active.items),
         {:ok, sha256, rows} <- ActiveCapture.seal_integrity(active),
         actual_charge = Limits.capture_header_bytes() + active.bytes + active.items * 8,
         mutation =
           Metadata.finish(
             state.db,
             row.id,
             status,
             active.bytes,
             active.items,
             sha256,
             actual_charge,
             row.delivery_key,
             rows,
             metadata_fault_opts(state)
           ),
         {:ok, :finished} <- mutation,
         terminal =
           terminal_row(row, status, active.bytes, active.items, sha256, actual_charge),
         {:ok, value} <- stored(state, terminal) do
      _ = ArtifactQuota.finish_capture(state.quota, state.namespace)
      release_excess(
        state,
        active.charged_bytes,
        active.charged_items,
        actual_charge,
        active.items
      )

      {:ok, value, state}
    else
      {:error, {:checkpoint_failed, _}, {:committed, :finished}} ->
        {:error, :storage_unavailable, block(state)}

      {:error, reason} ->
        {:error, normalize_write_error(reason), state}
    end
  end

  @spec finalize_recovered_open_row(
          t(),
          Metadata.row(),
          :complete | {:incomplete, atom()},
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, Stored.t(), t()} | {:error, term(), t()}
  defp finalize_recovered_open_row(
         state,
         row,
         status,
         conservative_charge,
         conservative_items
       ) do
    with {:ok, paths} <- Paths.new(state.directory, row.id),
         {:ok, recovered} <- Blob.recover_open(paths, row.mode),
         :ok <- FaultInjector.run(state.fault_injector, :before_blob_rename),
         :ok <- Blob.promote(paths, state.directory),
         actual_charge =
           Limits.capture_header_bytes() + recovered.bytes + recovered.items * 8,
         mutation =
           Metadata.finish_recovered(
             state.db,
             row.id,
             status,
             recovered.bytes,
             recovered.items,
             recovered.sha256,
             actual_charge,
             row.delivery_key,
             recovered.rows,
             metadata_fault_opts(state)
           ),
         {:ok, :finished} <- mutation,
         terminal =
           terminal_row(
             row,
             status,
             recovered.bytes,
             recovered.items,
             recovered.sha256,
             actual_charge
           ),
         {:ok, value} <- stored(state, terminal) do
      _ = ArtifactQuota.finish_capture(state.quota, state.namespace)

      release_excess(
        state,
        conservative_charge,
        conservative_items,
        actual_charge,
        recovered.items
      )

      {:ok, value, state}
    else
      {:error, {:checkpoint_failed, _}, {:committed, :finished}} ->
        {:error, :storage_unavailable, block(state)}

      {:error, reason} ->
        {:error, normalize_write_error(reason), state}
    end
  end

  @spec recover_opened_state(t()) :: {:ok, t()} | {:error, term()}
  defp recover_opened_state(state) do
    case recover_open_captures(state) do
      {:ok, recovered} ->
        {:ok, recovered}

      {:error, reason} ->
        _ = Metadata.close(state.db)
        {:error, reason}
    end
  end

  @spec recover_open_captures(t()) :: {:ok, t()} | {:error, term()}
  defp recover_open_captures(state) do
    with {:ok, rows} <- Metadata.open_captures(state.db) do
      Enum.reduce_while(rows, {:ok, state}, fn row, {:ok, current} ->
        case recover_row(current, row) do
          {:ok, recovered} -> {:cont, {:ok, recovered}}
          {:error, reason, _recovered} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @spec recover_row(t(), Metadata.row()) :: {:ok, t()} | {:error, term(), t()}
  defp recover_row(state, row) do
    case finalize_recovered_open_row(
           state,
           row,
           {:incomplete, :interrupted},
           row.charged_bytes,
           row.items
         ) do
      {:ok, _stored, recovered} -> {:ok, recovered}
      {:error, reason, recovered} -> {:error, reason, recovered}
    end
  end

  @spec lookup_open_delivery(t(), Metadata.row()) ::
          {{:ok, Stored.t()} | {:error, term()}, t()}
  defp lookup_open_delivery(state, row) do
    case Map.fetch(state.active, row.id) do
      {:ok, active} -> lookup_active_delivery(state, row, active)
      :error -> {{:error, :delivery_in_progress}, state}
    end
  end

  @spec lookup_active_delivery(t(), Metadata.row(), ActiveCapture.t()) ::
          {{:ok, Stored.t()} | {:error, term()}, t()}
  defp lookup_active_delivery(state, row, active) do
    monitored_capture? = Map.get(state.monitors, active.monitor) == row.id

    if monitored_capture? and not Process.alive?(active.owner_pid) do
      finish_active(state, row, active, {:incomplete, :interrupted}, true)
    else
      {{:error, :delivery_in_progress}, state}
    end
  end

  @spec stored_reply(t(), Metadata.row()) :: {{:ok, Stored.t()} | {:error, term()}, t()}
  defp stored_reply(state, row) do
    case stored(state, row) do
      {:ok, value} -> {{:ok, value}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @spec stored(t(), Metadata.row()) :: {:ok, Stored.t()} | {:error, term()}
  defp stored(state, row) do
    items = if row.mode == :items, do: row.items, else: nil
    token = "artifact:1:#{state.namespace}:#{row.id}"

    with {:ok, reference} <-
           Reference.new(
             token: token,
             media_type: row.media_type,
             bytes: row.bytes,
             items: items,
             sha256: row.sha256
           ) do
      {:ok, Stored.new(reference, row.capture)}
    end
  end

  @spec validate_append(ActiveCapture.t(), binary(), keyword(), Limits.t()) ::
          :ok | {:error, term()}
  defp validate_append(active, chunk, opts, limits) do
    item_ends = Keyword.get(opts, :item_ends, [])

    with true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) -- [:item_ends] == [],
         true <- byte_size(chunk) <= limits.append_bytes,
         true <- is_list(item_ends),
         true <- valid_item_ends?(active.mode, item_ends, byte_size(chunk)),
         true <- active.marked == nil do
      :ok
    else
      false ->
        if active.marked == nil,
          do: {:error, :invalid_append},
          else: {:error, active.marked}
    end
  end

  @spec validate_capture_totals(ActiveCapture.t(), binary(), non_neg_integer(), Limits.t()) ::
          :ok | {:limit, atom(), ActiveCapture.t()}
  defp validate_capture_totals(active, chunk, item_count, limits) do
    bytes = active.bytes + byte_size(chunk)
    items = active.items + item_count
    byte_limit = media_byte_limit(active.media_type, limits)

    if bytes > byte_limit do
      {:limit, :capture_byte_limit, active}
    else
      if items > limits.capture_items,
        do: {:limit, :session_item_quota, active},
        else: :ok
    end
  end

  @spec validate_expected(CaptureSpec.t(), Limits.t()) :: :ok | {:error, atom()}
  defp validate_expected(%CaptureSpec{expected_bytes: nil}, _limits), do: :ok

  defp validate_expected(%CaptureSpec{} = spec, limits) do
    if spec.expected_bytes <= media_byte_limit(spec.media_type, limits),
      do: :ok,
      else: {:error, :capture_byte_limit}
  end

  @spec media_byte_limit(String.t(), Limits.t()) :: pos_integer()
  defp media_byte_limit("image/" <> _subtype, limits), do: limits.image_bytes
  defp media_byte_limit(_media_type, limits), do: limits.capture_bytes

  @spec valid_item_ends?(:bytes | :items, [term()], non_neg_integer()) :: boolean()
  defp valid_item_ends?(:bytes, item_ends, _chunk_size), do: item_ends == []

  defp valid_item_ends?(:items, item_ends, chunk_size) do
    Enum.all?(item_ends, &(is_integer(&1) and &1 > 0 and &1 <= chunk_size)) and
      strictly_increasing?(item_ends)
  end

  @spec strictly_increasing?([integer()]) :: boolean()
  defp strictly_increasing?([]), do: true
  defp strictly_increasing?([_one]), do: true
  defp strictly_increasing?([first, second | rest]) when first < second,
    do: strictly_increasing?([second | rest])

  defp strictly_increasing?(_values), do: false

  @spec effective_status(atom() | nil, :complete | {:incomplete, atom()}) ::
          {:ok, :complete | {:incomplete, atom()}} | {:error, term()}
  defp effective_status(nil, status), do: {:ok, status}
  defp effective_status(reason, :complete), do: {:error, {:capture_incomplete, reason}}
  defp effective_status(reason, {:incomplete, _requested}), do: {:ok, {:incomplete, reason}}

  @spec validate_requested_status(term()) :: :ok | {:error, :invalid_capture_status}
  defp validate_requested_status(:complete), do: :ok

  defp validate_requested_status({:incomplete, reason}) when reason in @incomplete_reasons,
    do: :ok

  defp validate_requested_status(_status), do: {:error, :invalid_capture_status}

  @spec validate_range(Range.t(), Metadata.row()) ::
          {:ok, Range.t(), non_neg_integer()} | {:error, :invalid_range}
  defp validate_range(%Range{unit: :bytes} = range, row) do
    validate_known_range(range, row.bytes)
  end

  defp validate_range(%Range{unit: :items} = range, %{mode: :items} = row) do
    validate_known_range(range, row.items)
  end

  defp validate_range(_range, _row), do: {:error, :invalid_range}

  @spec validate_known_range(Range.t(), non_neg_integer()) ::
          {:ok, Range.t(), non_neg_integer()} | {:error, :invalid_range}
  defp validate_known_range(range, total) do
    valid_total = range.total == :unknown or range.total == total

    with true <- valid_total,
         true <- range.start + range.count <= total,
         {:ok, selection} <- Range.new(range.kind, range.unit, range.start, range.count, total) do
      {:ok, selection, total}
    else
      _ -> {:error, :invalid_range}
    end
  end

  @spec read_range(t(), Paths.t(), Range.t(), Metadata.row()) ::
          {:ok, binary()} | {:error, term()}
  defp read_range(state, paths, %Range{unit: :bytes} = range, row) do
    numbers = Blob.block_numbers(range.start, range.count, row.bytes)

    with {:ok, hashes} <- trusted_hashes(state, row.id, :blob, numbers) do
      Blob.fetch_bytes(
        paths,
        range.start,
        range.count,
        row.mode,
        row.bytes,
        row.items,
        hashes
      )
    end
  end

  defp read_range(state, paths, %Range{unit: :items} = range, row) do
    index_numbers = Blob.item_boundary_block_numbers(range.start, range.count)

    with {:ok, index_hashes} <- trusted_hashes(state, row.id, :index, index_numbers),
         {:ok, {first, last}} <-
           Blob.fetch_item_bounds(
             paths,
             range.start,
             range.count,
             row.bytes,
             row.items,
             index_hashes
           ),
         blob_numbers = Blob.block_numbers(first, last - first, row.bytes),
         {:ok, blob_hashes} <- trusted_hashes(state, row.id, :blob, blob_numbers) do
      Blob.fetch_payload(paths, first, last - first, row.bytes, blob_hashes)
    end
  end

  @spec trusted_hashes(
          t(),
          String.t(),
          Integrity.file_kind(),
          [non_neg_integer()]
        ) :: {:ok, [{non_neg_integer(), binary()}]} | {:error, term()}
  defp trusted_hashes(state, id, kind, numbers) do
    case Metadata.block_hashes(state.db, id, kind, numbers) do
      {:ok, hashes} -> {:ok, hashes}
      {:error, :artifact_corrupt} = error -> error
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  @spec authorize_capture(t(), Capture.t()) :: :ok | {:error, :unauthorized}
  defp authorize_capture(state, %Capture{namespace: namespace}) do
    if namespace == state.namespace, do: :ok, else: {:error, :unauthorized}
  end

  @spec authorize_reference(t(), Reference.t()) :: {:ok, String.t()} | {:error, term()}
  defp authorize_reference(state, reference) do
    case Reference.parse(reference.token) do
      {:ok, namespace, id} when namespace == state.namespace -> {:ok, id}
      {:ok, _foreign, _id} -> {:error, :unauthorized}
      {:error, _reason} -> {:error, :invalid_reference}
    end
  end

  @spec fetch_terminal_row(t(), String.t()) :: {:ok, Metadata.row()} | {:error, term()}
  defp fetch_terminal_row(state, id) do
    case Metadata.get(state.db, id) do
      {:ok, %{state: :terminal} = row} -> {:ok, row}
      {:ok, %{state: :open}} -> {:error, :unknown_reference}
      {:ok, nil} -> classify_missing_reference(state, id)
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  @spec classify_missing_reference(t(), String.t()) :: {:error, term()}
  defp classify_missing_reference(state, id) do
    case Metadata.expired?(state.db, id) do
      {:ok, true} -> {:error, :expired}
      {:ok, false} -> {:error, :unknown_reference}
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  @spec verify_reference(Reference.t(), Metadata.row()) :: :ok | {:error, :artifact_corrupt}
  defp verify_reference(reference, row) do
    expected_items = if row.mode == :items, do: row.items, else: nil

    if reference.media_type == row.media_type and reference.bytes == row.bytes and
         reference.items == expected_items and reference.sha256 == row.sha256,
      do: :ok,
      else: {:error, :artifact_corrupt}
  end

  @spec validate_pin_references(t(), [Reference.t()]) :: {:ok, [String.t()]} | {:error, term()}
  defp validate_pin_references(state, references) do
    Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, ids} ->
      with %Reference{} <- reference,
           {:ok, id} <- authorize_reference(state, reference),
           {:ok, row} <- fetch_terminal_row(state, id),
           :ok <- verify_reference(reference, row) do
        {:cont, {:ok, [id | ids]}}
      else
        {:error, _reason} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_reference}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end

  @spec cleanup_rows(t(), [Metadata.row()], non_neg_integer()) ::
          {{:ok, non_neg_integer()} | {:error, term()}, t()}
  defp cleanup_rows(state, [], count), do: {{:ok, count}, state}

  defp cleanup_rows(state, [row | rest], count) do
    case cleanup_row(state, row) do
      {:ok, next_state} -> cleanup_rows(next_state, rest, count + 1)
      {:skip, next_state} -> cleanup_rows(next_state, rest, count)
      {:error, reason, next_state} -> {{:error, reason}, next_state}
    end
  end

  @spec cleanup_row(t(), Metadata.row()) :: {:ok, t()} | {:skip, t()} | {:error, term(), t()}
  defp cleanup_row(state, row) do
    with {:ok, false} <- Metadata.pinned?(state.db, row.id),
         {:ok, paths} <- Paths.new(state.directory, row.id),
         :ok <- FaultInjector.run(state.fault_injector, :before_blob_delete),
         :ok <- Blob.delete(paths),
         {:ok, :expired} <-
           Metadata.expire_unreferenced(
             state.db,
             row.id,
             state.limits.session_artifacts,
             metadata_fault_opts(state)
           ) do
      _ = ArtifactQuota.release_artifact(state.quota, state.namespace, row.charged_bytes, row.items)
      {:ok, state}
    else
      {:ok, true} -> {:skip, state}
      {:error, {:checkpoint_failed, _}, {:committed, :expired}} ->
        {:error, :storage_unavailable, block(state)}

      {:error, reason} ->
        {:error, normalize_write_error(reason), state}
    end
  end

  @spec finish_owner_down(t(), String.t(), pid()) :: t()
  defp finish_owner_down(state, id, owner_pid) do
    case {Map.fetch(state.active, id), Metadata.get(state.db, id)} do
      {{:ok, %ActiveCapture{owner_pid: ^owner_pid} = active}, {:ok, %{state: :open} = row}} ->
        case finish_active(state, row, active, {:incomplete, :interrupted}, true) do
          {{:ok, _stored}, next_state} -> next_state
          {{:error, _reason}, next_state} -> next_state
        end

      _ ->
        state
    end
  end

  @spec sync_active(ActiveCapture.t(), boolean()) :: :ok | {:error, term()}
  defp sync_active(active, true), do: Blob.sync_and_close_after_down(active)
  defp sync_active(active, false), do: Blob.sync_and_close(active)

  @spec release_excess(t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  defp release_excess(state, conservative_charge, conservative_items, actual_charge, actual_items) do
    excess_bytes = max(conservative_charge - actual_charge, 0)
    excess_items = max(conservative_items - actual_items, 0)

    if excess_bytes == 0 and excess_items == 0 do
      :ok
    else
      _ =
        ArtifactQuota.release_reservation(
          state.quota,
          state.namespace,
          excess_bytes,
          excess_items
        )

      :ok
    end
  end

  @spec metadata_reply(t(), Metadata.mutation(term()), term()) :: {term(), t()}
  defp metadata_reply(state, {:ok, _value}, reply), do: {reply, state}

  defp metadata_reply(state, {:error, {:checkpoint_failed, _}, {:committed, _value}}, _reply),
    do: {{:error, :storage_unavailable}, block(state)}

  defp metadata_reply(state, {:error, reason}, _reply), do: {{:error, reason}, state}

  @spec metadata_fault_opts(t()) :: keyword()
  defp metadata_fault_opts(state) do
    [before_checkpoint: fn -> FaultInjector.run(state.fault_injector, :before_metadata_checkpoint) end]
  end

  @spec fetch_active(t(), String.t()) :: {:ok, ActiveCapture.t()} | {:error, term()}
  defp fetch_active(state, id) do
    case Map.fetch(state.active, id) do
      {:ok, active} -> {:ok, active}
      :error -> {:error, :capture_not_open}
    end
  end

  @spec put_active(t(), ActiveCapture.t()) :: t()
  defp put_active(%__MODULE__{} = state, active) do %__MODULE__{
    state
    | active: Map.put(state.active, active.id, active),
      monitors: Map.put(state.monitors, active.monitor, active.id)
  } end

  @spec replace_active(t(), ActiveCapture.t()) :: t()
  defp replace_active(%__MODULE__{} = state, active), do: %__MODULE__{state | active: Map.put(state.active, active.id, active)}

  @spec drop_active(t(), ActiveCapture.t()) :: t()
  defp drop_active(%__MODULE__{} = state, active) do %__MODULE__{
    state
    | active: Map.delete(state.active, active.id),
      monitors: Map.delete(state.monitors, active.monitor)
  } end

  @spec block(t()) :: t()
  defp block(%__MODULE__{} = state), do: %__MODULE__{state | blocked: true}

  @spec new_open_row(String.t(), String.t(), CaptureSpec.t(), non_neg_integer()) :: Metadata.row()
  defp new_open_row(id, delivery_key, spec, charged_bytes) do
    %{
      id: id,
      delivery_key: delivery_key,
      media_type: spec.media_type,
      mode: spec.mode,
      state: :open,
      capture: nil,
      bytes: 0,
      items: 0,
      sha256: nil,
      charged_bytes: charged_bytes,
      reserved_data: spec.expected_bytes || 0,
      limit_reason: nil
    }
  end

  @spec terminal_row(
          Metadata.row(),
          :complete | {:incomplete, atom()},
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          non_neg_integer()
        ) :: Metadata.row()
  defp terminal_row(row, status, bytes, items, sha256, charged_bytes) do
    %{
      row
      | state: :terminal,
        capture: status,
        bytes: bytes,
        items: items,
        sha256: sha256,
        charged_bytes: charged_bytes,
        limit_reason: nil
    }
  end

  @spec valid_quota_server?(term()) :: boolean()
  defp valid_quota_server?(quota) when is_pid(quota), do: true
  defp valid_quota_server?(quota) when is_atom(quota), do: quota != nil
  defp valid_quota_server?({:global, _name}), do: true
  defp valid_quota_server?({:via, module, _name}) when is_atom(module), do: true
  defp valid_quota_server?(_quota), do: false

  @spec random_id() :: String.t()
  defp random_id, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  @spec normalize_write_error(term()) :: term()
  defp normalize_write_error(:enospc), do: :disk_full
  defp normalize_write_error(:disk_full), do: :disk_full
  defp normalize_write_error({:io, :enospc}), do: :disk_full
  defp normalize_write_error(:artifact_corrupt), do: :artifact_corrupt
  defp normalize_write_error({:unsafe_artifact_file, _path, _type}), do: :artifact_corrupt
  defp normalize_write_error(reason), do: reason
end
