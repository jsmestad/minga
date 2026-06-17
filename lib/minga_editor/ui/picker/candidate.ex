defmodule MingaEditor.UI.Picker.Candidate do
  @moduledoc """
  Lean, pre-normalized scoring representation of a picker `%Item{}`.

  The picker's filtering hot path used to re-downcase the label, strip the icon
  prefix, and rebuild the searchable text for every candidate on every keystroke.
  A `Candidate` precomputes those fields once when the item list is set, so
  scoring a large set only does the match work, not the normalization work.

  A candidate carries a reference to its source `item` (for late display
  enrichment) and a stable `index` reflecting the source's original ordering,
  which `Scorer` uses to break score ties exactly as the previous brute-force
  sort did.

  Match positions and per-render display state deliberately do not live here;
  they are derived for the bounded winners only.
  """

  alias MingaEditor.UI.Picker.Item

  @enforce_keys [:item, :norm_label, :norm_search, :label_length, :index]
  defstruct [:item, :norm_label, :norm_search, :label_length, :index]

  @type t :: %__MODULE__{
          item: Item.t(),
          norm_label: String.t(),
          norm_search: String.t(),
          label_length: non_neg_integer(),
          index: non_neg_integer()
        }

  @doc """
  Builds the candidate cache for a list of items, preserving order and tagging
  each candidate with its original index.
  """
  @spec from_items([Item.t()]) :: [t()]
  def from_items(items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> from_item(item, index) end)
  end

  @doc "Builds a single candidate from an item and its index."
  @spec from_item(Item.t(), non_neg_integer()) :: t()
  def from_item(%Item{} = item, index) do
    norm_label = item.label |> String.downcase() |> strip_icon_prefix()

    %__MODULE__{
      item: item,
      norm_label: norm_label,
      norm_search: searchable_text(item),
      label_length: String.length(norm_label),
      index: index
    }
  end

  # The label's first grapheme is a multi-byte icon glyph for file/buffer
  # pickers; drop it (and its trailing space) so matching scores the real text.
  @spec strip_icon_prefix(String.t()) :: String.t()
  defp strip_icon_prefix(label) do
    case String.next_grapheme(label) do
      {g, " " <> rest} when byte_size(g) > 1 -> rest
      _ -> label
    end
  end

  @spec searchable_text(Item.t()) :: String.t()
  defp searchable_text(%Item{} = item) do
    [item.description, item.annotation, item.search_text]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end
end
