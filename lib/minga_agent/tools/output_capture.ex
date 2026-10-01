defmodule MingaAgent.Tools.OutputCapture do
  @moduledoc """
  Stores one bounded tool result and builds the canonical output value.

  This module is the byte/item boundary for built-in tools whose producer has
  already applied its semantic filtering. It never invents a successful
  retained result when no record-scoped artifact store is available.
  """

  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output.Revision
  alias MingaAgent.Tools.OutputLimit

  @append_bytes 65_536
  @visible_bytes 51_200
  @visible_items 100

  @typedoc "Options common to byte and item captures."
  @type capture_opts :: [
          media_type: String.t(),
          expected_bytes: non_neg_integer(),
          selection: Range.t(),
          revision: Revision.t(),
          view: String.t(),
          visible_items: [String.t()],
          capture_status: Output.capture_status(),
          attachments: [MingaAgent.Tool.Output.Attachment.t()]
        ]

  @doc "Captures exact bytes and returns a complete or visibly incomplete canonical output."
  @spec bytes(GenServer.server() | nil, term() | nil, binary(), capture_opts()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  def bytes(nil, _delivery_key, _bytes, _opts), do: {:error, :retention_unavailable}
  def bytes(_store, nil, _bytes, _opts), do: {:error, :retention_unavailable}

  def bytes(store, delivery_key, bytes, opts) when is_binary(bytes) and is_list(opts) do
    media_type = Keyword.get(opts, :media_type, "text/plain; charset=utf-8")

    with {:ok, spec} <-
           CaptureSpec.new(
             media_type: media_type,
             mode: :bytes,
             expected_bytes: Keyword.get(opts, :expected_bytes, byte_size(bytes)),
             owner_pid: self(),
             delivery_key: delivery_key
           ),
         {:ok, capture} <- ArtifactStore.begin(store, spec) do
      append_bytes(store, capture, bytes, 0, opts)
    end
  end

  @doc "Captures filtered canonical records once, preserving item boundaries for later pages."
  @spec items(GenServer.server() | nil, term() | nil, [String.t()], capture_opts()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  def items(nil, _delivery_key, _items, _opts), do: {:error, :retention_unavailable}
  def items(_store, nil, _items, _opts), do: {:error, :retention_unavailable}

  def items(store, delivery_key, items, opts) when is_list(items) and is_list(opts) do
    media_type = Keyword.get(opts, :media_type, "application/x-ndjson; charset=utf-8")
    expected_bytes = Enum.reduce(items, 0, &(byte_size(&1) + 1 + &2))

    with {:ok, spec} <-
           CaptureSpec.new(
             media_type: media_type,
             mode: :items,
             expected_bytes: expected_bytes,
             owner_pid: self(),
             delivery_key: delivery_key
           ),
         {:ok, capture} <- ArtifactStore.begin(store, spec) do
      append_items(store, capture, items, [], 0, 0, opts)
    end
  end

  @spec append_bytes(GenServer.server(), term(), binary(), non_neg_integer(), capture_opts()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp append_bytes(store, capture, bytes, offset, opts) when offset == byte_size(bytes) do
    finish_bytes(store, capture, bytes, Keyword.get(opts, :capture_status, :complete), opts)
  end

  defp append_bytes(store, capture, bytes, offset, opts) do
    count = min(@append_bytes, byte_size(bytes) - offset)
    chunk = binary_part(bytes, offset, count)

    case ArtifactStore.append(store, capture, chunk, item_ends: []) do
      {:ok, _progress} -> append_bytes(store, capture, bytes, offset + count, opts)
      {:error, reason} -> finish_bytes(store, capture, bytes, incomplete(reason), opts)
    end
  end

  @spec append_items(
          GenServer.server(),
          term(),
          [String.t()],
          iodata(),
          non_neg_integer(),
          non_neg_integer(),
          capture_opts()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp append_items(store, capture, [], pending, pending_bytes, accepted_items, opts) do
    case flush_items(store, capture, pending, pending_bytes, accepted_items) do
      {:ok, accepted_items} ->
        status = Keyword.get(opts, :capture_status, :complete)
        finish_items(store, capture, accepted_items, status, opts)

      {:error, reason, accepted_items} ->
        finish_items(store, capture, accepted_items, incomplete(reason), opts)
    end
  end

  defp append_items(store, capture, [item | rest], pending, pending_bytes, accepted_items, opts)
       when is_binary(item) do
    record = item <> "\n"

    if pending_bytes > 0 and pending_bytes + byte_size(record) > @append_bytes do
      case flush_items(store, capture, pending, pending_bytes, accepted_items) do
        {:ok, next_accepted} ->
          append_items(store, capture, [item | rest], [], 0, next_accepted, opts)

        {:error, reason, next_accepted} ->
          finish_items(store, capture, next_accepted, incomplete(reason), opts)
      end
    else
      append_item_record(
        store,
        capture,
        record,
        rest,
        pending,
        pending_bytes,
        accepted_items,
        opts
      )
    end
  end

  @spec append_item_record(
          GenServer.server(),
          term(),
          binary(),
          [String.t()],
          iodata(),
          non_neg_integer(),
          non_neg_integer(),
          capture_opts()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp append_item_record(
         store,
         capture,
         record,
         rest,
         pending,
         pending_bytes,
         accepted_items,
         opts
       )
       when byte_size(record) <= @append_bytes do
    append_items(
      store,
      capture,
      rest,
      [pending, record],
      pending_bytes + byte_size(record),
      accepted_items,
      opts
    )
  end

  defp append_item_record(
         store,
         capture,
         _record,
         _rest,
         pending,
         pending_bytes,
         accepted_items,
         opts
       ) do
    case flush_items(store, capture, pending, pending_bytes, accepted_items) do
      {:ok, next_accepted} ->
        finish_items(store, capture, next_accepted, {:incomplete, :capture_byte_limit}, opts)

      {:error, reason, next_accepted} ->
        finish_items(store, capture, next_accepted, incomplete(reason), opts)
    end
  end

  @spec flush_items(GenServer.server(), term(), iodata(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term(), non_neg_integer()}
  defp flush_items(_store, _capture, _pending, 0, accepted_items), do: {:ok, accepted_items}

  defp flush_items(store, capture, pending, _pending_bytes, accepted_items) do
    chunk = IO.iodata_to_binary(pending)
    ends = item_ends(chunk)

    case ArtifactStore.append(store, capture, chunk, item_ends: ends) do
      {:ok, progress} -> {:ok, progress.items}
      {:error, reason} -> {:error, reason, accepted_items}
    end
  end

  @spec item_ends(binary()) :: [pos_integer()]
  defp item_ends(chunk) do
    for {offset, 1} <- :binary.matches(chunk, "\n"), do: offset + 1
  end

  @spec finish_bytes(
          GenServer.server(),
          term(),
          binary(),
          Output.capture_status(),
          capture_opts()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp finish_bytes(store, capture, bytes, status, opts) do
    case ArtifactStore.finish(store, capture, status) do
      {:ok, stored} -> build_bytes_output(bytes, stored, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_bytes_output(binary(), term(), capture_opts()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp build_bytes_output(bytes, stored, opts) do
    reference = stored.reference
    capture = stored.capture
    captured = binary_part(bytes, 0, min(reference.bytes, byte_size(bytes)))
    view = Keyword.get(opts, :view, OutputLimit.utf8_prefix(captured, @visible_bytes))
    selection = selection(opts, capture, reference.bytes, nil)
    presentation = presentation(byte_size(captured), byte_size(view), reference)

    with {:ok, revision} <- captured_revision(Keyword.get(opts, :revision), captured, selection),
         {:ok, output} <-
           Output.new(view, capture, selection,
             reference: reference,
             revision: revision,
             attachments: Keyword.get(opts, :attachments, []),
             presentation: presentation
           ) do
      Output.result(output)
    end
  end

  @spec finish_items(
          GenServer.server(),
          term(),
          non_neg_integer(),
          Output.capture_status(),
          capture_opts()
        ) :: {:ok, Output.t()} | {:error, Output.t() | term()}
  defp finish_items(store, capture, accepted_items, status, opts) do
    case ArtifactStore.finish(store, capture, status) do
      {:ok, stored} -> build_items_output(stored, accepted_items, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_items_output(term(), non_neg_integer(), capture_opts()) ::
          {:ok, Output.t()} | {:error, Output.t() | term()}
  defp build_items_output(stored, accepted_items, opts) do
    reference = stored.reference
    capture = stored.capture
    all_items = Keyword.get(opts, :visible_items, [])
    captured_items = Enum.take(all_items, reference.items || accepted_items)
    visible_items = Enum.take(captured_items, @visible_items)
    captured_bytes = Enum.map_join(captured_items, "", &(&1 <> "\n"))
    view = Keyword.get(opts, :view, Enum.join(visible_items, "\n"))
    selection = selection(opts, capture, reference.bytes, reference.items || accepted_items)

    presentation =
      if reference.items != nil and reference.items > length(visible_items) do
        {:truncated, max(reference.bytes - byte_size(view), 1)}
      else
        :complete
      end

    with {:ok, revision} <-
           captured_revision(Keyword.get(opts, :revision), captured_bytes, selection),
         {:ok, output} <-
           Output.new(view, capture, selection,
             reference: reference,
             revision: revision,
             presentation: presentation
           ) do
      Output.result(output)
    end
  end

  @spec selection(
          capture_opts(),
          Output.capture_status(),
          non_neg_integer(),
          non_neg_integer() | nil
        ) ::
          Range.t()
  defp selection(opts, :complete, bytes, items) do
    case Keyword.get(opts, :selection) do
      %Range{} = range -> range
      nil -> new_range!(:full, unit(items), 0, count(bytes, items), count(bytes, items))
    end
  end

  defp selection(_opts, {:incomplete, _reason}, bytes, nil) do
    new_range!(:captured_prefix, :bytes, 0, bytes, :unknown)
  end

  defp selection(_opts, {:incomplete, _reason}, bytes, items) do
    new_range!(:captured_prefix, unit(items), 0, count(bytes, items), :unknown)
  end

  @spec unit(non_neg_integer() | nil) :: :bytes | :items
  defp unit(nil), do: :bytes
  defp unit(_items), do: :items

  @spec count(non_neg_integer(), non_neg_integer() | nil) :: non_neg_integer()
  defp count(bytes, nil), do: bytes
  defp count(_bytes, items), do: items

  @spec new_range!(
          Range.kind(),
          Range.unit(),
          non_neg_integer(),
          non_neg_integer(),
          Range.total()
        ) ::
          Range.t()
  defp new_range!(kind, unit, start, count, total) do
    {:ok, range} = Range.new(kind, unit, start, count, total)
    range
  end

  @spec captured_revision(Revision.t() | nil, binary(), Range.t()) ::
          {:ok, Revision.t() | nil} | {:error, :invalid_revision}
  defp captured_revision(nil, _bytes, _selection), do: {:ok, nil}

  defp captured_revision(%Revision{} = revision, bytes, selection) do
    Revision.new(
      source_kind: revision.source_kind,
      source_id: revision.source_id,
      scope: selection,
      generation: revision.generation,
      sha256: Reference.digest(bytes)
    )
  end

  @spec presentation(non_neg_integer(), non_neg_integer(), term()) :: Output.presentation_status()
  defp presentation(captured_bytes, view_bytes, _reference) when captured_bytes <= view_bytes,
    do: :complete

  defp presentation(captured_bytes, view_bytes, _reference),
    do: {:truncated, captured_bytes - view_bytes}

  @spec incomplete(term()) :: {:incomplete, Output.incomplete_reason()}
  defp incomplete(reason)
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

  defp incomplete(_reason), do: {:incomplete, :capture_failed}
end
