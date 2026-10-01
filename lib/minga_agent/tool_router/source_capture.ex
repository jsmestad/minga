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
  alias MingaAgent.ProjectView.Source
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Limitation
  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.LineSelection
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output.Revision
  alias MingaAgent.ToolRouter.Context
  alias MingaAgent.Tools.OutputCapture

  @typep owner :: Source.owner()
  @capture_bytes 16 * 1_024 * 1_024
  @all_lines 18_446_744_073_709_551_615
  @image_bytes 5 * 1_024 * 1_024
  @read_bytes 65_536

  @typedoc "Source capture options plus the exact retained-image delivery decision."
  @type capture_opts :: [
          offset: pos_integer() | nil,
          limit: pos_integer() | nil,
          image_tool_result_delivery: MingaAgent.ModelSelection.image_tool_result_delivery()
        ]

  @typep snapshot :: %{
           bytes: binary(),
           status: Output.capture_status(),
           range: Range.t(),
           source_kind: Revision.source_kind(),
           source_id: String.t(),
           generation: non_neg_integer() | nil
         }

  @typep snapshot_result ::
           {:ok, snapshot()}
           | {:stream_disk, String.t(), Revision.source_kind(), String.t(),
              non_neg_integer() | nil}
           | {:image, String.t(), binary(), Range.t(), Revision.source_kind(), String.t(),
              non_neg_integer() | nil}
           | {:error, term()}

  @typep disk_open_context :: %{
           store: GenServer.server(),
           delivery_key: term(),
           io: :file.io_device(),
           path: String.t(),
           source_kind: Revision.source_kind(),
           source_id: String.t(),
           generation: non_neg_integer() | nil,
           image_delivery: MingaAgent.ModelSelection.image_tool_result_delivery()
         }
  @typep disk_stream_context :: %{
           store: GenServer.server(),
           io: :file.io_device(),
           capture: term(),
           media_type: String.t(),
           path: String.t(),
           source_kind: Revision.source_kind(),
           source_id: String.t(),
           generation: non_neg_integer() | nil
         }
  @typep stream_progress :: {non_neg_integer(), term(), binary(), binary()}

  @doc "Captures a routed source once and returns its canonical retained output."
  @spec capture(Context.t(), String.t(), GenServer.server() | nil, term() | nil, capture_opts()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  def capture(%Context{} = context, path, store, delivery_key, opts)
      when is_binary(path) and is_list(opts) do
    image_delivery = image_delivery(opts)

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
        with :ok <- allow_image_delivery(image_delivery, path, media_type) do
          capture_image(
            store,
            delivery_key,
            path,
            media_type,
            bytes,
            range,
            {source_kind, source_id, generation}
          )
        end

      {:stream_disk, open_path, source_kind, source_id, generation} ->
        capture_disk(
          store,
          delivery_key,
          open_path,
          source_kind,
          source_id,
          generation,
          image_delivery
        )

      {:error, _reason} = error ->
        error
    end
  end

  @spec snapshot(Context.t(), String.t(), capture_opts()) :: snapshot_result()
  defp snapshot(%Context{project_view: %ProjectView{} = view}, path, opts) do
    with {:ok, source} <- ProjectView.resolve_source(view, project_view_relative_path(view, path)) do
      owner_snapshot(source.owner, :project_view, source.source_id, opts)
    end
  catch
    :exit, reason -> {:error, {:project_view_unavailable, reason}}
  end

  defp snapshot(%Context{fork_store: store} = context, path, opts) when store != nil do
    case BufferForkStore.get(store, path) do
      nil -> snapshot_changeset_or_direct(context, path, opts)
      fork -> owner_snapshot({:fork, fork}, :fork, path, opts)
    end
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  defp snapshot(%Context{} = context, path, opts),
    do: snapshot_changeset_or_direct(context, path, opts)

  @spec snapshot_changeset_or_direct(Context.t(), String.t(), capture_opts()) :: snapshot_result()
  defp snapshot_changeset_or_direct(%Context{changeset: changeset}, path, opts)
       when is_pid(changeset) do
    owner_snapshot(
      {:changeset, changeset, normalize_changeset_path(changeset, path)},
      :changeset,
      path,
      opts
    )
  catch
    :exit, reason -> {:error, {:changeset_unavailable, reason}}
  end

  defp snapshot_changeset_or_direct(%Context{}, path, opts) do
    case Buffer.pid_for_path(path) do
      {:ok, buffer} -> owner_snapshot({:buffer, buffer}, :buffer, path, opts)
      :not_found -> disk_snapshot(path, opts)
    end
  catch
    :exit, reason -> {:error, {:buffer_lookup_failed, reason}}
  end

  @spec owner_snapshot(owner(), Revision.source_kind(), String.t(), capture_opts()) ::
          snapshot_result()
  defp owner_snapshot({:disk, open_path}, kind, id, opts),
    do: disk_snapshot(open_path, opts, kind, id, nil)

  defp owner_snapshot(owner, kind, id, opts) do
    case read_owner_prefix(owner, 12) do
      {:ok, {:disk, open_path}, version} ->
        disk_snapshot(open_path, opts, kind, id, visible_generation(kind, version))

      {:ok, {:memory, sample, complete?}, version} ->
        with :ok <- preflight_image_sample(sample, id, image_delivery(opts)) do
          select_owner_snapshot(owner, kind, id, opts, sample, complete?, version)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec select_owner_snapshot(
          owner(),
          Revision.source_kind(),
          String.t(),
          capture_opts(),
          binary(),
          boolean(),
          non_neg_integer()
        ) :: snapshot_result()
  defp select_owner_snapshot(owner, kind, id, opts, sample, complete?, version) do
    case {image_media_type(sample), requested_lines(opts)} do
      {{:ok, _media_type}, nil} ->
        full_owner_snapshot(owner, kind, id, sample, complete?, version, @image_bytes + 1)

      {{:ok, _media_type}, _lines} ->
        {:error, "line ranges are unavailable for images: #{id}"}

      {:unknown, nil} ->
        full_owner_snapshot(owner, kind, id, sample, complete?, version, @capture_bytes + 1)

      {:unknown, {start, count}} ->
        line_owner_snapshot(owner, kind, id, start, count, version)
    end
  end

  @spec full_owner_snapshot(
          owner(),
          Revision.source_kind(),
          String.t(),
          binary(),
          boolean(),
          non_neg_integer(),
          pos_integer()
        ) :: snapshot_result()
  defp full_owner_snapshot(_owner, kind, id, sample, true, version, _max_bytes),
    do: memory_full_snapshot(sample, kind, id, visible_generation(kind, version))

  defp full_owner_snapshot(owner, kind, id, _sample, false, version, max_bytes) do
    with {:ok, {:memory, bytes, _complete?}, final_version} <- read_owner_prefix(owner, max_bytes),
         :ok <- coherent_generation(version, final_version, id) do
      memory_full_snapshot(bytes, kind, id, visible_generation(kind, final_version))
    else
      {:ok, {:disk, _path}, _version} -> {:error, {:source_changed_during_capture, id}}
      {:error, _reason} = error -> error
    end
  end

  @spec line_owner_snapshot(
          owner(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: snapshot_result()
  defp line_owner_snapshot(owner, kind, id, start, count, version) do
    with {:ok, {:memory, bytes, selected_count, total, complete?}, final_version} <-
           read_owner_lines(owner, start, count, @capture_bytes),
         :ok <- coherent_generation(version, final_version, id),
         {:ok, selected} <- normalize_text_selection(bytes, complete?, id) do
      range = range!(:requested, :lines, start, selected_count, total)
      status = if complete?, do: :complete, else: {:incomplete, :capture_byte_limit}
      {:ok, snapshot(selected, status, range, kind, id, visible_generation(kind, final_version))}
    else
      {:ok, {:disk, _path}, _version} -> {:error, {:source_changed_during_capture, id}}
      {:error, _reason} = error -> error
    end
  end

  @spec coherent_generation(non_neg_integer(), non_neg_integer(), String.t()) ::
          :ok | {:error, term()}
  defp coherent_generation(version, version, _id), do: :ok
  defp coherent_generation(_probe, _final, id), do: {:error, {:source_changed_during_capture, id}}

  @spec visible_generation(Revision.source_kind(), non_neg_integer()) :: non_neg_integer() | nil
  defp visible_generation(:project_view, _version), do: nil
  defp visible_generation(_kind, version), do: version

  @spec read_owner_prefix(owner(), pos_integer()) ::
          MingaAgent.Changeset.SourceRead.prefix_result()
  defp read_owner_prefix({:buffer, pid}, max_bytes) do
    {bytes, version, complete?} = Buffer.content_prefix_with_version(pid, max_bytes)
    {:ok, {:memory, bytes, complete?}, version}
  catch
    :exit, reason -> {:error, {:buffer_unavailable, reason}}
  end

  defp read_owner_prefix({:fork, pid}, max_bytes) do
    {bytes, version, complete?} = Fork.content_prefix_with_version(pid, max_bytes)
    {:ok, {:memory, bytes, complete?}, version}
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  defp read_owner_prefix({:changeset, pid, path}, max_bytes) do
    Changeset.read_source_prefix_with_version(pid, path, max_bytes)
  catch
    :exit, reason -> {:error, {:changeset_unavailable, reason}}
  end

  @spec read_owner_lines(owner(), non_neg_integer(), pos_integer(), pos_integer()) ::
          MingaAgent.Changeset.SourceRead.lines_result()
  defp read_owner_lines({:buffer, pid}, start, count, max_bytes) do
    {bytes, selected_count, total, version, complete?} =
      Buffer.content_on_lines_with_version(pid, start, count, max_bytes)

    {:ok, {:memory, bytes, selected_count, total, complete?}, version}
  catch
    :exit, reason -> {:error, {:buffer_unavailable, reason}}
  end

  defp read_owner_lines({:fork, pid}, start, count, max_bytes) do
    {bytes, selected_count, total, version, complete?} =
      Fork.content_on_lines_with_version(pid, start, count, max_bytes)

    {:ok, {:memory, bytes, selected_count, total, complete?}, version}
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  defp read_owner_lines({:changeset, pid, path}, start, count, max_bytes) do
    Changeset.read_source_lines_with_version(pid, path, start, count, max_bytes)
  catch
    :exit, reason -> {:error, {:changeset_unavailable, reason}}
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

      {:unsupported, media_type} ->
        {:error, Limitation.image_format(Path.basename(source_id), media_type)}

      :unknown ->
        bounded_full_snapshot(bytes, source_kind, source_id, generation)
    end
  end

  @spec bounded_full_snapshot(
          binary(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) ::
          {:ok, snapshot()} | {:error, String.t()}
  defp bounded_full_snapshot(bytes, source_kind, source_id, generation)
       when byte_size(bytes) <= @capture_bytes do
    with :ok <- validate_complete_text(bytes, source_id) do
      range = range!(:full, :bytes, 0, byte_size(bytes), byte_size(bytes))
      {:ok, snapshot(bytes, :complete, range, source_kind, source_id, generation)}
    end
  end

  defp bounded_full_snapshot(bytes, source_kind, source_id, generation) do
    case bounded_utf8_prefix(bytes, @capture_bytes) do
      {:ok, prefix} ->
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

      :invalid ->
        {:error, unsupported_format(source_id)}
    end
  end

  @spec disk_snapshot(String.t(), capture_opts()) :: snapshot_result()
  defp disk_snapshot(path, opts), do: disk_snapshot(path, opts, :disk, path, nil)

  @spec disk_snapshot(
          String.t(),
          capture_opts(),
          Revision.source_kind(),
          String.t(),
          non_neg_integer() | nil
        ) :: snapshot_result()
  defp disk_snapshot(open_path, opts, source_kind, source_id, generation) do
    case requested_lines(opts) do
      nil ->
        {:stream_disk, open_path, source_kind, source_id, generation}

      {start, count} ->
        case File.open(open_path, [:read, :binary, :raw]) do
          {:ok, io} ->
            try do
              with {:ok, sample} <- read_sample(io),
                   :ok <-
                     preflight_image_sample(
                       sample,
                       source_id,
                       image_delivery(opts)
                     ),
                   {:ok, _position} <- :file.position(io, :bof) do
                read_disk_lines(io, source_id, start, count, source_kind, generation)
              end
            after
              File.close(io)
            end

          {:error, reason} ->
            {:error, disk_error(source_id, reason)}
        end
    end
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

        with {:ok, bytes} <- normalize_text_selection(bytes, complete?, source_id) do
          {:ok, snapshot(bytes, status, range, source_kind, source_id, generation)}
        end

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
          non_neg_integer() | nil,
          MingaAgent.ModelSelection.image_tool_result_delivery()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp capture_disk(nil, _delivery_key, _path, _kind, _id, _generation, _image_delivery),
    do: {:error, :retention_unavailable}

  defp capture_disk(_store, nil, _path, _kind, _id, _generation, _image_delivery),
    do: {:error, :retention_unavailable}

  defp capture_disk(store, delivery_key, path, kind, id, generation, image_delivery) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        context = %{
          store: store,
          delivery_key: delivery_key,
          io: io,
          path: path,
          source_kind: kind,
          source_id: id,
          generation: generation,
          image_delivery: image_delivery
        }

        try do
          stream_open_disk(context)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, disk_error(id, reason)}
    end
  end

  @spec stream_open_disk(disk_open_context()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp stream_open_disk(%{io: io, source_id: id} = context) do
    case :file.read_file_info(io) do
      {:ok, info} ->
        stat = File.Stat.from_record(info)
        stream_disk_file(context, stat.size)

      {:error, reason} ->
        {:error, disk_error(id, reason)}
    end
  end

  @spec stream_disk_file(disk_open_context(), non_neg_integer()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp stream_disk_file(%{io: io, path: path, image_delivery: image_delivery} = context, size) do
    with {:ok, sample} <- read_sample(io),
         {:ok, media_type} <- stream_media_type(sample, path, image_delivery),
         :ok <- validate_image_size(media_type, size, context.source_id),
         {:ok, _position} <- :file.position(io, :bof),
         {:ok, spec} <-
           CaptureSpec.new(
             media_type: media_type,
             mode: :bytes,
             expected_bytes: min(size, stream_limit(media_type)),
             owner_pid: self(),
             delivery_key: context.delivery_key
           ),
         {:ok, capture} <- ArtifactStore.begin(context.store, spec) do
      stream_context = %{
        store: context.store,
        io: context.io,
        capture: capture,
        media_type: media_type,
        path: context.path,
        source_kind: context.source_kind,
        source_id: context.source_id,
        generation: context.generation
      }

      progress = {stream_limit(media_type), :crypto.hash_init(:sha256), "", ""}
      stream_disk_chunks(stream_context, progress)
    else
      {:error, _reason} = error -> error
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

  @spec stream_media_type(
          binary(),
          String.t(),
          MingaAgent.ModelSelection.image_tool_result_delivery()
        ) :: {:ok, String.t()} | {:error, Limitation.t()}
  defp stream_media_type(sample, path, image_delivery) do
    case image_media_type(sample) do
      {:ok, media_type} ->
        with :ok <- allow_image_delivery(image_delivery, path, media_type) do
          {:ok, media_type}
        end

      {:unsupported, media_type} ->
        {:error, Limitation.image_format(Path.basename(path), media_type)}

      :unknown ->
        {:ok, "text/plain; charset=utf-8"}
    end
  end

  @spec preflight_image_sample(
          binary(),
          String.t(),
          MingaAgent.ModelSelection.image_tool_result_delivery()
        ) :: :ok | {:error, Limitation.t()}
  defp preflight_image_sample(sample, path, image_delivery) do
    case image_media_type(sample) do
      {:ok, media_type} ->
        allow_image_delivery(image_delivery, path, media_type)

      {:unsupported, media_type} ->
        {:error, Limitation.image_format(Path.basename(path), media_type)}

      :unknown ->
        :ok
    end
  end

  @spec allow_image_delivery(
          MingaAgent.ModelSelection.image_tool_result_delivery(),
          String.t(),
          String.t()
        ) :: :ok | {:error, Limitation.t()}
  defp allow_image_delivery(:supported, _path, _media_type), do: :ok

  defp allow_image_delivery({:unsupported, reason}, path, media_type) do
    {:error, Limitation.image_delivery(reason, Path.basename(path), media_type)}
  end

  @spec stream_limit(String.t()) :: pos_integer()
  defp stream_limit("image/" <> _format), do: @image_bytes
  defp stream_limit(_media_type), do: @capture_bytes

  @spec validate_image_size(String.t(), non_neg_integer(), String.t()) ::
          :ok | {:error, String.t()}
  defp validate_image_size("image/" <> _format, size, id) when size > @image_bytes,
    do: {:error, "image exceeds the 5MiB retained-image limit: #{id}"}

  defp validate_image_size(_media_type, _size, _id), do: :ok

  @spec stream_disk_chunks(disk_stream_context(), stream_progress()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp stream_disk_chunks(%{io: io, source_id: id} = context, {0, _hash, _view, _tail} = progress) do
    case IO.binread(io, 1) do
      :eof ->
        finish_stream(context, progress, :complete)

      {:error, reason} ->
        finish_stream_error(
          context,
          {:incomplete, :capture_failed},
          disk_error(id, reason)
        )

      _byte ->
        finish_stream_limit(context, progress)
    end
  end

  defp stream_disk_chunks(
         %{io: io, source_id: id} = context,
         {remaining, _hash, _view, _tail} = progress
       ) do
    case IO.binread(io, min(@read_bytes, remaining)) do
      :eof ->
        finish_stream(context, progress, :complete)

      {:error, reason} ->
        finish_stream_error(
          context,
          {:incomplete, :capture_failed},
          disk_error(id, reason)
        )

      chunk when is_binary(chunk) ->
        append_stream_chunk(context, progress, chunk)
    end
  end

  @spec append_stream_chunk(disk_stream_context(), stream_progress(), binary()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp append_stream_chunk(
         %{store: store, capture: capture, media_type: media_type, path: path} = context,
         {remaining, hash, view, utf8_tail} = progress,
         chunk
       ) do
    case validate_stream_chunk(media_type, utf8_tail, chunk) do
      {:ok, "", next_tail} ->
        stream_disk_chunks(
          context,
          {remaining - byte_size(chunk), hash, view, next_tail}
        )

      {:ok, accepted, next_tail} ->
        case ArtifactStore.append(store, capture, accepted, item_ends: []) do
          {:ok, _progress} ->
            stream_disk_chunks(
              context,
              {
                remaining - byte_size(chunk),
                :crypto.hash_update(hash, accepted),
                append_view(view, accepted),
                next_tail
              }
            )

          {:error, reason} ->
            finish_append_refusal(context, progress, reason)
        end

      :invalid ->
        cancel_stream_limitation(context, unsupported_format(path))
    end
  end

  @spec finish_append_refusal(disk_stream_context(), stream_progress(), term()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp finish_append_refusal(%{media_type: "image/" <> _format} = context, _progress, reason) do
    finish_stream_error(context, stream_incomplete(reason), reason)
  end

  defp finish_append_refusal(context, progress, reason) do
    finish_stream(context, progress, stream_incomplete(reason))
  end

  @spec append_view(binary(), binary()) :: binary()
  defp append_view(view, _chunk) when byte_size(view) >= 51_203, do: view

  defp append_view(view, chunk),
    do: view <> binary_part(chunk, 0, min(byte_size(chunk), 51_203 - byte_size(view)))

  @spec validate_stream_chunk(String.t(), binary(), binary()) ::
          {:ok, binary(), binary()} | :invalid
  defp validate_stream_chunk("image/" <> _format, _tail, chunk), do: {:ok, chunk, ""}

  defp validate_stream_chunk(_media_type, tail, chunk) do
    bytes = tail <> chunk

    if :binary.match(bytes, <<0>>) == :nomatch do
      case utf8_tail(bytes, min(3, byte_size(bytes))) do
        {:ok, next_tail} ->
          accepted_size = byte_size(bytes) - byte_size(next_tail)
          {:ok, binary_part(bytes, 0, accepted_size), next_tail}

        :invalid ->
          :invalid
      end
    else
      :invalid
    end
  end

  @spec normalize_text_selection(binary(), boolean(), String.t()) ::
          {:ok, binary()} | {:error, Limitation.t()}
  defp normalize_text_selection(bytes, true, source_id) do
    case validate_complete_text(bytes, source_id) do
      :ok -> {:ok, bytes}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_text_selection(bytes, false, source_id) do
    case bounded_utf8_prefix(bytes, byte_size(bytes)) do
      {:ok, prefix} -> {:ok, prefix}
      :invalid -> {:error, unsupported_format(source_id)}
    end
  end

  @spec bounded_utf8_prefix(binary(), non_neg_integer()) :: {:ok, binary()} | :invalid
  defp bounded_utf8_prefix(bytes, limit) do
    candidate = binary_part(bytes, 0, min(limit, byte_size(bytes)))

    if :binary.match(candidate, <<0>>) == :nomatch do
      case utf8_tail(candidate, min(3, byte_size(candidate))) do
        {:ok, tail} ->
          {:ok, binary_part(candidate, 0, byte_size(candidate) - byte_size(tail))}

        :invalid ->
          :invalid
      end
    else
      :invalid
    end
  end

  @spec utf8_tail(binary(), non_neg_integer()) :: {:ok, binary()} | :invalid
  defp utf8_tail(bytes, max_tail) do
    case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
      valid when is_binary(valid) -> {:ok, ""}
      {:incomplete, _prefix, tail} when byte_size(tail) <= max_tail -> {:ok, tail}
      _invalid -> :invalid
    end
  end

  @spec finish_stream_limit(disk_stream_context(), stream_progress()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp finish_stream_limit(
         %{media_type: "image/" <> _format, source_id: id} = context,
         _progress
       ) do
    finish_stream_error(
      context,
      {:incomplete, :capture_byte_limit},
      "image exceeds the 5MiB retained-image limit: #{id}"
    )
  end

  defp finish_stream_limit(context, progress) do
    finish_stream(context, progress, {:incomplete, :capture_byte_limit})
  end

  @spec finish_stream(disk_stream_context(), stream_progress(), Output.capture_status()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp finish_stream(
         %{
           store: store,
           capture: capture,
           media_type: media_type,
           path: path,
           source_kind: kind,
           source_id: id,
           generation: generation
         } = context,
         {_remaining, hash, view, utf8_tail},
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
      cancel_stream_limitation(context, unsupported_format(path))
    end
  end

  @spec valid_stream_end?(String.t(), binary(), Output.capture_status()) :: boolean()
  defp valid_stream_end?("image/" <> _format, _tail, _status), do: true
  defp valid_stream_end?(_media_type, "", _status), do: true
  defp valid_stream_end?(_media_type, _tail, {:incomplete, _reason}), do: true
  defp valid_stream_end?(_media_type, _tail, :complete), do: false

  @spec finish_stream_error(disk_stream_context(), Output.capture_status(), term()) ::
          {:error, term()}
  defp finish_stream_error(%{store: store, capture: capture}, status, reason) do
    _result = ArtifactStore.finish(store, capture, status)
    {:error, reason}
  end

  @spec cancel_stream_limitation(disk_stream_context(), Limitation.t()) ::
          {:error, Limitation.t()}
  defp cancel_stream_limitation(%{store: store, capture: capture}, limitation) do
    _result = ArtifactStore.cancel(store, capture)
    {:error, limitation}
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
      build_stream_media_output(
        reference,
        capture,
        selection,
        revision,
        raw_view,
        media_type,
        path
      )
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
          {Revision.source_kind(), String.t(), non_neg_integer() | nil}
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp capture_image(
         store,
         delivery_key,
         path,
         media_type,
         bytes,
         range,
         {kind, id, generation}
       ) do
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
           Output.new(
             "[image: #{Path.basename(path)} (#{media_type})]",
             output.capture,
             output.selection,
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

  defp requested_lines(offset, nil) when is_integer(offset) and offset > 0,
    do: {offset - 1, @all_lines}

  defp requested_lines(nil, limit) when is_integer(limit) and limit > 0, do: {0, limit}

  defp requested_lines(offset, limit)
       when is_integer(offset) and offset > 0 and is_integer(limit) and limit > 0,
       do: {offset - 1, limit}

  defp requested_lines(_offset, _limit), do: {0, @capture_bytes}

  @spec validate_capture_opts(capture_opts()) :: :ok | {:error, String.t()}
  defp validate_capture_opts(opts) do
    offset = Keyword.get(opts, :offset)
    limit = Keyword.get(opts, :limit)

    if valid_optional_positive?(offset) and valid_optional_positive?(limit) and
         valid_image_delivery?(image_delivery(opts)),
       do: :ok,
       else:
         {:error, "offset and limit must be positive integers and image delivery must be valid"}
  end

  @spec image_delivery(capture_opts()) ::
          MingaAgent.ModelSelection.image_tool_result_delivery() | term()
  defp image_delivery(opts) do
    Keyword.get(opts, :image_tool_result_delivery, {:unsupported, :tool_result_transport})
  end

  @spec valid_image_delivery?(term()) :: boolean()
  defp valid_image_delivery?(:supported), do: true

  defp valid_image_delivery?({:unsupported, reason})
       when reason in [:model_image_input, :tool_result_transport],
       do: true

  defp valid_image_delivery?(_delivery), do: false

  @spec valid_optional_positive?(term()) :: boolean()
  defp valid_optional_positive?(nil), do: true
  defp valid_optional_positive?(value), do: is_integer(value) and value > 0

  @spec select_io_lines(:file.io_device(), non_neg_integer(), pos_integer(), pos_integer()) ::
          {:ok, binary(), non_neg_integer(), Range.total(), boolean()} | {:error, term()}
  defp select_io_lines(io, start, count, max_bytes),
    do: select_io_lines(io, start, count, max_bytes, LineSelection.new())

  @spec select_io_lines(
          :file.io_device(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          LineSelection.t()
        ) ::
          {:ok, binary(), non_neg_integer(), Range.total(), boolean()} | {:error, term()}
  defp select_io_lines(io, start, count, max_bytes, selection) do
    case IO.binread(io, @read_bytes) do
      :eof ->
        {bytes, selected_count, total, complete?} =
          LineSelection.result(selection, start, count, true)

        {:ok, bytes, selected_count, total, complete?}

      {:error, reason} ->
        {:error, reason}

      chunk when is_binary(chunk) ->
        next = LineSelection.consume(selection, chunk, start, count, max_bytes)

        if LineSelection.finished?(next, start, count, max_bytes) do
          {bytes, selected_count, total, complete?} =
            LineSelection.result(next, start, count, false)

          {:ok, bytes, selected_count, total, complete?}
        else
          select_io_lines(io, start, count, max_bytes, next)
        end
    end
  end

  @spec validate_snapshot_text(snapshot(), String.t()) :: :ok | {:error, Limitation.t()}
  defp validate_snapshot_text(%{bytes: bytes, status: :complete}, path),
    do: validate_complete_text(bytes, path)

  defp validate_snapshot_text(%{bytes: bytes, status: {:incomplete, _reason}}, path) do
    valid_prefix? =
      :binary.match(bytes, <<0>>) == :nomatch and
        match?({:ok, _tail}, utf8_tail(bytes, min(3, byte_size(bytes))))

    if valid_prefix?, do: :ok, else: {:error, unsupported_format(path)}
  end

  @spec validate_complete_text(binary(), String.t()) :: :ok | {:error, Limitation.t()}
  defp validate_complete_text("", _path), do: :ok

  defp validate_complete_text(bytes, path) do
    if String.valid?(bytes) and :binary.match(bytes, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, unsupported_format(path)}
  end

  @spec image_media_type(binary()) ::
          {:ok, String.t()} | {:unsupported, String.t()} | :unknown
  defp image_media_type(<<0x89, "PNG\r\n\x1A\n", _::binary>>), do: {:ok, "image/png"}
  defp image_media_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp image_media_type(<<"GIF87a", _::binary>>), do: {:ok, "image/gif"}
  defp image_media_type(<<"GIF89a", _::binary>>), do: {:ok, "image/gif"}

  defp image_media_type(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>),
    do: {:ok, "image/webp"}

  defp image_media_type(<<"BM", _::binary>>), do: {:unsupported, "image/bmp"}
  defp image_media_type(<<"II", 42, 0, _::binary>>), do: {:unsupported, "image/tiff"}
  defp image_media_type(<<"MM", 0, 42, _::binary>>), do: {:unsupported, "image/tiff"}
  defp image_media_type(<<"<svg", _::binary>>), do: {:unsupported, "image/svg+xml"}

  defp image_media_type(<<_size::unsigned-big-32, "ftyp", brand::binary-size(4), _::binary>>)
       when brand in ["heic", "heix", "hevc", "hevx", "mif1", "msf1"],
       do: {:unsupported, "image/heic"}

  defp image_media_type(_bytes), do: :unknown

  @spec unsupported_format(String.t()) :: Limitation.t()
  defp unsupported_format(path) do
    Limitation.image_format(Path.basename(path), "application/octet-stream")
  end

  @spec range!(Range.kind(), Range.unit(), non_neg_integer(), non_neg_integer(), Range.total()) ::
          Range.t()
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

  defp disk_error(path, :eisdir),
    do: "#{path} is a directory, not a file. Use list_directory instead."

  defp disk_error(path, reason), do: "failed to read #{path}: #{inspect(reason)}"
end
