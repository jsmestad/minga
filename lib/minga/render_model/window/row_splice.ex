defmodule Minga.RenderModel.Window.RowSplice do
  @moduledoc """
  One immutable-base row splice in a `RowDelta`.

  `start_index` and `delete_count` address the row sequence before any splice in
  the delta is applied. `insert_rows` are inserted at that base coordinate.
  """

  alias Minga.RenderModel.Window.Row

  @enforce_keys [:start_index, :delete_count, :insert_rows]
  defstruct [:start_index, :delete_count, :insert_rows]

  @type t :: %__MODULE__{
          start_index: non_neg_integer(),
          delete_count: non_neg_integer(),
          insert_rows: [Row.t()]
        }

  @doc "Builds one immutable-base row splice."
  @spec new(non_neg_integer(), non_neg_integer(), [Row.t()]) :: t()
  def new(start_index, delete_count, insert_rows)
      when is_integer(start_index) and start_index >= 0 and is_integer(delete_count) and
             delete_count >= 0 and is_list(insert_rows) do
    %__MODULE__{
      start_index: start_index,
      delete_count: delete_count,
      insert_rows: insert_rows
    }
  end

  @doc "Returns the exclusive base-row end coordinate deleted by this splice."
  @spec base_end(t()) :: non_neg_integer()
  def base_end(%__MODULE__{} = splice), do: splice.start_index + splice.delete_count

  @doc "Returns the number of rows inserted by this splice."
  @spec insert_count(t()) :: non_neg_integer()
  def insert_count(%__MODULE__{} = splice), do: length(splice.insert_rows)
end
