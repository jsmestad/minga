defmodule Minga.Session.Layout do
  @moduledoc """
  The window splits of a saved session, as a tree of `Minga.Session.Pane` leaves.

  The shape mirrors the editor's window tree: a leaf is one window, and a split holds two subtrees with a direction and the first subtree's size in cells (0 means an even split). `build/2` turns a live window tree into a layout and drops windows that show no file (a conversation, the home view): a split that loses one side collapses into the other, so the saved layout only names windows a restore can reopen.

  Pure: no process or file access. JSON encoding goes through `to_map/1` and `from_map/1` because the tree is made of tuples.
  """

  alias Minga.Session.Pane

  @typedoc "Split direction, as in the editor's window tree."
  @type direction :: :vertical | :horizontal

  @typedoc "A saved layout tree."
  @type t :: {:pane, Pane.t()} | {:split, direction(), t(), t(), non_neg_integer()}

  @typedoc "A live window tree: leaves carry a window id."
  @type window_tree ::
          {:leaf, term()} | {:split, direction(), window_tree(), window_tree(), non_neg_integer()}

  @doc """
  Builds a layout from a live window tree.

  `pane_for` maps a window id to its saved pane, or `nil` for a window that shows no file. Returns `nil` when no window shows a file.
  """
  @spec build(window_tree(), (term() -> Pane.t() | nil)) :: t() | nil
  def build({:leaf, id}, pane_for) when is_function(pane_for, 1) do
    case pane_for.(id) do
      %Pane{} = pane -> {:pane, pane}
      nil -> nil
    end
  end

  def build({:split, direction, first, second, size}, pane_for) do
    case {build(first, pane_for), build(second, pane_for)} do
      {nil, nil} -> nil
      {kept, nil} -> kept
      {nil, kept} -> kept
      {a, b} -> {:split, direction, a, b, size}
    end
  end

  @doc "The panes in leaf order: left before right, top before bottom."
  @spec panes(t()) :: [Pane.t()]
  def panes({:pane, pane}), do: [pane]
  def panes({:split, _direction, first, second, _size}), do: panes(first) ++ panes(second)

  @doc "Encodes the layout as a JSON-ready map."
  @spec to_map(t()) :: map()
  def to_map({:pane, %Pane{} = pane}), do: %{"pane" => Pane.to_map(pane)}

  def to_map({:split, direction, first, second, size}) do
    %{
      "split" => Atom.to_string(direction),
      "size" => size,
      "first" => to_map(first),
      "second" => to_map(second)
    }
  end

  @doc "Decodes a layout from its JSON map. Returns `:error` for any malformed node."
  @spec from_map(term()) :: {:ok, t()} | :error
  def from_map(%{"pane" => pane}) do
    case Pane.from_map(pane) do
      {:ok, pane} -> {:ok, {:pane, pane}}
      :error -> :error
    end
  end

  def from_map(%{"split" => direction, "first" => first, "second" => second} = map)
      when direction in ["vertical", "horizontal"] do
    with {:ok, first} <- from_map(first),
         {:ok, second} <- from_map(second) do
      {:ok, {:split, String.to_existing_atom(direction), first, second, size(map["size"])}}
    end
  end

  def from_map(_other), do: :error

  @spec size(term()) :: non_neg_integer()
  defp size(value) when is_integer(value) and value >= 0, do: value
  defp size(_value), do: 0
end
