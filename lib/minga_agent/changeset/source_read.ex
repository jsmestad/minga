defmodule MingaAgent.Changeset.SourceRead do
  @moduledoc "Bounded selection of a changeset-owned source with its atomic revision."

  alias MingaAgent.Tool.Output.LineSelection

  @type source :: {:ok, {:memory, binary()} | {:disk, String.t()}} | {:error, term()}
  @type prefix_result ::
          {:ok, {:memory, binary(), boolean()} | {:disk, String.t()}, non_neg_integer()}
          | {:error, term()}
  @type lines_result ::
          {:ok,
           {:memory, binary(), non_neg_integer(), non_neg_integer() | :unknown, boolean()}
           | {:disk, String.t()}, non_neg_integer()}
          | {:error, term()}

  @doc "Copies only a bounded prefix out of the selected resident source."
  @spec prefix(source(), non_neg_integer(), pos_integer()) :: prefix_result()
  def prefix({:ok, {:memory, bytes}}, revision, max_bytes) do
    size = min(byte_size(bytes), max_bytes)

    prefix =
      if size == byte_size(bytes), do: bytes, else: :binary.copy(binary_part(bytes, 0, size))

    {:ok, {:memory, prefix, size == byte_size(bytes)}, revision}
  end

  def prefix({:ok, {:disk, path}}, revision, _max_bytes), do: {:ok, {:disk, path}, revision}
  def prefix({:error, _reason} = error, _revision, _max_bytes), do: error

  @doc "Selects requested lines without materializing or indexing the full resident source."
  @spec lines(source(), non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()) ::
          lines_result()
  def lines({:ok, {:memory, bytes}}, revision, start, count, max_bytes) do
    {selected, selected_count, total, complete?} =
      LineSelection.from_binary(bytes, start, count, max_bytes)

    {:ok, {:memory, selected, selected_count, total, complete?}, revision}
  end

  def lines({:ok, {:disk, path}}, revision, _start, _count, _max_bytes),
    do: {:ok, {:disk, path}, revision}

  def lines({:error, _reason} = error, _revision, _start, _count, _max_bytes), do: error
end
