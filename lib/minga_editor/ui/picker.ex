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
            candidates: [],
            query: "",
            selected: 0,
            filtered: [],
            max_visible: 10,
            title: "",
            marked: %{}

  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Scorer

  # Upper bound on how many results filtering retains. Sources with fewer items
  # are unaffected (the full set fits); large sources (e.g. the file picker with
  # tens of thousands of paths) are bounded to the best matches so each keystroke
  # never scores-and-sorts the entire candidate list. Generous so paging past the
  # visible window still has somewhere to land.
  #
  # Consequence: `count/1` (and the picker footer's filtered count) reports how
  # many results are *shown*, capped here, not the true number of matches in a
  # huge source. `total/1` still reflects the full candidate count.
  @result_limit 200

  @typedoc "A picker item struct."
  @type item :: Item.t()

  @typedoc "Picker state. The `marked` map uses item ids as keys (values are `true`)."
  @type t :: %__MODULE__{
          items: [Item.t()],
          candidates: [Candidate.t()],
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

    refilter(%__MODULE__{
      items: items,
      candidates: Candidate.from_items(items),
      title: title,
      max_visible: max_visible,
      filtered: items,
      query: "",
      selected: 0
    })
  end

  @doc "Replaces the item list and refilters against the current query."
  @spec replace_items(t(), [item()]) :: t()
  def replace_items(%__MODULE__{} = picker, items) when is_list(items) do
    refilter(%{picker | items: items, candidates: Candidate.from_items(items)})
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

  @doc """
  Sets the query without refiltering, keeping the current `filtered` results.

  Used by the async/revision-tagged filtering path: the query updates
  immediately for display while the (potentially expensive) refilter is
  scheduled separately, so previous results stay visible until it completes.
  """
  @spec put_query(t(), String.t()) :: t()
  def put_query(%__MODULE__{} = picker, query) when is_binary(query) do
    %{picker | query: query}
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
  def visible_items(%__MODULE__{max_visible: max} = picker), do: visible_items(picker, max)

  @doc "Returns the visible slice using an explicit maximum item count."
  @spec visible_items(t(), non_neg_integer()) :: {[item()], non_neg_integer()}
  def visible_items(%__MODULE__{}, 0), do: {[], 0}

  def visible_items(%__MODULE__{filtered: []}, _max) do
    {[], 0}
  end

  def visible_items(%__MODULE__{filtered: filtered, selected: sel}, max) do
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
  def marked_items(%__MODULE__{marked: marked, items: items} = picker) do
    if map_size(marked) == 0 do
      case selected_item(picker) do
        nil -> []
        item -> [item]
      end
    else
      Enum.filter(items, fn %Item{id: id} -> Map.has_key?(marked, id) end)
    end
  end

  @doc "Returns true when the picker has explicit multi-select marks."
  @spec has_marks?(t()) :: boolean()
  def has_marks?(%__MODULE__{marked: marked}), do: map_size(marked) > 0

  @doc "Returns the number of explicitly marked items."
  @spec marked_count(t()) :: non_neg_integer()
  def marked_count(%__MODULE__{marked: marked}), do: map_size(marked)

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

  # Empty query: no scoring, just present the leading slice of the (already
  # source-ordered) items, bounded so huge sources don't materialize every item.
  @spec refilter(t()) :: t()
  defp refilter(%__MODULE__{items: items, query: ""} = picker) do
    filtered = bounded_unscored(items, result_limit(picker))
    %{picker | filtered: filtered, selected: clamp_selection(picker.selected, length(filtered))}
  end

  defp refilter(%__MODULE__{candidates: candidates, query: query} = picker) do
    case split_query(query) do
      [] ->
        filtered = bounded_unscored(picker.items, result_limit(picker))

        %{
          picker
          | filtered: filtered,
            selected: clamp_selection(picker.selected, length(filtered))
        }

      segments ->
        filtered =
          candidates
          |> Scorer.top_k(segments, result_limit(picker))
          |> Enum.map(&highlight_winner(&1, query))

        %{
          picker
          | filtered: filtered,
            selected: clamp_selection(picker.selected, length(filtered))
        }
    end
  end

  # Build a displayable item from a winning candidate, attaching match positions.
  # Positions are computed only here, for the bounded winners, never for the
  # whole candidate set.
  @spec highlight_winner(Candidate.t(), String.t()) :: Item.t()
  defp highlight_winner(%Candidate{item: %Item{label: label} = item}, query) do
    %{item | match_positions: match_positions(label, query)}
  end

  @spec bounded_unscored([Item.t()], pos_integer()) :: [Item.t()]
  defp bounded_unscored(items, limit) do
    items
    |> Enum.take(limit)
    |> Enum.map(&%{&1 | match_positions: []})
  end

  @spec result_limit(t()) :: pos_integer()
  defp result_limit(%__MODULE__{max_visible: max_visible}) do
    max(@result_limit, max_visible)
  end

  # Split query into lowercase segments on whitespace, dropping empty segments.
  @spec split_query(String.t()) :: [String.t()]
  defp split_query(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
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
