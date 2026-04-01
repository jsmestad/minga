defmodule MingaEditor.UI.Picker do
  @moduledoc """
  Generic filterable picker data structure with fuzzy/orderless matching.

  A picker holds a list of items and lets the user filter them by typing
  a query string, navigate with up/down, and select an item. The picker
  is a pure data structure with no side effects — the editor owns the
  rendering and action dispatch.

  ## Fuzzy matching

  The query is split on whitespace into segments. Each segment must match
  independently somewhere in the candidate label or description (orderless).
  Candidates are scored by match quality and sorted best-first:

  - Exact prefix match scores highest
  - Contiguous substring match scores well
  - Fuzzy character-by-character match scores lower
  - Shorter candidates score higher (tighter match)

  ## Usage

      alias MingaEditor.UI.Picker.Item

      picker = Picker.new([
        %Item{id: "pid1", label: "README.md", description: "/project/README.md"},
        %Item{id: "pid2", label: "config.exs", description: "/project/config/config.exs [+]"}
      ], title: "Switch buffer")

      picker = Picker.type_char(picker, "r")
      # filtered to items matching "r"

      picker = Picker.move_down(picker)
      %Item{id: id} = Picker.selected_item(picker)
  """

  @enforce_keys [:items, :title]
  defstruct items: [],
            query: "",
            selected: 0,
            filtered: [],
            max_visible: 10,
            title: "",
            marked: %{}

  alias MingaEditor.UI.Picker.Item

  @typedoc "A picker item struct."
  @type item :: Item.t()

  @typedoc "Picker state. The `marked` map uses item ids as keys (values are `true`)."
  @type t :: %__MODULE__{
          items: [Item.t()],
          query: String.t(),
          selected: non_neg_integer(),
          filtered: [Item.t()],
          max_visible: pos_integer(),
          title: String.t(),
          marked: %{optional(term()) => true}
        }

  @type option :: {:title, String.t()} | {:max_visible, pos_integer()}

  # ── Constructor ──────────────────────────────────────────────────────────────

  @doc "Creates a new picker with the given items."
  @spec new([item()], [option()]) :: t()
  def new(items, opts \\ []) when is_list(items) do
    title = Keyword.get(opts, :title, "")
    max_visible = Keyword.get(opts, :max_visible, 10)

    %__MODULE__{
      items: items,
      title: title,
      max_visible: max_visible,
      filtered: items,
      query: "",
      selected: 0
    }
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

  @doc "Moves the selection down by one page (`max_visible` items), clamped to the last item."
  @spec page_down(t()) :: t()
  def page_down(%__MODULE__{filtered: []} = picker), do: picker

  def page_down(%__MODULE__{selected: sel, filtered: filtered, max_visible: max} = picker) do
    last = length(filtered) - 1
    %{picker | selected: min(sel + max, last)}
  end

  @doc "Moves the selection up by one page (`max_visible` items), clamped to the first item."
  @spec page_up(t()) :: t()
  def page_up(%__MODULE__{filtered: []} = picker), do: picker

  def page_up(%__MODULE__{selected: sel, max_visible: max} = picker) do
    %{picker | selected: max(sel - max, 0)}
  end

  # ── Accessors ───────────────────────────────────────────────────────────────

  @doc "Returns the currently selected item, or nil if no items match."
  @spec selected_item(t()) :: item() | nil
  def selected_item(%__MODULE__{filtered: []}), do: nil

  def selected_item(%__MODULE__{filtered: filtered, selected: sel}) do
    Enum.at(filtered, sel)
  end

  @doc "Returns the selected item's id, or nil."
  @spec selected_id(t()) :: term()
  def selected_id(picker) do
    case selected_item(picker) do
      nil -> nil
      %Item{id: id} -> id
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

  @doc "Toggles the mark on the currently selected item (for multi-select)."
  @spec toggle_mark(t()) :: t()
  def toggle_mark(%__MODULE__{filtered: []} = picker), do: picker

  def toggle_mark(%__MODULE__{marked: marked} = picker) do
    case selected_item(picker) do
      nil ->
        picker

      %Item{id: id} ->
        new_marked =
          if Map.has_key?(marked, id),
            do: Map.delete(marked, id),
            else: Map.put(marked, id, true)

        %{picker | marked: new_marked}
    end
  end

  @doc "Returns all marked items. If none are marked, returns the selected item in a list."
  @spec marked_items(t()) :: [Item.t()]
  def marked_items(%__MODULE__{marked: marked, filtered: filtered} = picker) do
    if map_size(marked) == 0 do
      case selected_item(picker) do
        nil -> []
        item -> [item]
      end
    else
      Enum.filter(filtered, fn %Item{id: id} -> Map.has_key?(marked, id) end)
    end
  end

  @doc "Returns whether an item is marked."
  @spec marked?(t(), Item.t()) :: boolean()
  def marked?(%__MODULE__{marked: marked}, %Item{id: id}) do
    Map.has_key?(marked, id)
  end

  # ── Fuzzy matching (public API for rendering) ────────────────────────────────

  @typedoc "0-based character indices of matched characters in a string."
  @type match_positions :: [non_neg_integer()]

  @doc """
  Returns the indices of characters in `text` that match the current query,
  for use in highlighting matched characters during rendering.

  Returns an empty list if the query is empty or doesn't match.

  ## Examples

      iex> MingaEditor.UI.Picker.match_positions("buffer-switch", "b sw")
      [0, 7, 8]

      iex> MingaEditor.UI.Picker.match_positions("README.md", "")
      []
  """
  @spec match_positions(String.t(), String.t()) :: match_positions()
  def match_positions(_text, ""), do: []

  def match_positions(text, query) when is_binary(text) and is_binary(query) do
    segments = split_query(query)

    if segments == [] do
      []
    else
      down_text = String.downcase(text)
      graphemes = String.graphemes(down_text)

      segments
      |> Enum.flat_map(fn segment ->
        fuzzy_match_positions(graphemes, String.graphemes(segment))
      end)
      |> Enum.sort()
      |> Enum.uniq()
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec refilter(t()) :: t()
  defp refilter(%__MODULE__{items: items, query: ""} = picker) do
    # Clear any stale match positions when query is empty
    cleared = Enum.map(items, &%{&1 | match_positions: []})
    %{picker | filtered: cleared, selected: clamp_selection(picker.selected, length(items))}
  end

  defp refilter(%__MODULE__{items: items, query: query} = picker) do
    segments = split_query(query)

    case segments do
      [] ->
        cleared = Enum.map(items, &%{&1 | match_positions: []})
        %{picker | filtered: cleared, selected: clamp_selection(picker.selected, length(items))}

      _ ->
        scored = score_and_highlight(items, segments, query)
        %{picker | filtered: scored, selected: clamp_selection(picker.selected, length(scored))}
    end
  end

  @spec score_and_highlight([Item.t()], [String.t()], String.t()) :: [Item.t()]
  defp score_and_highlight(items, segments, query) do
    items
    |> Enum.map(&score_item_with_positions(&1, segments, query))
    |> Enum.filter(fn {_item, score} -> score > 0 end)
    |> Enum.sort_by(fn {_item, score} -> -score end)
    |> Enum.map(fn {item, _score} -> item end)
  end

  @spec score_item_with_positions(Item.t(), [String.t()], String.t()) ::
          {Item.t(), non_neg_integer()}
  defp score_item_with_positions(%Item{label: label, description: desc} = item, segments, query) do
    score = score_item(label, desc, segments)
    positions = if score > 0, do: match_positions(label, query), else: []
    {%{item | match_positions: positions}, score}
  end

  # Split query into lowercase segments on whitespace, dropping empty segments.
  @spec split_query(String.t()) :: [String.t()]
  defp split_query(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
  end

  # Score an item against all query segments. All segments must match for a
  # positive score. The total score is the sum of per-segment scores.
  @spec score_item(String.t(), String.t(), [String.t()]) :: non_neg_integer()
  defp score_item(label, desc, segments) do
    down_label = String.downcase(label)
    down_desc = String.downcase(desc)

    segment_scores =
      Enum.map(segments, fn seg ->
        label_score = score_segment(down_label, seg)
        desc_score = score_segment(down_desc, seg)
        max(label_score, desc_score)
      end)

    if Enum.any?(segment_scores, &(&1 == 0)) do
      0
    else
      base = Enum.sum(segment_scores)
      # Bonus for shorter labels (tighter match).
      length_bonus = max(0, 100 - String.length(label))
      base + length_bonus
    end
  end

  # Score a single segment against a string.
  # Returns 0 if no match.
  @spec score_segment(String.t(), String.t()) :: non_neg_integer()
  defp score_segment(text, segment) do
    cond do
      # Exact prefix match — best score
      String.starts_with?(text, segment) ->
        300

      # Contiguous substring match
      String.contains?(text, segment) ->
        200

      # Fuzzy character-by-character match
      fuzzy_match?(text, segment) ->
        100

      true ->
        0
    end
  end

  # Check if all characters in `needle` appear in order in `haystack`.
  @spec fuzzy_match?(String.t(), String.t()) :: boolean()
  defp fuzzy_match?(haystack, needle) do
    haystack_graphemes = String.graphemes(haystack)
    needle_graphemes = String.graphemes(needle)
    do_fuzzy_match?(haystack_graphemes, needle_graphemes)
  end

  @spec do_fuzzy_match?([String.t()], [String.t()]) :: boolean()
  defp do_fuzzy_match?(_haystack, []), do: true
  defp do_fuzzy_match?([], _needle), do: false

  defp do_fuzzy_match?([h | h_rest], [n | n_rest] = needle) do
    if h == n do
      do_fuzzy_match?(h_rest, n_rest)
    else
      do_fuzzy_match?(h_rest, needle)
    end
  end

  # Find the 0-based indices of matched characters for a single segment.
  @spec fuzzy_match_positions([String.t()], [String.t()]) :: [non_neg_integer()]
  defp fuzzy_match_positions(text_graphemes, segment_graphemes) do
    # Prefer contiguous match first (find substring position)
    case find_substring_positions(text_graphemes, segment_graphemes) do
      {:ok, positions} ->
        positions

      :no_match ->
        # Fall back to fuzzy match
        do_fuzzy_positions(text_graphemes, segment_graphemes, 0, [])
    end
  end

  # Find contiguous substring match positions.
  @spec find_substring_positions([String.t()], [String.t()]) ::
          {:ok, [non_neg_integer()]} | :no_match
  defp find_substring_positions(text, segment) do
    seg_len = length(segment)
    text_len = length(text)

    if seg_len > text_len do
      :no_match
    else
      result =
        Enum.find(0..(text_len - seg_len)//1, fn start ->
          Enum.slice(text, start, seg_len) == segment
        end)

      case result do
        nil -> :no_match
        start -> {:ok, Enum.to_list(start..(start + seg_len - 1)//1)}
      end
    end
  end

  @spec do_fuzzy_positions([String.t()], [String.t()], non_neg_integer(), [non_neg_integer()]) ::
          [non_neg_integer()]
  defp do_fuzzy_positions(_text, [], _idx, acc), do: Enum.reverse(acc)
  defp do_fuzzy_positions([], _seg, _idx, _acc), do: []

  defp do_fuzzy_positions([t | t_rest], [s | s_rest] = seg, idx, acc) do
    if t == s do
      do_fuzzy_positions(t_rest, s_rest, idx + 1, [idx | acc])
    else
      do_fuzzy_positions(t_rest, seg, idx + 1, acc)
    end
  end

  @spec clamp_selection(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp clamp_selection(_sel, 0), do: 0
  defp clamp_selection(sel, count), do: min(sel, count - 1)
end
