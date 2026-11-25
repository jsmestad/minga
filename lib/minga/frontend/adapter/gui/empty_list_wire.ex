defmodule Minga.Frontend.Adapter.GUI.EmptyListWire do
  @moduledoc """
  The wire form of an empty list, shared by every encoder whose surface can show one: the picker, the file tree and Git status.

  `nil` becomes an empty list with an empty title, which frontends read as "no empty state".
  """

  alias Minga.RenderModel.UI.EmptyList

  @typedoc "The `empty_list` structure the schema-generated encoders take."
  @type t :: %{
          glyph: String.t(),
          title: String.t(),
          why: String.t(),
          selected: non_neg_integer(),
          actions: [%{id: String.t(), key: String.t(), label: String.t()}]
        }

  @doc "The wire map for `empty`, or a blank one when there is no empty state."
  @spec to_wire(EmptyList.t() | nil) :: t()
  def to_wire(nil), do: %{glyph: "", title: "", why: "", selected: 0, actions: []}

  def to_wire(%EmptyList{} = empty) do
    %{
      glyph: empty.glyph,
      title: empty.title,
      why: empty.why,
      selected: empty.selected,
      actions: Enum.map(empty.actions, &%{id: &1.id, key: &1.key, label: &1.label})
    }
  end
end
