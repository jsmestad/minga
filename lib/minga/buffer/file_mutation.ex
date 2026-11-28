defmodule Minga.Buffer.FileMutation do
  @moduledoc """
  Prepares one revision-checked file mutation without side effects.

  Exact replacements run in order against prepared content. Each nonempty old text must occur exactly once, including overlapping occurrences. An empty old text appends its new text at the end of the prepared content; when that content is nonempty, does not end with a newline, and the new text does not start with one, a single `"\\n"` separates them so the appended text starts on its own line. An append with empty new text is rejected as `:empty_edit`. A later replacement cannot touch bytes inserted by an earlier replacement. Failure reports the one-based edit index and discards the complete preparation.
  """

  @type operation ::
          {:edit, [{String.t(), String.t()}]}
          | {:replace, String.t()}
          | {:create, String.t()}
          | :delete
  @type expectation :: String.t() | :absent
  @type identity :: {atom(), String.t()}
  @type source :: {:ok, binary()} | {:error, term()}
  @typedoc "An accepted replacement in the byte coordinates it was applied to."
  @type splice :: {start_byte :: non_neg_integer(), removed :: binary(), inserted :: binary()}

  @typedoc "Exact splices in undo order, or a whole-file operation with no observed match points."
  @type geometry :: [splice()] | :whole

  @type preparation :: {:ok, binary() | :deleted, geometry()} | {:error, term()}

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

  @doc "Validates the writer's revision and prepares the bytes and exact geometry of the complete mutation."
  @spec prepare(source(), non_neg_integer() | nil, identity(), expectation(), operation()) ::
          preparation()
  def prepare({:error, :enoent}, _generation, _identity, :absent, {:create, content})
      when is_binary(content),
      do: prepare_whole(content)

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

  @spec prepare_operation(binary(), operation()) :: preparation()
  defp prepare_operation(_content, {:replace, replacement}) when is_binary(replacement),
    do: prepare_whole(replacement)

  defp prepare_operation(_content, :delete), do: {:ok, :deleted, :whole}

  defp prepare_operation(content, {:edit, [_ | _] = edits}),
    do: prepare_edits(content, edits, 1, [], [])

  defp prepare_operation(_content, _operation), do: {:error, :invalid_operation}

  @spec prepare_edits(binary(), list(), pos_integer(), touched(), [splice()]) :: preparation()
  defp prepare_edits(content, [], _index, _touched, splices), do: {:ok, content, splices}

  defp prepare_edits(_content, [{"", ""} | _rest], index, _touched, _splices),
    do: {:error, {:edit_failed, index, :empty_edit}}

  defp prepare_edits(content, [{"", new} | rest], index, touched, splices) when is_binary(new) do
    case validate_content(new) do
      {:ok, _} ->
        # The separator is inserted text too: later edits cannot touch it.
        appended = append_separator(content, new) <> new
        start = byte_size(content)
        inserted = {start, byte_size(appended)}

        prepare_edits(content <> appended, rest, index + 1, [inserted | touched], [
          {start, "", appended} | splices
        ])

      {:error, reason} ->
        {:error, {:edit_failed, index, reason}}
    end
  end

  defp prepare_edits(content, [{old, new} | rest], index, touched, splices)
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

      splices = if old == new, do: splices, else: [{start, old, new} | splices]
      prepare_edits(prepared, rest, index + 1, next_touched, splices)
    else
      {:error, reason} -> {:error, {:edit_failed, index, reason}}
    end
  end

  defp prepare_edits(_content, _edits, index, _touched, _splices),
    do: {:error, {:edit_failed, index, :invalid_edit}}

  @spec prepare_whole(binary()) :: preparation()
  defp prepare_whole(content) do
    with {:ok, content} <- validate_content(content), do: {:ok, content, :whole}
  end

  @spec append_separator(binary(), binary()) :: binary()
  defp append_separator("", _new), do: ""
  defp append_separator(_content, "\n" <> _new), do: ""

  defp append_separator(content, _new) do
    if :binary.last(content) == ?\n, do: "", else: "\n"
  end

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
