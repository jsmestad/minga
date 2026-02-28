defmodule Minga.Picker do
  @moduledoc """
  Generic filterable picker data structure.

  A picker holds a list of items and lets the user filter them by typing
  a query string, navigate with up/down, and select an item. The picker
  is a pure data structure with no side effects — the editor owns the
  rendering and action dispatch.

  ## Usage

      picker = Picker.new([
        {"pid1", "README.md", "/project/README.md"},
        {"pid2", "config.exs", "/project/config/config.exs [+]"}
      ], title: "Switch buffer")

      picker = Picker.type_char(picker, "r")
      # filtered to items matching "r"

      picker = Picker.move_down(picker)
      {id, label, desc} = Picker.selected_item(picker)
  """

  @enforce_keys [:items, :title]
  defstruct items: [],
            query: "",
            selected: 0,
            filtered: [],
            max_visible: 10,
            title: ""

  @typedoc "A unique identifier for a picker item."
  @type item_id :: term()

  @typedoc "A picker item: `{id, label, description}`."
  @type item :: {item_id(), String.t(), String.t()}

  @typedoc "Picker state."
  @type t :: %__MODULE__{
          items: [item()],
          query: String.t(),
          selected: non_neg_integer(),
          filtered: [item()],
          max_visible: pos_integer(),
          title: String.t()
        }

  @type option :: {:title, String.t()} | {:max_visible, pos_integer()}

  # ── Constructor ──────────────────────────────────────────────────────────────

  @doc "Creates a new picker with the given items."
  @spec new([item()], [option()]) :: t()
  def new(items, opts \\ []) when is_list(items) do
    title = Keyword.get(opts, :title, "")
    max_visible = Keyword.get(opts, :max_visible, 10)

    picker = %__MODULE__{
      items: items,
      title: title,
      max_visible: max_visible,
      filtered: items,
      query: "",
      selected: 0
    }

    picker
  end

  # ── Query manipulation ──────────────────────────────────────────────────────

  @doc "Appends a character to the query and refilters."
  @spec type_char(t(), String.t()) :: t()
  def type_char(%__MODULE__{query: query} = picker, char) when is_binary(char) do
    refilter(%{picker | query: query <> char})
  end

  @doc "Removes the last character from the query and refilters."
  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{query: ""} = picker), do: picker

  def backspace(%__MODULE__{query: query} = picker) do
    new_query = String.slice(query, 0, String.length(query) - 1)
    refilter(%{picker | query: new_query})
  end

  @doc "Sets the query to an exact value and refilters."
  @spec filter(t(), String.t()) :: t()
  def filter(%__MODULE__{} = picker, query) when is_binary(query) do
    refilter(%{picker | query: query})
  end

  # ── Navigation ──────────────────────────────────────────────────────────────

  @doc "Moves the selection down by one (wraps around)."
  @spec move_down(t()) :: t()
  def move_down(%__MODULE__{filtered: []} = picker), do: picker

  def move_down(%__MODULE__{selected: sel, filtered: filtered} = picker) do
    %{picker | selected: rem(sel + 1, length(filtered))}
  end

  @doc "Moves the selection up by one (wraps around)."
  @spec move_up(t()) :: t()
  def move_up(%__MODULE__{filtered: []} = picker), do: picker

  def move_up(%__MODULE__{selected: 0, filtered: filtered} = picker) do
    %{picker | selected: length(filtered) - 1}
  end

  def move_up(%__MODULE__{selected: sel} = picker) do
    %{picker | selected: sel - 1}
  end

  # ── Accessors ───────────────────────────────────────────────────────────────

  @doc "Returns the currently selected item, or nil if no items match."
  @spec selected_item(t()) :: item() | nil
  def selected_item(%__MODULE__{filtered: []}), do: nil

  def selected_item(%__MODULE__{filtered: filtered, selected: sel}) do
    Enum.at(filtered, sel)
  end

  @doc "Returns the selected item's id, or nil."
  @spec selected_id(t()) :: item_id() | nil
  def selected_id(picker) do
    case selected_item(picker) do
      nil -> nil
      {id, _label, _desc} -> id
    end
  end

  @doc """
  Returns the slice of filtered items visible in the picker window,
  along with the index of the selected item within that slice.

  Returns `{visible_items, selected_offset}`.
  """
  @spec visible_items(t()) :: {[item()], non_neg_integer()}
  def visible_items(%__MODULE__{filtered: [], max_visible: _max}) do
    {[], 0}
  end

  def visible_items(%__MODULE__{filtered: filtered, selected: sel, max_visible: max}) do
    total = length(filtered)

    if total <= max do
      {filtered, sel}
    else
      # Scroll the window to keep the selection visible
      half = div(max, 2)
      start = max(0, min(sel - half, total - max))
      visible = Enum.slice(filtered, start, max)
      offset = sel - start
      {visible, offset}
    end
  end

  @doc "Returns the number of filtered items."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{filtered: filtered}), do: length(filtered)

  @doc "Returns the total number of items (unfiltered)."
  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{items: items}), do: length(items)

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec refilter(t()) :: t()
  defp refilter(%__MODULE__{items: items, query: ""} = picker) do
    %{picker | filtered: items, selected: clamp_selection(picker.selected, length(items))}
  end

  defp refilter(%__MODULE__{items: items, query: query} = picker) do
    q = String.downcase(query)

    filtered =
      Enum.filter(items, fn {_id, label, desc} ->
        String.contains?(String.downcase(label), q) or
          String.contains?(String.downcase(desc), q)
      end)

    %{picker | filtered: filtered, selected: clamp_selection(picker.selected, length(filtered))}
  end

  @spec clamp_selection(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp clamp_selection(_sel, 0), do: 0
  defp clamp_selection(sel, count), do: min(sel, count - 1)
end
