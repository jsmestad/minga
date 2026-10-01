defmodule MingaAgent.ToolRouter.SourceCapture do
  @moduledoc """
  Captures one coherent routed file source into the record-scoped artifact store.

  Routing is identical to `MingaAgent.ToolRouter.read_file/2`, but this path
  also binds the selected bytes to a source identity and atomic generation.
  Disk reads are descriptor-based and bounded; requested line ranges never
  copy the whole file.
  """

  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias Minga.Buffer
  alias Minga.Buffer.Fork
  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output.Revision
  alias MingaAgent.ToolRouter.Context
  alias MingaAgent.Tools.OutputCapture

  @capture_bytes 16 * 1_024 * 1_024
  @all_lines 18_446_744_073_709_551_615
  @image_bytes 5 * 1_024 * 1_024
  @read_bytes 65_536

  @typedoc "Line-oriented source capture options; offsets are one-based at the public tool boundary."
  @type capture_opts :: [offset: pos_integer() | nil, limit: pos_integer() | nil]

  @typep snapshot :: %{
           bytes: binary(),
           status: Output.capture_status(),
           range: Range.t(),
           source_kind: Revision.source_kind(),
           source_id: String.t(),
           generation: non_neg_integer() | nil
         }

  @doc "Captures a routed source once and returns its canonical retained output."
  @spec capture(Context.t(), String.t(), GenServer.server() | nil, term() | nil, capture_opts()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  def capture(%Context{} = context, path, store, delivery_key, opts)
      when is_binary(path) and is_list(opts) do
    with :ok <- validate_capture_opts(opts),
         {:ok, snapshot} <- snapshot(context, path, opts),
         :ok <- validate_snapshot_text(snapshot, path),
         {:ok, revision} <- revision(snapshot) do
      OutputCapture.bytes(store, delivery_key, snapshot.bytes,
        selection: snapshot.range,
        revision: revision,
        capture_status: snapshot.status
      )
    else
      {:image, media_type, bytes, range, source_kind, source_id, generation} ->
        capture_image(store, delivery_key, path, media_type, bytes, range, source_kind, source_id, generation)

      {:stream_disk, open_path, source_kind, source_id, generation} ->
        capture_disk(store, delivery_key, open_path, source_kind, source_id, generation)

      {:error, _reason} = error ->
        error
    end
  end

  @spec snapshot(Context.t(), String.t(), capture_opts()) ::
          {:ok, snapshot()}
          | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(),
             non_neg_integer() | nil}
          | {:error, term()}
  defp snapshot(%Context{project_view: %ProjectView{} = view}, path, opts) do
    relative = project_view_relative_path(view, path)

    try do
      case ProjectView.read_file(view, relative) do
        {:ok, bytes} -> memory_snapshot(bytes, :project_view, path, nil, opts)
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, reason -> {:error, {:project_view_unavailable, reason}}
    end
  end

  defp snapshot(%Context{fork_store: store} = context, path, opts) when store != nil do
    try do
      case BufferForkStore.get(store, path) do
        nil -> snapshot_changeset_or_direct(context, path, opts)
        fork -> fork_snapshot(fork, path, opts)
      end
    catch
      :exit, reason -> {:error, {:fork_unavailable, reason}}
    end
  end

  defp snapshot(%Context{} = context, path, opts),
    do: snapshot_changeset_or_direct(context, path, opts)

  @spec snapshot_changeset_or_direct(Context.t(), String.t(), capture_opts()) ::
          {:ok, snapshot()} | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(), non_neg_integer() | nil} | {:error, term()}
  defp snapshot_changeset_or_direct(%Context{changeset: changeset}, path, opts)
       when changeset != nil and is_pid(changeset) do
    try do
      relative = normalize_changeset_path(changeset, path)

      case Changeset.read_source_with_version(changeset, relative) do
        {:ok, {:memory, bytes}, version} ->
          memory_snapshot(bytes, :changeset, path, version, opts)

        {:ok, {:disk, disk_path}, version} ->
          disk_snapshot(disk_path, opts, :changeset, path, version)

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, reason -> {:error, {:changeset_unavailable, reason}}
    end
  end

  defp snapshot_changeset_or_direct(%Context{}, path, opts) do
    case Buffer.pid_for_path(path) do
      {:ok, buffer} -> buffer_snapshot(buffer, path, opts)
      :not_found -> disk_snapshot(path, opts)
    end
  rescue
    _error -> disk_snapshot(path, opts)
  catch
    :exit, _reason -> disk_snapshot(path, opts)
  end

  @spec buffer_snapshot(GenServer.server(), String.t(), capture_opts()) ::
          {:ok, snapshot()} | {:error, term()}
  defp buffer_snapshot(buffer, path, opts) do
    case requested_lines(opts) do
      nil ->
        {bytes, version} = Buffer.content_with_version(buffer)
        memory_snapshot(bytes, :buffer, path, version, opts)

      {start, count} ->
        {bytes, selected_count, total, version, complete?} =
          Buffer.content_on_lines_with_version(buffer, start, count, @capture_bytes)

        range = range!(:requested, :lines, start, selected_count, total)
        status = if complete?, do: :complete, else: {:incomplete, :capture_byte_limit}
        {:ok, snapshot(bytes, status, range, :buffer, path, version)}
    end
  end

  @spec fork_snapshot(GenServer.server(), String.t(), capture_opts()) ::
          {:ok, snapshot()} | {:error, term()}
  defp fork_snapshot(fork, path, opts) do
    case requested_lines(opts) do
      nil ->
        {bytes, version} = Fork.content_with_version(fork)
        memory_snapshot(bytes, :fork, path, version, opts)

      {start, count} ->
        {bytes, selected_count, total, version, complete?} =
          Fork.content_on_lines_with_version(fork, start, count, @capture_bytes)

        range = range!(:requested, :lines, start, selected_count, total)
        status = if complete?, do: :complete, else: {:incomplete, :capture_byte_limit}
        {:ok, snapshot(bytes, status, range, :fork, path, version)}
    end
  end

  @spec memory_snapshot(
          binary(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil,
          capture_opts()
        ) ::
          {:ok, snapshot()}
          | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(),
             non_neg_integer() | nil}
          | {:error, term()}
  defp memory_snapshot(bytes, source_kind, source_id, generation, opts) do
    case requested_lines(opts) do
      nil -> memory_full_snapshot(bytes, source_kind, source_id, generation)
      {start, count} -> memory_line_snapshot(bytes, start, count, source_kind, source_id, generation)
    end
  end

  @spec memory_full_snapshot(
          binary(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) ::
          {:ok, snapshot()}
          | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(),
             non_neg_integer() | nil}
          | {:error, String.t()}
  defp memory_full_snapshot(bytes, source_kind, source_id, generation) do
    case image_media_type(bytes) do
      {:ok, media_type} when byte_size(bytes) <= @image_bytes ->
        range = range!(:full, :bytes, 0, byte_size(bytes), byte_size(bytes))
        {:image, media_type, bytes, range, source_kind, source_id, generation}

      {:ok, _media_type} ->
        {:error, "image exceeds the 5MiB retained-image limit: #{source_id}"}

      :unknown ->
        bounded_full_snapshot(bytes, source_kind, source_id, generation)
    end
  end

  @spec bounded_full_snapshot(binary(), Revision.source_kind(), String.t(), non_neg_integer() | nil) ::
          {:ok, snapshot()}
  defp bounded_full_snapshot(bytes, source_kind, source_id, generation)
       when byte_size(bytes) <= @capture_bytes do
    range = range!(:full, :bytes, 0, byte_size(bytes), byte_size(bytes))
    {:ok, snapshot(bytes, :complete, range, source_kind, source_id, generation)}
  end

  defp bounded_full_snapshot(bytes, source_kind, source_id, generation) do
    prefix = binary_part(bytes, 0, @capture_bytes)
    range = range!(:captured_prefix, :bytes, 0, byte_size(prefix), :unknown)

    {:ok,
     snapshot(
       prefix,
       {:incomplete, :capture_byte_limit},
       range,
       source_kind,
       source_id,
       generation
     )}
  end

  @spec memory_line_snapshot(
          binary(),
          non_neg_integer(),
          pos_integer(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) :: {:ok, snapshot()}
  defp memory_line_snapshot(bytes, start, count, source_kind, source_id, generation) do
    {selected, selected_count, total, complete?} = select_lines(bytes, start, count, @capture_bytes)
    range = range!(:requested, :lines, start, selected_count, total)
    status = if complete?, do: :complete, else: {:incomplete, :capture_byte_limit}
    {:ok, snapshot(selected, status, range, source_kind, source_id, generation)}
  end

  @spec disk_snapshot(String.t(), capture_opts()) ::
          {:ok, snapshot()}
          | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(),
             non_neg_integer() | nil}
          | {:error, term()}
  defp disk_snapshot(path, opts), do: disk_snapshot(path, opts, :disk, path, nil)

  @spec disk_snapshot(
          String.t(),
          capture_opts(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) ::
          {:ok, snapshot()}
          | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(),
             non_neg_integer() | nil}
          | {:error, term()}
  defp disk_snapshot(open_path, opts, source_kind, source_id, generation) do
    case requested_lines(opts) do
      nil ->
        {:stream_disk, open_path, source_kind, source_id, generation}

      {_start, _count} ->
        case File.open(open_path, [:read, :binary, :raw]) do
          {:ok, io} ->
            try do
              read_disk(io, source_id, opts, source_kind, generation)
            after
              File.close(io)
            end

          {:error, reason} ->
            {:error, disk_error(source_id, reason)}
        end
    end
  end

  @spec read_disk(
          :file.io_device(),
          String.t(),
          capture_opts(),
          Revision.source_kind(),
          non_neg_integer() | nil
        ) ::
          {:ok, snapshot()}
          | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(),
             non_neg_integer() | nil}
          | {:error, term()}
  defp read_disk(io, source_id, opts, source_kind, generation) do
    case requested_lines(opts) do
      nil -> read_disk_full(io, source_id, source_kind, generation)
      {start, count} ->
        read_disk_lines(io, source_id, start, count, source_kind, generation)
    end
  end

  @spec read_disk_full(
          :file.io_device(),
          String.t(),
          Revision.source_kind(),
          non_neg_integer() | nil
        ) ::
          {:ok, snapshot()}
          | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(),
             non_neg_integer() | nil}
          | {:error, term()}
  defp read_disk_full(io, source_id, source_kind, generation) do
    case read_prefix(io, @capture_bytes + 1) do
      {:ok, bytes, eof?} ->
        classify_disk_full(bytes, eof?, source_id, source_kind, generation)

      {:error, reason} ->
        {:error, disk_error(source_id, reason)}
    end
  end

  @spec classify_disk_full(
          binary(),
          boolean(),
          String.t(),
          Revision.source_kind(),
          non_neg_integer() | nil
        ) ::
          {:ok, snapshot()}
          | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(),
             non_neg_integer() | nil}
          | {:error, term()}
  defp classify_disk_full(bytes, eof?, source_id, source_kind, generation) do
    case image_media_type(bytes) do
      {:ok, media_type} when byte_size(bytes) <= @image_bytes and eof? ->
        range = range!(:full, :bytes, 0, byte_size(bytes), byte_size(bytes))
        {:image, media_type, bytes, range, source_kind, source_id, generation}

      {:ok, _media_type} ->
        {:error, "image exceeds the 5MiB retained-image limit: #{source_id}"}

      :unknown ->
        classify_disk_text(bytes, eof?, source_id, source_kind, generation)
    end
  end

  @spec classify_disk_text(
          binary(),
          boolean(),
          String.t(),
          Revision.source_kind(),
          non_neg_integer() | nil
        ) :: {:ok, snapshot()}
  defp classify_disk_text(bytes, true, source_id, source_kind, generation) do
    range = range!(:full, :bytes, 0, byte_size(bytes), byte_size(bytes))
    {:ok, snapshot(bytes, :complete, range, source_kind, source_id, generation)}
  end

  defp classify_disk_text(bytes, false, source_id, source_kind, generation) do
    prefix = binary_part(bytes, 0, @capture_bytes)
    range = range!(:captured_prefix, :bytes, 0, byte_size(prefix), :unknown)

    {:ok,
     snapshot(
       prefix,
       {:incomplete, :capture_byte_limit},
       range,
       source_kind,
       source_id,
       generation
     )}
  end

  @spec read_disk_lines(
          :file.io_device(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          Revision.source_kind(),
          non_neg_integer() | nil
        ) :: {:ok, snapshot()} | {:error, term()}
  defp read_disk_lines(io, source_id, start, count, source_kind, generation) do
    case select_io_lines(io, start, count, @capture_bytes) do
      {:ok, bytes, selected_count, total, complete?} ->
        range = range!(:requested, :lines, start, selected_count, total)
        status = if complete?, do: :complete, else: {:incomplete, :capture_byte_limit}
        {:ok, snapshot(bytes, status, range, source_kind, source_id, generation)}

      {:error, reason} ->
        {:error, disk_error(source_id, reason)}
    end
  end

  @spec capture_disk(
          GenServer.server() | nil,
          term() | nil,
          String.t(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp capture_disk(nil, _delivery_key, _path, _kind, _id, _generation),
    do: {:error, :retention_unavailable}

  defp capture_disk(_store, nil, _path, _kind, _id, _generation),
    do: {:error, :retention_unavailable}

  defp capture_disk(store, delivery_key, path, kind, id, generation) do
    with {:ok, stat} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        stream_disk_file(store, delivery_key, io, path, stat.size, kind, id, generation)
      after
        File.close(io)
      end
    else
      {:error, reason} -> {:error, disk_error(id, reason)}
    end
  end

  @spec stream_disk_file(
          GenServer.server(),
          term(),
          :file.io_device(),
          String.t(),
          non_neg_integer(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp stream_disk_file(store, delivery_key, io, path, size, kind, id, generation) do
    with {:ok, sample} <- read_sample(io),
         media_type <- stream_media_type(sample),
         :ok <- validate_image_size(media_type, size, id),
         {:ok, _position} <- :file.position(io, :bof),
         {:ok, spec} <-
           CaptureSpec.new(
             media_type: media_type,
             mode: :bytes,
             expected_bytes: min(size, stream_limit(media_type)),
             owner_pid: self(),
             delivery_key: delivery_key
           ),
         {:ok, capture} <- ArtifactStore.begin(store, spec) do
      stream_disk_chunks(
        store,
        capture,
        io,
        stream_limit(media_type),
        :crypto.hash_init(:sha256),
        "",
        "",
        media_type,
        path,
        kind,
        id,
        generation
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_sample(:file.io_device()) :: {:ok, binary()} | {:error, term()}
  defp read_sample(io) do
    case IO.binread(io, 12) do
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
      bytes when is_binary(bytes) -> {:ok, bytes}
    end
  end

  @spec stream_media_type(binary()) :: String.t()
  defp stream_media_type(sample) do
    case image_media_type(sample) do
      {:ok, media_type} -> media_type
      :unknown -> "text/plain; charset=utf-8"
    end
  end

  @spec stream_limit(String.t()) :: pos_integer()
  defp stream_limit("image/" <> _format), do: @image_bytes
  defp stream_limit(_media_type), do: @capture_bytes

  @spec validate_image_size(String.t(), non_neg_integer(), String.t()) :: :ok | {:error, String.t()}
  defp validate_image_size("image/" <> _format, size, id) when size > @image_bytes,
    do: {:error, "image exceeds the 5MiB retained-image limit: #{id}"}

  defp validate_image_size(_media_type, _size, _id), do: :ok

  @spec stream_disk_chunks(
          GenServer.server(),
          term(),
          :file.io_device(),
          non_neg_integer(),
          term(),
          binary(),
          binary(),
          String.t(),
          String.t(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp stream_disk_chunks(
         store,
         capture,
         io,
         0,
         hash,
         view,
         utf8_tail,
         media_type,
         path,
         kind,
         id,
         generation
       ) do
    case IO.binread(io, 1) do
      :eof ->
        finish_stream(
          store,
          capture,
          hash,
          view,
          utf8_tail,
          media_type,
          path,
          kind,
          id,
          generation,
          :complete
        )

      {:error, reason} ->
        finish_stream_error(store, capture, {:incomplete, :capture_failed}, disk_error(id, reason))

      _byte ->
        finish_stream_limit(
          store,
          capture,
          hash,
          view,
          utf8_tail,
          media_type,
          path,
          kind,
          id,
          generation
        )
    end
  end

  defp stream_disk_chunks(
         store,
         capture,
         io,
         remaining,
         hash,
         view,
         utf8_tail,
         media_type,
         path,
         kind,
         id,
         generation
       ) do
    case IO.binread(io, min(@read_bytes, remaining)) do
      :eof ->
        finish_stream(
          store,
          capture,
          hash,
          view,
          utf8_tail,
          media_type,
          path,
          kind,
          id,
          generation,
          :complete
        )

      {:error, reason} ->
        finish_stream_error(store, capture, {:incomplete, :capture_failed}, disk_error(id, reason))

      chunk when is_binary(chunk) ->
        append_stream_chunk(
          store,
          capture,
          io,
          remaining,
          hash,
          view,
          utf8_tail,
          media_type,
          path,
          kind,
          id,
          generation,
          chunk
        )
    end
  end

  @spec append_stream_chunk(
          GenServer.server(),
          term(),
          :file.io_device(),
          non_neg_integer(),
          term(),
          binary(),
          binary(),
          String.t(),
          String.t(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil,
          binary()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp append_stream_chunk(
         store,
         capture,
         io,
         remaining,
         hash,
         view,
         utf8_tail,
         media_type,
         path,
         kind,
         id,
         generation,
         chunk
       ) do
    case validate_stream_chunk(media_type, utf8_tail, chunk) do
      {:ok, next_tail} ->
        case ArtifactStore.append(store, capture, chunk, item_ends: []) do
          {:ok, _progress} ->
            next_hash = :crypto.hash_update(hash, chunk)
            next_view = append_view(view, chunk)

            stream_disk_chunks(
              store,
              capture,
              io,
              remaining - byte_size(chunk),
              next_hash,
              next_view,
              next_tail,
              media_type,
              path,
              kind,
              id,
              generation
            )

          {:error, reason} ->
            finish_append_refusal(
              store,
              capture,
              hash,
              view,
              utf8_tail,
              media_type,
              path,
              kind,
              id,
              generation,
              reason
            )
        end

      :invalid ->
        finish_stream_error(
          store,
          capture,
          {:incomplete, :capture_failed},
          "unsupported non-text or image format: #{path}"
        )
    end
  end

  @spec finish_append_refusal(
          GenServer.server(),
          term(),
          term(),
          binary(),
          binary(),
          String.t(),
          String.t(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil,
          term()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp finish_append_refusal(
         store,
         capture,
         _hash,
         _view,
         _tail,
         "image/" <> _format,
         _path,
         _kind,
         _id,
         _generation,
         reason
       ) do
    finish_stream_error(store, capture, stream_incomplete(reason), reason)
  end

  defp finish_append_refusal(
         store,
         capture,
         hash,
         view,
         tail,
         media_type,
         path,
         kind,
         id,
         generation,
         reason
       ) do
    finish_stream(
      store,
      capture,
      hash,
      view,
      tail,
      media_type,
      path,
      kind,
      id,
      generation,
      stream_incomplete(reason)
    )
  end

  @spec append_view(binary(), binary()) :: binary()
  defp append_view(view, _chunk) when byte_size(view) >= 51_203, do: view

  defp append_view(view, chunk),
    do: view <> binary_part(chunk, 0, min(byte_size(chunk), 51_203 - byte_size(view)))

  @spec validate_stream_chunk(String.t(), binary(), binary()) :: {:ok, binary()} | :invalid
  defp validate_stream_chunk("image/" <> _format, _tail, _chunk), do: {:ok, ""}

  defp validate_stream_chunk(_media_type, tail, chunk) do
    bytes = tail <> chunk

    if :binary.match(bytes, <<0>>) == :nomatch do
      utf8_tail(bytes, min(3, byte_size(bytes)))
    else
      :invalid
    end
  end

  @spec utf8_tail(binary(), non_neg_integer()) :: {:ok, binary()} | :invalid
  defp utf8_tail(bytes, max_tail) do
    if String.valid?(bytes) do
      {:ok, ""}
    else
      utf8_incomplete_tail(bytes, max_tail)
    end
  end

  @spec utf8_incomplete_tail(binary(), non_neg_integer()) :: {:ok, binary()} | :invalid
  defp utf8_incomplete_tail(_bytes, 0), do: :invalid

  defp utf8_incomplete_tail(bytes, max_tail) do
    prefix_size = byte_size(bytes) - max_tail
    prefix = binary_part(bytes, 0, prefix_size)

    if String.valid?(prefix) do
      {:ok, binary_part(bytes, prefix_size, max_tail)}
    else
      utf8_incomplete_tail(bytes, max_tail - 1)
    end
  end

  @spec finish_stream_limit(
          GenServer.server(),
          term(),
          term(),
          binary(),
          binary(),
          String.t(),
          String.t(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp finish_stream_limit(
         store,
         capture,
         _hash,
         _view,
         _utf8_tail,
         "image/" <> _format,
         _path,
         _kind,
         id,
         _generation
       ) do
    finish_stream_error(
      store,
      capture,
      {:incomplete, :capture_byte_limit},
      "image exceeds the 5MiB retained-image limit: #{id}"
    )
  end

  defp finish_stream_limit(
         store,
         capture,
         hash,
         view,
         utf8_tail,
         media_type,
         path,
         kind,
         id,
         generation
       ) do
    finish_stream(
      store,
      capture,
      hash,
      view,
      utf8_tail,
      media_type,
      path,
      kind,
      id,
      generation,
      {:incomplete, :capture_byte_limit}
    )
  end

  @spec finish_stream(
          GenServer.server(),
          term(),
          term(),
          binary(),
          binary(),
          String.t(),
          String.t(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil,
          Output.capture_status()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp finish_stream(
         store,
         capture,
         hash,
         view,
         utf8_tail,
         media_type,
         path,
         kind,
         id,
         generation,
         status
       ) do
    if valid_stream_end?(media_type, utf8_tail, status) do
      case ArtifactStore.finish(store, capture, status) do
        {:ok, stored} ->
          build_stream_output(
            stored,
            hash |> :crypto.hash_final() |> Base.encode16(case: :lower),
            view,
            media_type,
            path,
            kind,
            id,
            generation
          )

        {:error, reason} ->
          {:error, reason}
      end
    else
      finish_stream_error(
        store,
        capture,
        {:incomplete, :capture_failed},
        "unsupported non-text or image format: #{path}"
      )
    end
  end

  @spec valid_stream_end?(String.t(), binary(), Output.capture_status()) :: boolean()
  defp valid_stream_end?("image/" <> _format, _tail, _status), do: true
  defp valid_stream_end?(_media_type, "", _status), do: true
  defp valid_stream_end?(_media_type, _tail, {:incomplete, _reason}), do: true
  defp valid_stream_end?(_media_type, _tail, :complete), do: false

  @spec finish_stream_error(GenServer.server(), term(), Output.capture_status(), term()) ::
          {:error, term()}
  defp finish_stream_error(store, capture, status, reason) do
    _result = ArtifactStore.finish(store, capture, status)
    {:error, reason}
  end

  @spec build_stream_output(
          term(),
          binary(),
          binary(),
          String.t(),
          String.t(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp build_stream_output(stored, digest, raw_view, media_type, path, kind, id, generation) do
    reference = stored.reference
    capture = stored.capture
    selection = stream_range(capture, reference.bytes)

    with {:ok, revision} <-
           Revision.new(
             source_kind: kind,
             source_id: id,
             scope: selection,
             generation: generation,
             sha256: digest
           ) do
      build_stream_media_output(reference, capture, selection, revision, raw_view, media_type, path)
    end
  end

  @spec build_stream_media_output(
          Reference.t(),
          Output.capture_status(),
          Range.t(),
          Revision.t(),
          binary(),
          String.t(),
          String.t()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp build_stream_media_output(
         reference,
         capture,
         selection,
         revision,
         _view,
         "image/" <> _ = media_type,
         path
       ) do
    with {:ok, attachment} <- Attachment.image(reference, Path.basename(path)),
         {:ok, output} <-
           Output.new("[image: #{Path.basename(path)} (#{media_type})]", capture, selection,
             reference: reference,
             revision: revision,
             attachments: [attachment],
             presentation: :complete
           ) do
      Output.result(output)
    end
  end

  defp build_stream_media_output(
         reference,
         capture,
         selection,
         revision,
         raw_view,
         _media_type,
         _path
       ) do
    view = MingaAgent.Tools.OutputLimit.utf8_prefix(raw_view, 51_200)

    presentation =
      if reference.bytes > byte_size(view),
        do: {:truncated, reference.bytes - byte_size(view)},
        else: :complete

    with {:ok, output} <-
           Output.new(view, capture, selection,
             reference: reference,
             revision: revision,
             presentation: presentation
           ) do
      Output.result(output)
    end
  end

  @spec stream_range(Output.capture_status(), non_neg_integer()) :: Range.t()
  defp stream_range(:complete, bytes), do: range!(:full, :bytes, 0, bytes, bytes)

  defp stream_range({:incomplete, _reason}, bytes),
    do: range!(:captured_prefix, :bytes, 0, bytes, :unknown)

  @spec stream_incomplete(term()) :: Output.capture_status()
  defp stream_incomplete(reason)
       when reason in [
              :capture_byte_limit,
              :session_disk_quota,
              :root_disk_quota,
              :session_item_quota,
              :root_item_quota,
              :disk_full,
              :interrupted,
              :timeout
            ],
       do: {:incomplete, reason}

  defp stream_incomplete(_reason), do: {:incomplete, :capture_failed}

  @spec capture_image(
          GenServer.server() | nil,
          term() | nil,
          String.t(),
          String.t(),
          binary(),
          Range.t(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp capture_image(store, delivery_key, path, media_type, bytes, range, kind, id, generation) do
    snapshot = snapshot(bytes, :complete, range, kind, id, generation)

    with {:ok, revision} <- revision(snapshot),
         {:ok, output} <-
           OutputCapture.bytes(store, delivery_key, bytes,
             media_type: media_type,
             selection: range,
             revision: revision
           ),
         %Reference{} = reference <- output.reference,
         {:ok, attachment} <- Attachment.image(reference, Path.basename(path)),
         {:ok, image_output} <-
           Output.new("[image: #{Path.basename(path)} (#{media_type})]", output.capture, output.selection,
             reference: reference,
             revision: revision,
             attachments: [attachment],
             presentation: :complete
           ) do
      Output.result(image_output)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :capture_failed}
    end
  end

  @spec revision(snapshot()) :: {:ok, Revision.t()} | {:error, :invalid_revision}
  defp revision(snapshot) do
    Revision.new(
      source_kind: snapshot.source_kind,
      source_id: snapshot.source_id,
      scope: snapshot.range,
      generation: snapshot.generation,
      sha256: Reference.digest(snapshot.bytes)
    )
  end

  @spec snapshot(
          binary(),
          Output.capture_status(),
          Range.t(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) :: snapshot()
  defp snapshot(bytes, status, range, source_kind, source_id, generation) do
    %{
      bytes: bytes,
      status: status,
      range: range,
      source_kind: source_kind,
      source_id: source_id,
      generation: generation
    }
  end

  @spec requested_lines(capture_opts()) :: {non_neg_integer(), pos_integer()} | nil
  defp requested_lines(opts) do
    offset = Keyword.get(opts, :offset)
    limit = Keyword.get(opts, :limit)
    requested_lines(offset, limit)
  end

  @spec requested_lines(term(), term()) :: {non_neg_integer(), pos_integer()} | nil
  defp requested_lines(nil, nil), do: nil
  defp requested_lines(offset, nil) when is_integer(offset) and offset > 0, do: {offset - 1, @all_lines}
  defp requested_lines(nil, limit) when is_integer(limit) and limit > 0, do: {0, limit}

  defp requested_lines(offset, limit)
       when is_integer(offset) and offset > 0 and is_integer(limit) and limit > 0,
       do: {offset - 1, limit}

  defp requested_lines(_offset, _limit), do: {0, @capture_bytes}

  @spec validate_capture_opts(capture_opts()) :: :ok | {:error, String.t()}
  defp validate_capture_opts(opts) do
    offset = Keyword.get(opts, :offset)
    limit = Keyword.get(opts, :limit)

    if valid_optional_positive?(offset) and valid_optional_positive?(limit),
      do: :ok,
      else: {:error, "offset and limit must be positive integers"}
  end

  @spec valid_optional_positive?(term()) :: boolean()
  defp valid_optional_positive?(nil), do: true
  defp valid_optional_positive?(value), do: is_integer(value) and value > 0

  @spec select_lines(binary(), non_neg_integer(), pos_integer(), pos_integer()) ::
          {binary(), non_neg_integer(), pos_integer(), boolean()}
  defp select_lines(bytes, start, count, max_bytes) do
    state = select_chunk(bytes, start, count, max_bytes, {[], 0, 0, true})
    {chunks, retained, newlines, complete?} = state
    total = newlines + 1
    selected_count = min(max(total - start, 0), count)
    {chunks |> Enum.reverse() |> IO.iodata_to_binary(), selected_count, total, complete? and retained <= max_bytes}
  end

  @spec select_io_lines(:file.io_device(), non_neg_integer(), pos_integer(), pos_integer()) ::
          {:ok, binary(), non_neg_integer(), pos_integer(), boolean()} | {:error, term()}
  defp select_io_lines(io, start, count, max_bytes) do
    select_io_lines(io, start, count, max_bytes, {[], 0, 0, true})
  end

  @spec select_io_lines(
          :file.io_device(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          {[binary()], non_neg_integer(), non_neg_integer(), boolean()}
        ) :: {:ok, binary(), non_neg_integer(), pos_integer(), boolean()} | {:error, term()}
  defp select_io_lines(io, start, count, max_bytes, state) do
    case IO.binread(io, @read_bytes) do
      :eof ->
        {chunks, _retained, newlines, complete?} = state
        total = newlines + 1
        selected_count = min(max(total - start, 0), count)
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), selected_count, total, complete?}

      {:error, reason} ->
        {:error, reason}

      chunk when is_binary(chunk) ->
        next = select_chunk(chunk, start, count, max_bytes, state)
        select_io_lines(io, start, count, max_bytes, next)
    end
  end

  @spec select_chunk(
          binary(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          {[binary()], non_neg_integer(), non_neg_integer(), boolean()}
        ) :: {[binary()], non_neg_integer(), non_neg_integer(), boolean()}
  defp select_chunk(chunk, start, count, max_bytes, state) do
    select_segments(chunk, :binary.matches(chunk, "\n"), 0, start, count, max_bytes, state)
  end

  @spec select_segments(
          binary(),
          [{non_neg_integer(), pos_integer()}],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          {[binary()], non_neg_integer(), non_neg_integer(), boolean()}
        ) :: {[binary()], non_neg_integer(), non_neg_integer(), boolean()}
  defp select_segments(chunk, [], offset, start, count, max_bytes, state) do
    segment = binary_part(chunk, offset, byte_size(chunk) - offset)
    retain_segment(segment, start, count, max_bytes, state)
  end

  defp select_segments(chunk, [{newline, 1} | rest], offset, start, count, max_bytes, state) do
    segment = binary_part(chunk, offset, newline - offset + 1)
    state = retain_segment(segment, start, count, max_bytes, state)
    {chunks, retained, line, complete?} = state
    next = {chunks, retained, line + 1, complete?}
    select_segments(chunk, rest, newline + 1, start, count, max_bytes, next)
  end

  @spec retain_segment(
          binary(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          {[binary()], non_neg_integer(), non_neg_integer(), boolean()}
        ) :: {[binary()], non_neg_integer(), non_neg_integer(), boolean()}
  defp retain_segment(segment, start, count, max_bytes, {chunks, retained, line, complete?})
       when line >= start and line < start + count and retained < max_bytes do
    accepted = min(byte_size(segment), max_bytes - retained)
    prefix = binary_part(segment, 0, accepted)
    chunks = if prefix == "", do: chunks, else: [prefix | chunks]
    {chunks, retained + accepted, line, complete? and accepted == byte_size(segment)}
  end

  defp retain_segment(segment, start, count, _max_bytes, {chunks, retained, line, _complete?})
       when line >= start and line < start + count and byte_size(segment) > 0 do
    {chunks, retained, line, false}
  end

  defp retain_segment(_segment, _start, _count, _max_bytes, state), do: state

  @spec read_prefix(:file.io_device(), pos_integer()) :: {:ok, binary(), boolean()} | {:error, term()}
  defp read_prefix(io, limit), do: read_prefix(io, limit, [], 0)

  @spec read_prefix(:file.io_device(), pos_integer(), [binary()], non_neg_integer()) ::
          {:ok, binary(), boolean()} | {:error, term()}
  defp read_prefix(_io, limit, chunks, size) when size >= limit do
    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), false}
  end

  defp read_prefix(io, limit, chunks, size) do
    case IO.binread(io, min(@read_bytes, limit - size)) do
      :eof -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), true}
      {:error, reason} -> {:error, reason}
      chunk when is_binary(chunk) -> read_prefix(io, limit, [chunk | chunks], size + byte_size(chunk))
    end
  end

  @spec validate_snapshot_text(snapshot(), String.t()) :: :ok | {:error, String.t()}
  defp validate_snapshot_text(%{bytes: bytes, status: :complete}, path),
    do: validate_complete_text(bytes, path)

  defp validate_snapshot_text(%{bytes: bytes, status: {:incomplete, _reason}}, path) do
    valid_prefix? =
      :binary.match(bytes, <<0>>) == :nomatch and
        match?({:ok, _tail}, utf8_tail(bytes, min(3, byte_size(bytes))))

    if valid_prefix?, do: :ok, else: {:error, "unsupported non-text or image format: #{path}"}
  end

  @spec validate_complete_text(binary(), String.t()) :: :ok | {:error, String.t()}
  defp validate_complete_text("", _path), do: :ok

  defp validate_complete_text(bytes, path) do
    if String.valid?(bytes) and :binary.match(bytes, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, "unsupported non-text or image format: #{path}"}
  end

  @spec image_media_type(binary()) :: {:ok, String.t()} | :unknown
  defp image_media_type(<<0x89, "PNG\r\n\x1A\n", _::binary>>), do: {:ok, "image/png"}
  defp image_media_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp image_media_type(<<"GIF87a", _::binary>>), do: {:ok, "image/gif"}
  defp image_media_type(<<"GIF89a", _::binary>>), do: {:ok, "image/gif"}
  defp image_media_type(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp image_media_type(_bytes), do: :unknown

  @spec range!(Range.kind(), Range.unit(), non_neg_integer(), non_neg_integer(), Range.total()) :: Range.t()
  defp range!(kind, unit, start, count, total) do
    {:ok, range} = Range.new(kind, unit, start, count, total)
    range
  end

  @spec project_view_relative_path(ProjectView.t(), String.t()) :: String.t()
  defp project_view_relative_path(%ProjectView{} = view, path) do
    path
    |> Path.relative_to(view.project_root)
    |> String.trim_leading("/")
    |> String.trim_leading("./")
  end

  @spec normalize_changeset_path(pid(), String.t()) :: String.t()
  defp normalize_changeset_path(changeset, path) do
    Path.relative_to(path, Changeset.project_root(changeset))
  end

  @spec disk_error(String.t(), term()) :: String.t()
  defp disk_error(path, :enoent), do: "file not found: #{path}"
  defp disk_error(path, :eisdir), do: "#{path} is a directory, not a file. Use list_directory instead."
  defp disk_error(path, reason), do: "failed to read #{path}: #{inspect(reason)}"
end
