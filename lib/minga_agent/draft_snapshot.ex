defmodule MingaAgent.DraftSnapshot do
  @moduledoc "An immutable, bounded composer snapshot. It is never part of the model conversation."

  alias MingaAgent.Tool.Output.Reference

  @version 1
  @max_inline_bytes 1_048_576
  @max_entries 128
  @max_field_bytes 4_096

  @type position :: {non_neg_integer(), non_neg_integer()}
  @type paste_block :: {String.t(), boolean()}
  @type source_kind :: :selection | :buffer | :file | :diagnostics
  @type attachment_content :: {:snapshot, Reference.t()} | :live
  @type attachment :: {source_kind(), String.t(), String.t(), String.t(), attachment_content()}
  @type t :: %__MODULE__{
          text: String.t(),
          cursor: position(),
          paste_blocks: [paste_block()],
          attachments: [attachment()]
        }

  @enforce_keys [:text, :cursor, :paste_blocks, :attachments]
  defstruct @enforce_keys

  @doc "Validates a snapshot and encodes its versioned storage representation."
  @spec encode(t()) :: {:ok, map()} | {:error, :invalid_draft_snapshot | :draft_too_large}
  def encode(%__MODULE__{} = snapshot)
      when is_binary(snapshot.text) and is_list(snapshot.paste_blocks) and
             is_list(snapshot.attachments) do
    with :ok <- validate_sizes(snapshot.text, snapshot.paste_blocks, snapshot.attachments) do
      %{
        "version" => @version,
        "text" => snapshot.text,
        "cursor" => Tuple.to_list(snapshot.cursor),
        "paste_blocks" =>
          Enum.map(snapshot.paste_blocks, fn {text, expanded?} -> [text, expanded?] end),
        "attachments" => Enum.map(snapshot.attachments, &encode_attachment/1)
      }
      |> checked_encoding()
    end
  rescue
    _ in [ArgumentError, FunctionClauseError, Protocol.UndefinedError] ->
      {:error, :invalid_draft_snapshot}
  end

  def encode(%__MODULE__{}), do: {:error, :invalid_draft_snapshot}

  @doc "Validates and restores an exact composer snapshot from disk."
  @spec decode(term()) ::
          {:ok, t()}
          | {:error,
             :invalid_draft_snapshot | :draft_too_large | {:unknown_draft_version, term()}}
  def decode(%{"version" => version}) when version != @version,
    do: {:error, {:unknown_draft_version, version}}

  def decode(%{
        "version" => @version,
        "text" => text,
        "cursor" => [line, byte_col],
        "paste_blocks" => paste_blocks,
        "attachments" => attachments
      })
      when is_binary(text) and is_list(paste_blocks) and is_list(attachments) do
    with :ok <- validate_inline_size(text, paste_blocks, attachments),
         true <- String.valid?(text) and valid_position?(text, line, byte_col),
         {:ok, blocks} <- decode_list(paste_blocks, &decode_paste_block/1),
         {:ok, attachments} <- decode_list(attachments, &decode_attachment/1) do
      {:ok,
       %__MODULE__{
         text: text,
         cursor: {line, byte_col},
         paste_blocks: blocks,
         attachments: attachments
       }}
    else
      false -> {:error, :invalid_draft_snapshot}
      {:error, _reason} = error -> error
    end
  end

  def decode(_), do: {:error, :invalid_draft_snapshot}

  @doc "Returns immutable captured bytes that must stay pinned with this record."
  @spec references(t()) :: [Reference.t()]
  def references(%__MODULE__{attachments: attachments}) do
    for {_kind, _source, _label, _revision, {:snapshot, reference}} <- attachments, do: reference
  end

  @doc "Encodes the canonical captured attachment fields for another owner in the same saved record."
  @spec encode_attachments([attachment()]) :: [map()]
  def encode_attachments(attachments), do: Enum.map(attachments, &encode_attachment/1)

  @doc "Restores a bounded list of attachment identities and captured references."
  @spec decode_attachments(term()) :: {:ok, [attachment()]} | {:error, term()}
  def decode_attachments(attachments) when is_list(attachments) do
    with :ok <- validate_sizes("", [], attachments) do
      decode_list(attachments, &decode_attachment/1)
    end
  end

  def decode_attachments(_invalid), do: {:error, :invalid_draft_snapshot}

  @doc "Recalls text and exact captured attachments ahead of the saved composer without moving the caret within its prior text."
  @spec prepend_recalled(t() | nil, iodata(), [attachment()]) ::
          {:ok, t()} | {:error, :draft_too_large}
  def prepend_recalled(nil, prefix, attachments) do
    empty = %__MODULE__{text: "", cursor: {0, 0}, paste_blocks: [], attachments: []}
    prepend_recalled(empty, prefix, attachments)
  end

  def prepend_recalled(%__MODULE__{} = draft, prefix, attachments) do
    prefix_size = IO.iodata_length(prefix)
    separator = if draft.text == "" or prefix_size == 0, do: "", else: "\n\n"
    added_bytes = prefix_size + byte_size(separator)

    if added_bytes + byte_size(draft.text) <= @max_inline_bytes do
      text = IO.iodata_to_binary([prefix, separator, draft.text])
      {line, column} = draft.cursor
      offset = length(:binary.matches(text, "\n", scope: {0, added_bytes}))

      {:ok,
       %{
         draft
         | text: text,
           cursor: {line + offset, column},
           attachments: attachments ++ draft.attachments
       }}
    else
      {:error, :draft_too_large}
    end
  end

  @spec checked_encoding(map()) ::
          {:ok, map()} | {:error, :invalid_draft_snapshot | :draft_too_large}
  defp checked_encoding(encoded) do
    case decode(encoded) do
      {:ok, _validated} -> {:ok, encoded}
      {:error, {:unknown_draft_version, _version}} -> {:error, :invalid_draft_snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_inline_size(binary(), [term()], [term()]) ::
          :ok | {:error, :draft_too_large | :invalid_draft_snapshot}
  defp validate_inline_size(text, blocks, attachments) do
    with :ok <- validate_sizes(text, blocks, attachments) do
      Enum.reduce_while(blocks, byte_size(text), fn
        [block, _expanded?], size
        when is_binary(block) and size + byte_size(block) <= @max_inline_bytes ->
          {:cont, size + byte_size(block)}

        [block, _expanded?], _size when is_binary(block) ->
          {:halt, {:error, :draft_too_large}}

        _invalid, _size ->
          {:halt, {:error, :invalid_draft_snapshot}}
      end)
      |> inline_size_result()
    end
  end

  @spec validate_sizes(binary(), [term()], [term()]) :: :ok | {:error, :draft_too_large}
  defp validate_sizes(text, blocks, attachments) do
    if byte_size(text) > @max_inline_bytes or
         Enum.count_until(blocks, @max_entries + 1) > @max_entries or
         Enum.count_until(attachments, @max_entries + 1) > @max_entries do
      {:error, :draft_too_large}
    else
      :ok
    end
  end

  @spec inline_size_result(non_neg_integer() | {:error, term()}) :: :ok | {:error, term()}
  defp inline_size_result(size) when is_integer(size), do: :ok
  defp inline_size_result({:error, _} = error), do: error

  @spec valid_position?(binary(), term(), term()) :: boolean()
  defp valid_position?(text, line, byte_col)
       when is_integer(line) and line >= 0 and is_integer(byte_col) and byte_col >= 0 do
    case line_at(text, line) do
      row when is_binary(row) and byte_col < byte_size(row) ->
        :binary.at(row, byte_col) not in 0x80..0xBF

      row when is_binary(row) ->
        byte_col == byte_size(row)

      nil ->
        false
    end
  end

  defp valid_position?(_text, _line, _byte_col), do: false

  @spec line_at(binary(), non_neg_integer()) :: binary() | nil
  defp line_at(text, 0) do
    case :binary.match(text, "\n") do
      {offset, 1} -> binary_part(text, 0, offset)
      :nomatch -> text
    end
  end

  defp line_at(text, line) do
    case :binary.match(text, "\n") do
      {offset, 1} ->
        start = offset + 1
        line_at(binary_part(text, start, byte_size(text) - start), line - 1)

      :nomatch ->
        nil
    end
  end

  @spec decode_list([term()], (term() -> {:ok, value} | {:error, term()})) ::
          {:ok, [value]} | {:error, term()}
        when value: var
  defp decode_list(encoded, decoder) do
    decode_list(encoded, decoder, [])
  end

  @spec decode_list([term()], (term() -> {:ok, value} | {:error, term()}), [value]) ::
          {:ok, [value]} | {:error, term()}
        when value: var
  defp decode_list([], _decoder, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_list([entry | rest], decoder, acc) do
    with {:ok, value} <- decoder.(entry), do: decode_list(rest, decoder, [value | acc])
  end

  @spec decode_paste_block(term()) :: {:ok, paste_block()} | {:error, :invalid_draft_snapshot}
  defp decode_paste_block([text, expanded?]) when is_binary(text) and is_boolean(expanded?) do
    if String.valid?(text), do: {:ok, {text, expanded?}}, else: {:error, :invalid_draft_snapshot}
  end

  defp decode_paste_block(_), do: {:error, :invalid_draft_snapshot}

  @spec encode_attachment(attachment()) :: map()
  defp encode_attachment({kind, source, label, revision, content}) do
    %{
      "kind" => Atom.to_string(kind),
      "source" => source,
      "label" => label,
      "revision" => revision,
      "content" => encode_content(content)
    }
  end

  @spec encode_content(attachment_content()) :: String.t() | map()
  defp encode_content(:live), do: "live"

  defp encode_content({:snapshot, %Reference{} = reference}) do
    %{
      "token" => reference.token,
      "media_type" => reference.media_type,
      "bytes" => reference.bytes,
      "items" => reference.items,
      "sha256" => reference.sha256
    }
  end

  @spec decode_attachment(term()) :: {:ok, attachment()} | {:error, :invalid_draft_snapshot}
  defp decode_attachment(%{
         "kind" => kind,
         "source" => source,
         "label" => label,
         "revision" => revision,
         "content" => content
       }) do
    with {:ok, kind} <- decode_kind(kind),
         true <- valid_field?(source) and valid_field?(label) and valid_field?(revision),
         {:ok, content} <- decode_content(content) do
      {:ok, {kind, source, label, revision, content}}
    else
      _invalid -> {:error, :invalid_draft_snapshot}
    end
  end

  defp decode_attachment(_), do: {:error, :invalid_draft_snapshot}

  @spec decode_kind(term()) :: {:ok, source_kind()} | :error
  defp decode_kind("selection"), do: {:ok, :selection}
  defp decode_kind("buffer"), do: {:ok, :buffer}
  defp decode_kind("file"), do: {:ok, :file}
  defp decode_kind("diagnostics"), do: {:ok, :diagnostics}
  defp decode_kind(_), do: :error

  @spec valid_field?(term()) :: boolean()
  defp valid_field?(value) do
    is_binary(value) and byte_size(value) in 1..@max_field_bytes and String.valid?(value)
  end

  @spec decode_content(term()) ::
          {:ok, attachment_content()} | {:error, :invalid_draft_snapshot | :invalid_reference}
  defp decode_content("live"), do: {:ok, :live}

  defp decode_content(
         %{"token" => token, "media_type" => type, "bytes" => bytes, "sha256" => sha} = encoded
       ) do
    if valid_field?(type) do
      with {:ok, reference} <-
             Reference.new(
               token: token,
               media_type: type,
               bytes: bytes,
               items: encoded["items"],
               sha256: sha
             ),
           do: {:ok, {:snapshot, reference}}
    else
      {:error, :invalid_draft_snapshot}
    end
  end

  defp decode_content(_), do: {:error, :invalid_draft_snapshot}
end
