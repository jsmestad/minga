defmodule Minga.RenderModel.Window.RowDelta do
  @moduledoc """
  A validated row-sequence transition expressed in immutable-base coordinates.

  The current renderer can derive one prefix/suffix splice from two snapshots via
  `from_snapshots/2`. Ticket #2742 can replace that derivation with ChangeLog-owned
  splices without changing the encoder or frontend wire contract.
  """

  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowSplice

  @enforce_keys [:base_row_count, :result_row_count, :splices]
  defstruct [:base_row_count, :result_row_count, :splices]

  @type t :: %__MODULE__{
          base_row_count: non_neg_integer(),
          result_row_count: non_neg_integer(),
          splices: [RowSplice.t()]
        }

  @type validation_error ::
          :count_out_of_range
          | :empty_splice
          | :splice_out_of_range
          | :splices_not_strictly_ascending
          | :splices_overlap
          | :result_count_mismatch

  @max_u32 0xFFFF_FFFF

  @doc "Builds and validates a row delta."
  @spec new(non_neg_integer(), non_neg_integer(), [RowSplice.t()]) ::
          {:ok, t()} | {:error, validation_error()}
  def new(base_row_count, result_row_count, splices)
      when is_integer(base_row_count) and is_integer(result_row_count) and is_list(splices) do
    delta = %__MODULE__{
      base_row_count: base_row_count,
      result_row_count: result_row_count,
      splices: splices
    }

    case validate(delta) do
      :ok -> {:ok, delta}
      {:error, _reason} = error -> error
    end
  end

  @doc "Validates immutable-base ordering, ranges, and exact result arithmetic."
  @spec validate(t()) :: :ok | {:error, validation_error()}
  def validate(%__MODULE__{} = delta) do
    with :ok <- validate_counts(delta),
         :ok <- validate_splices(delta.splices, delta.base_row_count, nil) do
      validate_result_count(delta)
    end
  end

  @doc "Derives the temporary single prefix/suffix splice used before #2742 supplies ChangeLog deltas."
  @spec from_snapshots([Row.t()], [Row.t()]) :: t()
  def from_snapshots(base_rows, result_rows) when is_list(base_rows) and is_list(result_rows) do
    prefix = common_prefix_count(base_rows, result_rows, 0)
    base_tail = Enum.drop(base_rows, prefix)
    result_tail = Enum.drop(result_rows, prefix)
    suffix = common_suffix_count(base_tail, result_tail, 0)
    delete_count = length(base_rows) - prefix - suffix
    insert_count = length(result_rows) - prefix - suffix
    insert_rows = Enum.slice(result_rows, prefix, insert_count)

    splices =
      case {delete_count, insert_rows} do
        {0, []} -> []
        _ -> [RowSplice.new(prefix, delete_count, insert_rows)]
      end

    {:ok, delta} = new(length(base_rows), length(result_rows), splices)
    delta
  end

  @spec validate_counts(t()) :: :ok | {:error, :count_out_of_range}
  defp validate_counts(%__MODULE__{base_row_count: base, result_row_count: result})
       when base >= 0 and base <= @max_u32 and result >= 0 and result <= @max_u32,
       do: :ok

  defp validate_counts(_delta), do: {:error, :count_out_of_range}

  @spec validate_splices([RowSplice.t()], non_neg_integer(), RowSplice.t() | nil) ::
          :ok | {:error, validation_error()}
  defp validate_splices([], _base_count, _previous), do: :ok

  defp validate_splices([%RowSplice{} = splice | rest], base_count, previous) do
    with :ok <- validate_nonempty(splice),
         :ok <- validate_range(splice, base_count),
         :ok <- validate_order(previous, splice) do
      validate_splices(rest, base_count, splice)
    end
  end

  @spec validate_nonempty(RowSplice.t()) :: :ok | {:error, :empty_splice}
  defp validate_nonempty(%RowSplice{delete_count: 0, insert_rows: []}),
    do: {:error, :empty_splice}

  defp validate_nonempty(_splice), do: :ok

  @spec validate_range(RowSplice.t(), non_neg_integer()) ::
          :ok | {:error, :splice_out_of_range}
  defp validate_range(%RowSplice{} = splice, base_count)
       when splice.start_index >= 0 and splice.delete_count >= 0 and
              splice.start_index <= base_count and
              splice.start_index + splice.delete_count <= base_count and
              splice.start_index <= @max_u32 and splice.delete_count <= @max_u32,
       do: :ok

  defp validate_range(_splice, _base_count), do: {:error, :splice_out_of_range}

  @spec validate_order(RowSplice.t() | nil, RowSplice.t()) ::
          :ok | {:error, :splices_not_strictly_ascending | :splices_overlap}
  defp validate_order(nil, _splice), do: :ok

  defp validate_order(%RowSplice{} = previous, %RowSplice{} = splice)
       when splice.start_index <= previous.start_index,
       do: {:error, :splices_not_strictly_ascending}

  defp validate_order(%RowSplice{} = previous, %RowSplice{} = splice)
       when splice.start_index < previous.start_index + previous.delete_count,
       do: {:error, :splices_overlap}

  defp validate_order(_previous, _splice), do: :ok

  @spec validate_result_count(t()) :: :ok | {:error, :result_count_mismatch}
  defp validate_result_count(%__MODULE__{} = delta) do
    result =
      Enum.reduce(delta.splices, delta.base_row_count, fn splice, count ->
        count - splice.delete_count + RowSplice.insert_count(splice)
      end)

    if result == delta.result_row_count, do: :ok, else: {:error, :result_count_mismatch}
  end

  @spec common_prefix_count([Row.t()], [Row.t()], non_neg_integer()) :: non_neg_integer()
  defp common_prefix_count([row | base], [row | result], count),
    do: common_prefix_count(base, result, count + 1)

  defp common_prefix_count(_base, _result, count), do: count

  @spec common_suffix_count([Row.t()], [Row.t()], non_neg_integer()) :: non_neg_integer()
  defp common_suffix_count(base, result, count) do
    common_prefix_count(Enum.reverse(base), Enum.reverse(result), count)
  end
end
