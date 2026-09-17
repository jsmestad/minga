defmodule Minga.Editing.Completion do
  @moduledoc """
  Pure data structure for managing LSP completion state.

  Holds the list of completion items returned by a language server,
  tracks the selected index, and filters items as the user continues
  typing. All functions are pure transformations with no side effects.

  ## Lifecycle

  1. `new/2` — create from parsed LSP completion items and a trigger position
  2. `filter/2` — narrow the visible items as the user types more characters
  3. `move_up/1` / `move_down/1` — navigate the selection
  4. `selected_item/1` — get the currently highlighted item
  5. `accept/1` — returns the text/edit to insert for the selected item
  """

  alias Minga.Editing.Completion.Item

  @enforce_keys [:items, :trigger_position]
  defstruct items: [],
            filtered: [],
            selected: 0,
            filter_text: "",
            trigger_position: {0, 0},
            max_visible: 10,
            resolve_timer: nil,
            last_resolved_identity: nil,
            selected_item_id: nil

  @typedoc "LSP CompletionItemKind as an atom."
  @type item_kind :: Item.kind()

  @typedoc "A text edit to apply when accepting a completion."
  @type text_edit :: Item.text_edit()

  @typedoc "A parsed completion item."
  @type item :: Item.t()

  @type t :: %__MODULE__{
          items: [item()],
          filtered: [item()],
          selected: non_neg_integer(),
          filter_text: String.t(),
          trigger_position: {non_neg_integer(), non_neg_integer()},
          max_visible: pos_integer(),
          resolve_timer: reference() | nil,
          last_resolved_identity: map() | nil,
          selected_item_id: Item.id() | nil
        }

  # ── Constructor ──────────────────────────────────────────────────────────────

  @doc """
  Creates a new completion state from a list of parsed items and the
  cursor position where completion was triggered.
  """
  @spec new([item()], {non_neg_integer(), non_neg_integer()}) :: t()
  def new(items, trigger_position) when is_list(items) do
    sorted = items |> Enum.map(&normalize_item/1) |> Enum.sort_by(& &1.sort_text)

    %__MODULE__{
      items: sorted,
      filtered: sorted,
      trigger_position: trigger_position,
      selected: 0,
      selected_item_id: first_item_id(sorted)
    }
  end

  # ── Filtering ────────────────────────────────────────────────────────────────

  @doc """
  Filters completion items by the text typed since the trigger position.

  Items whose `filter_text` starts with `prefix` (case-insensitive) are kept.
  Resets selection to the top.
  """
  @spec filter(t(), String.t()) :: t()
  def filter(%__MODULE__{} = completion, prefix) when is_binary(prefix) do
    down_prefix = String.downcase(prefix)

    filtered =
      completion.items
      |> Enum.filter(fn item ->
        String.starts_with?(String.downcase(item.filter_text), down_prefix)
      end)

    %{
      completion
      | filtered: filtered,
        filter_text: prefix,
        selected: 0,
        selected_item_id: item_id_at(filtered, 0)
    }
  end

  # ── Navigation ───────────────────────────────────────────────────────────────

  @doc "Moves the selection down one item, wrapping at the bottom."
  @spec move_down(t()) :: t()
  def move_down(%__MODULE__{filtered: []} = c), do: c

  def move_down(%__MODULE__{filtered: filtered, selected: sel} = c) do
    selected = rem(sel + 1, length(filtered))
    %{c | selected: selected, selected_item_id: item_id_at(filtered, selected)}
  end

  @doc "Moves the selection up one item, wrapping at the top."
  @spec move_up(t()) :: t()
  def move_up(%__MODULE__{filtered: []} = c), do: c

  def move_up(%__MODULE__{filtered: filtered, selected: sel} = c) do
    new_sel = if sel == 0, do: length(filtered) - 1, else: sel - 1
    %{c | selected: new_sel, selected_item_id: item_id_at(filtered, new_sel)}
  end

  # ── Selection ────────────────────────────────────────────────────────────────

  @doc "Selects an item by its offset in the current visible completion window."
  @spec select_visible(t(), non_neg_integer()) :: t()
  def select_visible(%__MODULE__{filtered: []} = completion, _offset), do: completion

  def select_visible(%__MODULE__{} = completion, offset)
      when is_integer(offset) and offset >= 0 do
    {visible, _selected_offset} = visible_items(completion)

    if Enum.at(visible, offset) == nil do
      completion
    else
      selected = visible_start(completion) + offset

      %{
        completion
        | selected: selected,
          selected_item_id: item_id_at(completion.filtered, selected)
      }
    end
  end

  @doc "Returns the currently selected item, or nil if no items."
  @spec selected_item(t()) :: item() | nil
  def selected_item(%__MODULE__{filtered: []}), do: nil

  def selected_item(%__MODULE__{filtered: filtered, selected: sel}) do
    Enum.at(filtered, sel)
  end

  @doc "Selects an item by stable identity when it remains visible."
  @spec select_item(t(), Item.id() | nil) :: t()
  def select_item(%__MODULE__{} = completion, nil), do: completion

  def select_item(%__MODULE__{} = completion, item_id) do
    case Enum.find_index(completion.filtered, &(&1.id == item_id)) do
      nil -> completion
      selected -> %{completion | selected: selected, selected_item_id: item_id}
    end
  end

  @doc """
  Returns the insert text and optional text edit for the selected item.

  If the item has a `text_edit`, returns `{:text_edit, edit}`.
  Otherwise returns `{:insert_text, text}`.
  """
  @spec accept(t()) :: {:insert_text, String.t()} | {:text_edit, text_edit()} | nil
  def accept(%__MODULE__{} = completion) do
    case selected_item(completion) do
      nil ->
        nil

      %{text_edit: %{} = edit} ->
        {:text_edit, edit}

      %{insert_text: text} ->
        {:insert_text, text}
    end
  end

  # ── Visibility ───────────────────────────────────────────────────────────────

  @doc """
  Returns `{visible_items, selected_offset}` for rendering.

  `visible_items` is a window of at most `max_visible` items centered
  around the selection. `selected_offset` is the index of the selected
  item within that window.
  """
  @spec visible_items(t()) :: {[item()], non_neg_integer()}
  def visible_items(%__MODULE__{filtered: []}), do: {[], 0}

  def visible_items(%__MODULE__{filtered: filtered, selected: sel, max_visible: max_vis} = c) do
    start = visible_start(c)
    visible = Enum.slice(filtered, start, min(length(filtered), max_vis))
    {visible, sel - start}
  end

  @spec visible_start(t()) :: non_neg_integer()
  defp visible_start(%__MODULE__{filtered: filtered, selected: sel, max_visible: max_vis}) do
    visible_start(length(filtered), sel, max_vis)
  end

  @spec visible_start(non_neg_integer(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp visible_start(total, _sel, max_vis) when total <= max_vis, do: 0
  defp visible_start(_total, sel, max_vis) when sel < div(max_vis, 2), do: 0

  defp visible_start(total, sel, max_vis) when sel >= total - div(max_vis, 2) do
    total - max_vis
  end

  defp visible_start(_total, sel, max_vis), do: sel - div(max_vis, 2)

  @doc "Returns true if there are any filtered items to show."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{filtered: []}), do: false
  def active?(%__MODULE__{}), do: true

  @doc "Returns the count of currently filtered items."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{filtered: filtered}), do: length(filtered)

  # ── LSP Response Parsing ─────────────────────────────────────────────────────

  @doc """
  Parses an LSP completion response into a list of `item()` maps.

  Handles both `CompletionList` (`%{"items" => [...]}`) and bare
  `CompletionItem[]` response formats.
  """
  @spec parse_response(map() | [map()] | nil) :: [item()]
  def parse_response(response), do: parse_response(response, :local)

  @doc "Parses a completion response and qualifies every item with its provider identity."
  @spec parse_response(map() | [map()] | nil, Item.provider_id()) :: [item()]
  def parse_response(nil, _provider_id), do: []

  def parse_response(items, provider_id) when is_list(items),
    do: Enum.map(items, &parse_item(&1, provider_id))

  def parse_response(%{"items" => items}, provider_id) when is_list(items) do
    Enum.map(items, &parse_item(&1, provider_id))
  end

  def parse_response(_response, _provider_id), do: []

  @doc "Parses a single LSP CompletionItem map into an `item()` struct."
  @spec parse_item(map()) :: item()
  def parse_item(raw) when is_map(raw), do: parse_item(raw, :local)

  @doc "Parses one completion item with its provider identity."
  @spec parse_item(map(), Item.provider_id()) :: item()
  def parse_item(raw, provider_id) when is_map(raw), do: Item.from_lsp(provider_id, raw)

  @doc "Returns true when the selected item's raw identity equals the expected raw item."
  @spec selected_raw?(t(), map()) :: boolean()
  def selected_raw?(%__MODULE__{} = completion, raw_item) when is_map(raw_item) do
    case selected_item(completion) do
      %{raw: ^raw_item} -> true
      _ -> false
    end
  end

  @doc """
  Updates documentation only when the currently selected item matches the expected raw identity.

  Called when a `completionItem/resolve` response arrives with the full documentation text.
  """
  @spec update_selected_documentation(t(), map(), String.t()) :: t()
  def update_selected_documentation(%__MODULE__{} = completion, raw_item, doc_text)
      when is_map(raw_item) do
    if selected_raw?(completion, raw_item) do
      completion
      |> update_documentation_for_raw(raw_item, doc_text)
      |> Map.put(:last_resolved_identity, raw_item)
    else
      completion
    end
  end

  @doc "Updates documentation for one stable item identity."
  @spec update_item_documentation(t(), Item.id(), String.t()) :: t()
  def update_item_documentation(%__MODULE__{} = completion, item_id, doc_text) do
    %{
      completion
      | items: update_documentation_items_by_id(completion.items, item_id, doc_text),
        filtered: update_documentation_items_by_id(completion.filtered, item_id, doc_text)
    }
  end

  @spec update_documentation_for_raw(t(), map(), String.t()) :: t()
  defp update_documentation_for_raw(%__MODULE__{} = completion, raw_item, doc_text) do
    %{
      completion
      | items: update_documentation_items(completion.items, raw_item, doc_text),
        filtered: update_documentation_items(completion.filtered, raw_item, doc_text)
    }
  end

  @spec update_documentation_items([item()], map(), String.t()) :: [item()]
  defp update_documentation_items(items, raw_item, doc_text) do
    Enum.map(items, fn
      %{raw: ^raw_item} = item -> %{item | documentation: doc_text}
      item -> item
    end)
  end

  @spec update_documentation_items_by_id([item()], Item.id(), String.t()) :: [item()]
  defp update_documentation_items_by_id(items, item_id, doc_text) do
    Enum.map(items, fn
      %Item{id: ^item_id} = item -> Item.resolve(item, doc_text)
      item -> item
    end)
  end

  @spec first_item_id([item()]) :: Item.id() | nil
  defp first_item_id([%Item{id: id} | _]), do: id
  defp first_item_id([]), do: nil

  @spec item_id_at([item()], non_neg_integer()) :: Item.id() | nil
  defp item_id_at(items, index) do
    case Enum.at(items, index) do
      %Item{id: id} -> id
      nil -> nil
    end
  end

  @spec normalize_item(item() | map()) :: item()
  defp normalize_item(%Item{} = item), do: item
  defp normalize_item(item) when is_map(item), do: Item.from_fields(:local, item)

  @doc "Returns a single-character kind indicator for rendering."
  @spec kind_label(item_kind()) :: String.t()
  def kind_label(:text), do: "t"
  def kind_label(:method), do: "m"
  def kind_label(:function), do: "f"
  def kind_label(:constructor), do: "c"
  def kind_label(:field), do: "d"
  def kind_label(:variable), do: "v"
  def kind_label(:class), do: "C"
  def kind_label(:interface), do: "I"
  def kind_label(:module), do: "M"
  def kind_label(:property), do: "p"
  def kind_label(:unit), do: "U"
  def kind_label(:value), do: "V"
  def kind_label(:enum), do: "E"
  def kind_label(:keyword), do: "k"
  def kind_label(:snippet), do: "s"
  def kind_label(:color), do: "l"
  def kind_label(:file), do: "F"
  def kind_label(:reference), do: "r"
  def kind_label(:folder), do: "D"
  def kind_label(:enum_member), do: "e"
  def kind_label(:constant), do: "n"
  def kind_label(:struct), do: "S"
  def kind_label(:event), do: "E"
  def kind_label(:operator), do: "o"
  def kind_label(:type_parameter), do: "T"
end
