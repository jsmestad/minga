defmodule MingaAgent.ArtifactStore.Blob do
  @moduledoc "Versioned blob/index files, bounded verified reads, and crash recovery."

  alias MingaAgent.ArtifactStorage.FaultInjector
  alias MingaAgent.ArtifactStorage.Files
  alias MingaAgent.ArtifactStore.ActiveCapture
  alias MingaAgent.ArtifactStore.Integrity
  alias MingaAgent.ArtifactStore.Limits
  alias MingaAgent.ArtifactStore.Paths

  @blob_header <<"MINGARTB", 1::unsigned-big-32, 0::unsigned-big-32>>
  @index_header <<"MINGARTI", 1::unsigned-big-32, 0::unsigned-big-32>>

  @type measured :: %{bytes: non_neg_integer(), items: non_neg_integer()}
  @type recovered :: %{
          bytes: non_neg_integer(),
          items: non_neg_integer(),
          sha256: String.t(),
          rows: [Integrity.block_row()]
        }
  @type block_hash :: {non_neg_integer(), binary()}

  @doc "Creates both exclusive partial files after quota admission."
  @spec create(Paths.t()) ::
          {:ok, Files.io_device(), Files.io_device()} | {:error, term()}
  def create(%Paths{} = paths) do
    case Files.create_capture_file(paths.blob_partial, @blob_header) do
      {:ok, data_io} -> create_index_file(paths, data_io)
      {:error, :enospc} -> {:error, :disk_full}
      {:error, _reason} = error -> error
    end
  end

  @doc "Appends one admitted chunk and returns the single encoded offset binary written."
  @spec append(ActiveCapture.t(), binary(), [pos_integer()], FaultInjector.t()) ::
          {:ok, binary()} | {:error, term()}
  def append(%ActiveCapture{} = active, chunk, item_ends, fault_injector) do
    encoded_offsets = encode_offsets(active.bytes, item_ends)

    with :ok <- :file.write(active.data_io, chunk),
         :ok <- FaultInjector.run(fault_injector, :before_index_write),
         :ok <- :file.write(active.index_io, encoded_offsets) do
      {:ok, encoded_offsets}
    else
      {:error, :enospc} -> {:error, :disk_full}
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  @doc "Synchronizes and closes both partial capture files."
  @spec sync_and_close(ActiveCapture.t()) :: :ok | {:error, term()}
  def sync_and_close(%ActiveCapture{} = active) do
    result = sync_handles(active)
    _ = ActiveCapture.close(active)
    normalize_io_result(result)
  end

  @doc "Synchronizes and closes after its owner monitor has already fired."
  @spec sync_and_close_after_down(ActiveCapture.t()) :: :ok | {:error, term()}
  def sync_and_close_after_down(%ActiveCapture{} = active) do
    result = sync_handles(active)
    _ = ActiveCapture.close_after_down(active)
    normalize_io_result(result)
  end

  @doc "Promotes partial files by rename and synchronizes the namespace directory."
  @spec promote(Paths.t(), String.t()) :: :ok | {:error, term()}
  def promote(%Paths{} = paths, directory) do
    with :ok <- promote_one(paths.blob_partial, paths.blob),
         :ok <- promote_one(paths.index_partial, paths.index),
         :ok <- Files.sync_directory(directory) do
      :ok
    end
  end

  @doc "Validates exact terminal headers and sizes without scanning content."
  @spec validate_final(Paths.t(), :bytes | :items, non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  def validate_final(%Paths{} = paths, mode, total_bytes, total_items) do
    with {:ok, ^total_bytes} <- validated_size(paths.blob, @blob_header),
         {:ok, index_size} <- validated_size(paths.index, @index_header),
         :ok <- validate_terminal_index_size(mode, index_size, total_items) do
      :ok
    else
      {:ok, _different} -> {:error, :artifact_corrupt}
      {:error, :enoent} -> {:error, :artifact_corrupt}
      {:error, _reason} = error -> normalize_artifact_error(error)
    end
  end

  @doc "Repairs an open index suffix and rebuilds exact terminal facts in one bounded pass."
  @spec recover_open(Paths.t(), :bytes | :items) :: {:ok, recovered()} | {:error, term()}
  def recover_open(%Paths{} = paths, mode) do
    with {:ok, blob_path} <- existing_path(paths.blob, paths.blob_partial),
         {:ok, index_path} <- existing_path(paths.index, paths.index_partial),
         {:ok, bytes} <- validated_size(blob_path, @blob_header),
         {:ok, index_size} <- validated_size(index_path, @index_header),
         {:ok, items} <- repair_index(index_path, index_size, bytes, mode),
         :ok <- Files.sync_regular(blob_path),
         {:ok, sha256, blob_rows} <- hash_file(blob_path, @blob_header, bytes, :blob, true),
         {:ok, _unused, index_rows} <-
           hash_file(index_path, @index_header, items * 8, :index, false) do
      {:ok, %{bytes: bytes, items: items, sha256: sha256, rows: blob_rows ++ index_rows}}
    else
      {:error, _reason} = error -> normalize_artifact_error(error)
    end
  end

  @doc "Returns zero-based fixed blocks touched by one exact content range."
  @spec block_numbers(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          [non_neg_integer()]
  def block_numbers(_start, 0, _total), do: []

  def block_numbers(start, count, total)
      when start >= 0 and count > 0 and start + count <= total do
    first = div(start, Limits.integrity_block_bytes())
    last = div(start + count - 1, Limits.integrity_block_bytes())
    Enum.to_list(first..last)
  end

  @doc "Returns the one or two index blocks containing requested item boundaries."
  @spec item_boundary_block_numbers(non_neg_integer(), non_neg_integer()) ::
          [non_neg_integer()]
  def item_boundary_block_numbers(_start, 0), do: []

  def item_boundary_block_numbers(start, count) when start >= 0 and count > 0 do
    last_entry = start + count - 1
    numbers = [div(last_entry * 8, Limits.integrity_block_bytes())]

    case start do
      0 -> numbers
      _positive -> Enum.sort(Enum.uniq([div((start - 1) * 8, Limits.integrity_block_bytes()) | numbers]))
    end
  end

  @doc "Validates final layout and returns exact bytes from verified touched payload blocks."
  @spec fetch_bytes(
          Paths.t(),
          non_neg_integer(),
          non_neg_integer(),
          :bytes | :items,
          non_neg_integer(),
          non_neg_integer(),
          [block_hash()]
        ) :: {:ok, binary()} | {:error, term()}
  def fetch_bytes(paths, start, count, mode, total_bytes, total_items, hashes) do
    with :ok <- validate_final(paths, mode, total_bytes, total_items),
         {:ok, bytes} <- verified_slice(paths.blob, @blob_header, start, count, total_bytes, hashes) do
      {:ok, bytes}
    end
  end

  @doc "Validates consumed offset blocks and returns exact payload byte boundaries."
  @spec fetch_item_bounds(
          Paths.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [block_hash()]
        ) :: {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def fetch_item_bounds(paths, start, count, total_bytes, total_items, hashes) do
    with :ok <- validate_final(paths, :items, total_bytes, total_items),
         {:ok, blocks} <- verified_blocks(paths.index, @index_header, total_items * 8, hashes),
         {:ok, bounds} <- decode_item_bounds(blocks, start, count, total_bytes) do
      {:ok, bounds}
    end
  end

  @doc "Returns an exact payload span after verifying every touched payload block."
  @spec fetch_payload(
          Paths.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [block_hash()]
        ) :: {:ok, binary()} | {:error, term()}
  def fetch_payload(paths, start, count, total_bytes, hashes),
    do: verified_slice(paths.blob, @blob_header, start, count, total_bytes, hashes)

  @doc "Deletes promoted and partial regular files before quota release."
  @spec delete(Paths.t()) :: :ok | {:error, term()}
  def delete(%Paths{} = paths) do
    [paths.blob, paths.index, paths.blob_partial, paths.index_partial]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case Files.remove_regular(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec create_index_file(Paths.t(), Files.io_device()) ::
          {:ok, Files.io_device(), Files.io_device()} | {:error, term()}
  defp create_index_file(paths, data_io) do
    case Files.create_capture_file(paths.index_partial, @index_header) do
      {:ok, index_io} ->
        {:ok, data_io, index_io}

      {:error, reason} ->
        _ = Files.close(data_io)
        _ = Files.remove_regular(paths.blob_partial)
        if reason == :enospc, do: {:error, :disk_full}, else: {:error, reason}
    end
  end

  @spec encode_offsets(non_neg_integer(), [pos_integer()]) :: binary()
  defp encode_offsets(existing_bytes, item_ends) do
    for item_end <- item_ends, into: <<>> do
      <<(existing_bytes + item_end)::unsigned-big-64>>
    end
  end

  @spec sync_handles(ActiveCapture.t()) :: :ok | {:error, term()}
  defp sync_handles(active) do
    with :ok <- :file.sync(active.data_io),
         :ok <- :file.sync(active.index_io) do
      :ok
    end
  end

  @spec promote_one(String.t(), String.t()) :: :ok | {:error, term()}
  defp promote_one(partial, final) do
    case {File.lstat(partial), File.lstat(final)} do
      {{:ok, %File.Stat{type: :regular}}, {:error, :enoent}} -> Files.rename(partial, final)
      {{:error, :enoent}, {:ok, %File.Stat{type: :regular}}} -> :ok
      {{:ok, %File.Stat{type: :regular}}, {:ok, %File.Stat{type: :regular}}} ->
        Files.remove_regular(partial)

      {{:ok, %File.Stat{type: type}}, _} ->
        {:error, {:unsafe_artifact_file, partial, type}}

      {_, {:ok, %File.Stat{type: type}}} ->
        {:error, {:unsafe_artifact_file, final, type}}

      {{:error, reason}, _} ->
        {:error, reason}

      {_, {:error, reason}} ->
        {:error, reason}
    end
  end

  @spec existing_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp existing_path(final, partial) do
    case File.lstat(final) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, final}
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_artifact_file, final, type}}
      {:error, :enoent} -> partial_path(partial)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec partial_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp partial_path(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, path}
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_artifact_file, path, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validated_size(String.t(), binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp validated_size(path, expected_header) do
    with {:ok, size} <- Files.regular_size(path),
         true <- size >= byte_size(expected_header),
         {:ok, header} <- read_at_path(path, 0, byte_size(expected_header)) do
      if header == expected_header,
        do: {:ok, size - byte_size(expected_header)},
        else: {:error, :artifact_corrupt}
    else
      false -> {:error, :artifact_corrupt}
      {:error, _reason} = error -> error
    end
  end

  @spec validate_terminal_index_size(:bytes | :items, non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :artifact_corrupt}
  defp validate_terminal_index_size(:bytes, 0, 0), do: :ok
  defp validate_terminal_index_size(:items, size, items) when size == items * 8, do: :ok
  defp validate_terminal_index_size(_mode, _size, _items), do: {:error, :artifact_corrupt}

  @spec repair_index(String.t(), non_neg_integer(), non_neg_integer(), :bytes | :items) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp repair_index(path, index_size, _blob_size, :bytes), do: truncate_index(path, index_size, 0)

  defp repair_index(path, index_size, blob_size, :items) do
    complete_bytes = index_size - rem(index_size, 8)

    case Files.open_read_write(path) do
      {:ok, io} ->
        result =
          with {:ok, valid_items} <- scan_offset_chunks(io, 0, complete_bytes, 0, 0, blob_size),
               {:ok, ^valid_items} <- truncate_open_index(io, index_size, valid_items) do
            {:ok, valid_items}
          end

        _ = Files.close(io)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @spec truncate_index(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp truncate_index(path, current_size, items) do
    case Files.open_read_write(path) do
      {:ok, io} ->
        result = truncate_open_index(io, current_size, items)
        _ = Files.close(io)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @spec truncate_open_index(Files.io_device(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp truncate_open_index(io, current_size, items) do
    desired_size = items * 8

    with :ok <- maybe_truncate(io, current_size, desired_size),
         :ok <- :file.sync(io) do
      {:ok, items}
    end
  end

  @spec maybe_truncate(Files.io_device(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp maybe_truncate(_io, size, size), do: :ok

  defp maybe_truncate(io, _current_size, desired_size) do
    with {:ok, _position} <- :file.position(io, Limits.index_header_bytes() + desired_size),
         :ok <- :file.truncate(io) do
      :ok
    end
  end

  @spec scan_offset_chunks(
          Files.io_device(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  defp scan_offset_chunks(_io, position, complete_bytes, _previous, items, _blob_size)
       when position == complete_bytes,
       do: {:ok, items}

  defp scan_offset_chunks(io, position, complete_bytes, previous, items, blob_size) do
    count = min(Limits.integrity_block_bytes(), complete_bytes - position)

    with {:ok, bytes} <- read_exact(io, Limits.index_header_bytes() + position, count) do
      case scan_offset_entries(bytes, previous, items, blob_size) do
        {:continue, next_previous, next_items} ->
          scan_offset_chunks(
            io,
            position + count,
            complete_bytes,
            next_previous,
            next_items,
            blob_size
          )

        {:stop, valid_items} ->
          {:ok, valid_items}
      end
    end
  end

  @spec scan_offset_entries(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:continue, non_neg_integer(), non_neg_integer()} | {:stop, non_neg_integer()}
  defp scan_offset_entries(<<>>, previous, items, _blob_size),
    do: {:continue, previous, items}

  defp scan_offset_entries(<<offset::unsigned-big-64, rest::binary>>, previous, items, blob_size) do
    case offset > previous and offset <= blob_size do
      true -> scan_offset_entries(rest, offset, items + 1, blob_size)
      false -> {:stop, items}
    end
  end

  @spec hash_file(String.t(), binary(), non_neg_integer(), Integrity.file_kind(), boolean()) ::
          {:ok, String.t(), [Integrity.block_row()]} | {:error, term()}
  defp hash_file(path, header, total, kind, whole_payload?) do
    case Files.open_read(path) do
      {:ok, io} ->
        context = initial_whole_context(whole_payload?)
        result = hash_file_blocks(io, byte_size(header), total, kind, 0, context, [], whole_payload?)
        _ = Files.close(io)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @spec hash_file_blocks(
          Files.io_device(),
          non_neg_integer(),
          non_neg_integer(),
          Integrity.file_kind(),
          non_neg_integer(),
          term(),
          [Integrity.block_row()],
          boolean()
        ) :: {:ok, String.t(), [Integrity.block_row()]} | {:error, term()}
  defp hash_file_blocks(_io, _header_size, 0, _kind, _number, context, rows, whole?) do
    {:ok, finalize_whole(context, whole?), Enum.reverse(rows)}
  end

  defp hash_file_blocks(io, header_size, remaining, kind, number, context, rows, whole?) do
    count = min(Limits.integrity_block_bytes(), remaining)
    offset = header_size + number * Limits.integrity_block_bytes()

    with {:ok, bytes} <- read_exact(io, offset, count) do
      next_context = maybe_hash_whole(context, bytes, whole?)
      row = {kind, number, :crypto.hash(:sha256, bytes)}
      hash_file_blocks(io, header_size, remaining - count, kind, number + 1, next_context, [row | rows], whole?)
    end
  end

  @spec maybe_hash_whole(term(), binary(), boolean()) :: term()
  defp maybe_hash_whole(context, bytes, true), do: :crypto.hash_update(context, bytes)
  defp maybe_hash_whole(context, _bytes, false), do: context

  @spec initial_whole_context(boolean()) :: term() | nil
  defp initial_whole_context(true), do: :crypto.hash_init(:sha256)
  defp initial_whole_context(false), do: nil

  @spec finalize_whole(term() | nil, boolean()) :: String.t()
  defp finalize_whole(context, true),
    do: context |> :crypto.hash_final() |> Base.encode16(case: :lower)

  defp finalize_whole(nil, false), do: ""

  @spec verified_slice(
          String.t(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [block_hash()]
        ) :: {:ok, binary()} | {:error, term()}
  defp verified_slice(_path, _header, _start, 0, _total, []), do: {:ok, <<>>}

  defp verified_slice(path, header, start, count, total, hashes) do
    expected = block_numbers(start, count, total)

    with :ok <- require_hash_numbers(hashes, expected) do
      case Files.open_read(path) do
        {:ok, io} ->
          result =
            read_verified_slices(
              io,
              byte_size(header),
              total,
              start,
              start + count,
              hashes,
              []
            )

          _ = Files.close(io)
          result

        {:error, :enoent} ->
          {:error, :artifact_corrupt}

        {:error, reason} ->
          normalize_artifact_error({:error, reason})
      end
    end
  end

  @spec read_verified_slices(
          Files.io_device(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [block_hash()],
          [binary()]
        ) :: {:ok, binary()} | {:error, term()}
  defp read_verified_slices(_io, _header_size, _total, _start, _last, [], slices),
    do: {:ok, slices |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_verified_slices(
         io,
         header_size,
         total,
         start,
         last,
         [{number, expected} | rest],
         slices
       ) do
    block_start = number * Limits.integrity_block_bytes()
    block_count = min(Limits.integrity_block_bytes(), total - block_start)

    with true <- block_count > 0,
         {:ok, block} <- read_exact(io, header_size + block_start, block_count),
         true <- :crypto.hash(:sha256, block) == expected do
      slice_start = max(start, block_start) - block_start
      slice_end = min(last, block_start + block_count) - block_start
      slice = binary_part(block, slice_start, slice_end - slice_start)
      read_verified_slices(io, header_size, total, start, last, rest, [slice | slices])
    else
      false -> {:error, :artifact_corrupt}
      {:error, _reason} = error -> error
    end
  end

  @spec verified_blocks(String.t(), binary(), non_neg_integer(), [block_hash()]) ::
          {:ok, %{optional(non_neg_integer()) => binary()}} | {:error, term()}
  defp verified_blocks(_path, _header, _total, []), do: {:ok, %{}}

  defp verified_blocks(path, header, total, hashes) do
    case Files.open_read(path) do
      {:ok, io} ->
        result = read_verified_blocks(io, byte_size(header), total, hashes, %{})
        _ = Files.close(io)
        result

      {:error, :enoent} ->
        {:error, :artifact_corrupt}

      {:error, reason} ->
        normalize_artifact_error({:error, reason})
    end
  end

  @spec read_verified_blocks(
          Files.io_device(),
          non_neg_integer(),
          non_neg_integer(),
          [block_hash()],
          %{optional(non_neg_integer()) => binary()}
        ) :: {:ok, %{optional(non_neg_integer()) => binary()}} | {:error, term()}
  defp read_verified_blocks(_io, _header_size, _total, [], blocks), do: {:ok, blocks}

  defp read_verified_blocks(io, header_size, total, [{number, expected} | rest], blocks) do
    block_start = number * Limits.integrity_block_bytes()
    count = min(Limits.integrity_block_bytes(), total - block_start)

    with true <- count > 0,
         {:ok, bytes} <- read_exact(io, header_size + block_start, count),
         true <- :crypto.hash(:sha256, bytes) == expected do
      read_verified_blocks(io, header_size, total, rest, Map.put(blocks, number, bytes))
    else
      false -> {:error, :artifact_corrupt}
      {:error, _reason} = error -> error
    end
  end

  @spec require_hash_numbers([block_hash()], [non_neg_integer()]) ::
          :ok | {:error, :artifact_corrupt}
  defp require_hash_numbers(hashes, expected) do
    if Enum.map(hashes, &elem(&1, 0)) == expected,
      do: :ok,
      else: {:error, :artifact_corrupt}
  end

  @spec decode_item_bounds(
          %{optional(non_neg_integer()) => binary()},
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, :artifact_corrupt}
  defp decode_item_bounds(_blocks, start, 0, total_bytes) do
    if start == 0, do: {:ok, {0, 0}}, else: {:ok, {total_bytes, total_bytes}}
  end

  defp decode_item_bounds(blocks, start, count, total_bytes) do
    with {:ok, first} <- offset_before(blocks, start),
         {:ok, last} <- offset_at(blocks, start + count - 1),
         true <- first <= last and last <= total_bytes do
      {:ok, {first, last}}
    else
      _ -> {:error, :artifact_corrupt}
    end
  end

  @spec offset_before(%{optional(non_neg_integer()) => binary()}, non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :artifact_corrupt}
  defp offset_before(_blocks, 0), do: {:ok, 0}
  defp offset_before(blocks, start), do: offset_at(blocks, start - 1)

  @spec offset_at(%{optional(non_neg_integer()) => binary()}, non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :artifact_corrupt}
  defp offset_at(blocks, entry) do
    byte_offset = entry * 8
    number = div(byte_offset, Limits.integrity_block_bytes())
    within = rem(byte_offset, Limits.integrity_block_bytes())

    case Map.fetch(blocks, number) do
      {:ok, block} when within + 8 <= byte_size(block) ->
        <<_prefix::binary-size(^within), offset::unsigned-big-64, _rest::binary>> = block
        {:ok, offset}

      _missing ->
        {:error, :artifact_corrupt}
    end
  end

  @spec read_at_path(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  defp read_at_path(path, offset, count) do
    case Files.open_read(path) do
      {:ok, io} ->
        result = read_exact(io, offset, count)
        _ = Files.close(io)
        result

      {:error, _reason} = error ->
        error
    end
  end

  @spec read_exact(Files.io_device(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  defp read_exact(_io, _offset, 0), do: {:ok, <<>>}

  defp read_exact(io, offset, count) do
    case :file.pread(io, offset, count) do
      {:ok, bytes} when byte_size(bytes) == count -> {:ok, bytes}
      {:ok, _short} -> {:error, :artifact_corrupt}
      :eof -> {:error, :artifact_corrupt}
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  @spec normalize_io_result(:ok | {:error, term()}) :: :ok | {:error, term()}
  defp normalize_io_result(:ok), do: :ok
  defp normalize_io_result({:error, :enospc}), do: {:error, :disk_full}
  defp normalize_io_result({:error, reason}), do: {:error, {:io, reason}}

  @spec normalize_artifact_error({:error, term()}) :: {:error, term()}
  defp normalize_artifact_error({:error, :artifact_corrupt} = error), do: error
  defp normalize_artifact_error({:error, {:unsafe_artifact_file, _path, _type}}),
    do: {:error, :artifact_corrupt}

  defp normalize_artifact_error({:error, {:io, _reason}} = error), do: error
  defp normalize_artifact_error({:error, reason}), do: {:error, {:io, reason}}
end
