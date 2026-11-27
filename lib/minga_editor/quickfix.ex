defmodule MingaEditor.Quickfix do
  @moduledoc "A shared editor list of file locations, separate from the producer's review or search view."

  alias Minga.Buffer.Document
  alias Minga.Buffer.UndoHistory
  alias MingaAgent.Session.ConnectionTarget

  @type destination :: {:review_unit, pid(), UndoHistory.review_location()} | :file
  @type entry :: {Path.t(), Document.position(), destination()}
  @type source ::
          {:task_review, String.t(), non_neg_integer(), ConnectionTarget.t()}
          | :search
          | :diagnostics
  @type t :: %__MODULE__{
          source: source() | nil,
          entries: tuple(),
          current: non_neg_integer() | nil
        }
  defstruct source: nil, entries: {}, current: nil

  @spec replace(source(), [entry()]) :: t()
  def replace(source, entries), do: %__MODULE__{source: source, entries: List.to_tuple(entries)}

  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: Tuple.to_list(entries)

  @spec move(t(), :next | :previous) :: :empty | {entry(), t()}
  def move(%__MODULE__{entries: {}}, _), do: :empty

  def move(%__MODULE__{entries: entries, current: current} = list, direction) do
    size = tuple_size(entries)

    index =
      case {current, direction} do
        {nil, :next} -> 0
        {nil, :previous} -> size - 1
        {current, :next} -> rem(current + 1, size)
        {current, :previous} -> Integer.mod(current - 1, size)
      end

    {elem(entries, index), %{list | current: index}}
  end
end
