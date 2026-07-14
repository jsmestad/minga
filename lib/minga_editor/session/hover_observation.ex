defmodule MingaEditor.Session.HoverObservation do
  @moduledoc """
  Transient pointer observation used for Cmd/Ctrl-hover navigation.

  The link and the cell that produced it change together. Keeping both in one
  value prevents a stale deduplication cell from outliving its visible link.
  This value is frame-local and is never included in tab snapshots.
  """

  @typedoc "A buffer position as `{line, byte_col}`."
  @type position :: {non_neg_integer(), non_neg_integer()}
  @type link :: {position(), position()} | nil

  defstruct link: nil, cell: nil

  @type t :: %__MODULE__{link: link(), cell: position() | nil}

  @doc "Records the currently resolved navigation link."
  @spec observe_link(t(), link()) :: t()
  def observe_link(%__MODULE__{} = observation, link), do: %{observation | link: link}

  @doc "Records the pointer cell that produced the current observation."
  @spec observe_cell(t(), position() | nil) :: t()
  def observe_cell(%__MODULE__{} = observation, cell), do: %{observation | cell: cell}

  @doc "Clears the complete transient hover observation."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{}), do: %__MODULE__{}

  @doc "Returns whether this observation was resolved at the given cell."
  @spec at_cell?(t(), position()) :: boolean()
  def at_cell?(%__MODULE__{cell: cell}, cell), do: true
  def at_cell?(%__MODULE__{}, _cell), do: false
end
