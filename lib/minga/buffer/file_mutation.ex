defmodule Minga.Buffer.FileMutation do
  @moduledoc """
  Prepares one revision-checked file mutation without side effects.

  Exact replacements run in order against prepared content. Each old text must be nonempty and occur exactly once, including overlapping occurrences. A later replacement cannot touch bytes inserted by an earlier replacement. Failure reports the one-based edit index and discards the complete preparation.
  """

  @type operation ::
          {:edit, [{String.t(), String.t()}]}
          | {:replace, String.t()}
          | {:create, String.t()}
          | :delete
  @type expectation :: String.t() | :absent
  @type identity :: {atom(), String.t()}
  @type source :: {:ok, binary()} | {:error, term()}
  @typep touched :: [{non_neg_integer(), non_neg_integer()}]

  @doc "Returns the existing full-source read revision token for these bytes and owner generation."
  @spec revision(binary(), non_neg_integer() | nil, identity()) :: String.t()
  def revision(content, generation, {kind, id}) do
    size = byte_size(content)

    digest(
      JSON.encode!([
        1,
        Atom.to_string(kind),
        id,
        "full",
        "bytes",
        0,
        size,
        size,
        generation,
        digest(content)
      ])
    )
  end

  @doc "Validates current owner content and prepares the complete mutation. Call inside the writer transition."
  @spec prepare(source(), non_neg_integer() | nil, identity(), expectation(), operation()) ::
          {:ok, binary() | :deleted} | {:error, term()}
  def prepare({:error, :enoent}, _generation, _identity, :absent, {:create, content})
      when is_binary(content),
      do: validate_content(content)

  def prepare({:ok, _content}, _generation, _identity, :absent, {:create, _new}),
    do: {:error, :already_exists}

  def prepare({:error, reason}, _generation, _identity, _expected, _operation),
    do: {:error, reason}

  def prepare({:ok, content}, generation, identity, expected, operation)
      when is_binary(expected) do
    if revision(content, generation, identity) == expected do
      prepare_operation(content, operation)
    else
      {:error, :stale_revision}
    end
  end

  def prepare(_source, _generation, _identity, _expected, _operation),
    do: {:error, :revision_required}

  @spec prepare_operation(binary(), operation()) :: {:ok, binary() | :deleted} | {:error, term()}
  defp prepare_operation(_content, {:replace, replacement}) when is_binary(replacement),
    do: validate_content(replacement)

  defp prepare_operation(_content, :delete), do: {:ok, :deleted}

  defp prepare_operation(content, {:edit, [_ | _] = edits}),
    do: prepare_edits(content, edits, 1, [])

  defp prepare_operation(_content, _operation), do: {:error, :invalid_operation}

  @spec prepare_edits(binary(), list(), pos_integer(), touched()) ::
          {:ok, binary()} | {:error, term()}
  defp prepare_edits(content, [], _index, _touched), do: {:ok, content}

  defp prepare_edits(content, [{old, new} | rest], index, touched)
       when is_binary(old) and byte_size(old) > 0 and is_binary(new) do
    with {:ok, _} <- validate_content(old),
         {:ok, _} <- validate_content(new),
         {:ok, start} <- unique_match(content, old),
         :ok <- reject_overlap(touched, start, byte_size(old)) do
      old_size = byte_size(old)
      new_size = byte_size(new)
      suffix_start = start + old_size

      prepared =
        :binary.list_to_bin([
          binary_part(content, 0, start),
          new,
          binary_part(content, suffix_start, byte_size(content) - suffix_start)
        ])

      next_touched = [
        {start, new_size} | move_touched(touched, suffix_start, new_size - old_size)
      ]

      prepare_edits(prepared, rest, index + 1, next_touched)
    else
      {:error, reason} -> {:error, {:edit_failed, index, reason}}
    end
  end

  defp prepare_edits(_content, _edits, index, _touched),
    do: {:error, {:edit_failed, index, :invalid_edit}}

  @spec unique_match(binary(), binary()) :: {:ok, non_neg_integer()} | {:error, atom()}
  defp unique_match(content, old) do
    case :binary.match(content, old) do
      :nomatch ->
        {:error, :not_found}

      {start, _size} ->
        remaining = byte_size(content) - start - 1

        case :binary.match(content, old, scope: {start + 1, remaining}) do
          :nomatch -> {:ok, start}
          _match -> {:error, :ambiguous_match}
        end
    end
  end

  @spec reject_overlap(touched(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, :overlapping_edit}
  defp reject_overlap(touched, start, size) do
    if Enum.any?(touched, fn {offset, length} ->
         (length == 0 and offset > start and offset < start + size) or
           (length > 0 and start < offset + length and offset < start + size)
       end), do: {:error, :overlapping_edit}, else: :ok
  end

  @spec move_touched(touched(), non_neg_integer(), integer()) :: touched()
  defp move_touched(touched, suffix_start, shift) do
    Enum.map(touched, fn
      {offset, length} when offset >= suffix_start -> {offset + shift, length}
      span -> span
    end)
  end

  @spec validate_content(binary()) :: {:ok, binary()} | {:error, :invalid_text}
  defp validate_content(content) do
    if String.valid?(content) and :binary.match(content, <<0>>) == :nomatch,
      do: {:ok, content},
      else: {:error, :invalid_text}
  end

  @spec digest(binary()) :: String.t()
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
