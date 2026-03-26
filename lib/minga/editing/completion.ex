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

  @enforce_keys [:items, :trigger_position]
  defstruct items: [],
            filtered: [],
            selected: 0,
            filter_text: "",
            trigger_position: {0, 0},
            max_visible: 10,
            resolve_timer: nil,
            last_resolved_index: -1

  @typedoc "LSP CompletionItemKind as an atom."
  @type item_kind ::
          :text
          | :method
          | :function
          | :constructor
          | :field
          | :variable
          | :class
          | :interface
          | :module
          | :property
          | :unit
          | :value
          | :enum
          | :keyword
          | :snippet
          | :color
          | :file
          | :reference
          | :folder
          | :enum_member
          | :constant
          | :struct
          | :event
          | :operator
          | :type_parameter

  @typedoc "A text edit to apply when accepting a completion."
  @type text_edit :: %{
          range: %{
            start_line: non_neg_integer(),
            start_col: non_neg_integer(),
            end_line: non_neg_integer(),
            end_col: non_neg_integer()
          },
          new_text: String.t()
        }

  @typedoc "A parsed completion item."
  @type item :: %{
          label: String.t(),
          kind: item_kind(),
          insert_text: String.t(),
          filter_text: String.t(),
          detail: String.t(),
          documentation: String.t(),
          sort_text: String.t(),
          text_edit: text_edit() | nil,
          raw: map() | nil
        }

  @type t :: %__MODULE__{
          items: [item()],
          filtered: [item()],
          selected: non_neg_integer(),
          filter_text: String.t(),
          trigger_position: {non_neg_integer(), non_neg_integer()},
          max_visible: pos_integer(),
          resolve_timer: reference() | nil,
          last_resolved_index: integer()
        }

  # ── Constructor ──────────────────────────────────────────────────────────────

  @doc """
  Creates a new completion state from a list of parsed items and the
  cursor position where completion was triggered.
  """
  @spec new([item()], {non_neg_integer(), non_neg_integer()}) :: t()
  def new(items, trigger_position) when is_list(items) do
    sorted = Enum.sort_by(items, & &1.sort_text)

    %__MODULE__{
      items: sorted,
      filtered: sorted,
      trigger_position: trigger_position,
      selected: 0
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

    %{completion | filtered: filtered, filter_text: prefix, selected: 0}
  end

  # ── Navigation ───────────────────────────────────────────────────────────────

  @doc "Moves the selection down one item, wrapping at the bottom."
  @spec move_down(t()) :: t()
  def move_down(%__MODULE__{filtered: []} = c), do: c

  def move_down(%__MODULE__{filtered: filtered, selected: sel} = c) do
    %{c | selected: rem(sel + 1, length(filtered))}
  end

  @doc "Moves the selection up one item, wrapping at the top."
  @spec move_up(t()) :: t()
  def move_up(%__MODULE__{filtered: []} = c), do: c

  def move_up(%__MODULE__{filtered: filtered, selected: sel} = c) do
    new_sel = if sel == 0, do: length(filtered) - 1, else: sel - 1
    %{c | selected: new_sel}
  end

  # ── Selection ────────────────────────────────────────────────────────────────

  @doc "Returns the currently selected item, or nil if no items."
  @spec selected_item(t()) :: item() | nil
  def selected_item(%__MODULE__{filtered: []}), do: nil

  def selected_item(%__MODULE__{filtered: filtered, selected: sel}) do
    Enum.at(filtered, sel)
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

  def visible_items(%__MODULE__{filtered: filtered, selected: sel, max_visible: max_vis}) do
    total = length(filtered)

    {start, count} =
      cond do
        total <= max_vis ->
          {0, total}

        sel < div(max_vis, 2) ->
          {0, max_vis}

        sel >= total - div(max_vis, 2) ->
          {total - max_vis, max_vis}

        true ->
          {sel - div(max_vis, 2), max_vis}
      end

    visible = Enum.slice(filtered, start, count)
    {visible, sel - start}
  end

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
  def parse_response(nil), do: []
  def parse_response(items) when is_list(items), do: Enum.map(items, &parse_item/1)

  def parse_response(%{"items" => items}) when is_list(items) do
    Enum.map(items, &parse_item/1)
  end

  def parse_response(_), do: []

  @doc "Parses a single LSP CompletionItem map into an `item()` struct."
  @spec parse_item(map()) :: item()
  def parse_item(raw) when is_map(raw) do
    label = Map.get(raw, "label", "")
    insert_text = Map.get(raw, "insertText", label)

    # Strip snippet markers ($1, ${2:placeholder}, $0) for plain text insertion
    insert_text = strip_snippet_markers(insert_text)

    %{
      label: label,
      kind: parse_kind(Map.get(raw, "kind", 1)),
      insert_text: insert_text,
      filter_text: Map.get(raw, "filterText", label),
      detail: Map.get(raw, "detail", ""),
      documentation: extract_documentation(Map.get(raw, "documentation")),
      sort_text: Map.get(raw, "sortText", label),
      text_edit: parse_text_edit(Map.get(raw, "textEdit")),
      raw: raw
    }
  end

  @doc """
  Updates the documentation for the currently selected item.

  Called when a `completionItem/resolve` response arrives with
  the full documentation text.
  """
  @spec update_selected_documentation(t(), String.t()) :: t()
  def update_selected_documentation(%__MODULE__{} = completion, doc_text) do
    item = selected_item(completion)

    if item do
      updated = %{item | documentation: doc_text}
      idx = absolute_selected_index(completion)

      filtered =
        List.update_at(completion.filtered, idx, fn _ -> updated end)

      %{completion | filtered: filtered}
    else
      completion
    end
  end

  @spec absolute_selected_index(t()) :: non_neg_integer()
  defp absolute_selected_index(%__MODULE__{selected: sel}), do: sel

  @spec extract_documentation(term()) :: String.t()
  defp extract_documentation(nil), do: ""
  defp extract_documentation(text) when is_binary(text), do: String.trim(text)

  defp extract_documentation(%{"kind" => _, "value" => value}) when is_binary(value),
    do: String.trim(value)

  defp extract_documentation(%{"value" => value}) when is_binary(value),
    do: String.trim(value)

  defp extract_documentation(_), do: ""

  @spec strip_snippet_markers(String.t()) :: String.t()
  defp strip_snippet_markers(text) do
    text
    # ${N:placeholder} → placeholder
    |> String.replace(~r/\$\{\d+:([^}]*)\}/, "\\1")
    # $N → empty
    |> String.replace(~r/\$\d+/, "")
  end

  @spec parse_text_edit(map() | nil) :: text_edit() | nil
  defp parse_text_edit(nil), do: nil

  defp parse_text_edit(%{"range" => range, "newText" => new_text}) do
    %{
      range: %{
        start_line: get_in(range, ["start", "line"]) || 0,
        start_col: get_in(range, ["start", "character"]) || 0,
        end_line: get_in(range, ["end", "line"]) || 0,
        end_col: get_in(range, ["end", "character"]) || 0
      },
      new_text: strip_snippet_markers(new_text)
    }
  end

  # InsertReplaceEdit has "insert" and "replace" ranges; use the insert range
  defp parse_text_edit(%{"insert" => insert_range, "newText" => new_text}) do
    parse_text_edit(%{"range" => insert_range, "newText" => new_text})
  end

  defp parse_text_edit(_), do: nil

  @spec parse_kind(integer()) :: item_kind()
  defp parse_kind(1), do: :text
  defp parse_kind(2), do: :method
  defp parse_kind(3), do: :function
  defp parse_kind(4), do: :constructor
  defp parse_kind(5), do: :field
  defp parse_kind(6), do: :variable
  defp parse_kind(7), do: :class
  defp parse_kind(8), do: :interface
  defp parse_kind(9), do: :module
  defp parse_kind(10), do: :property
  defp parse_kind(11), do: :unit
  defp parse_kind(12), do: :value
  defp parse_kind(13), do: :enum
  defp parse_kind(14), do: :keyword
  defp parse_kind(15), do: :snippet
  defp parse_kind(16), do: :color
  defp parse_kind(17), do: :file
  defp parse_kind(18), do: :reference
  defp parse_kind(19), do: :folder
  defp parse_kind(20), do: :enum_member
  defp parse_kind(21), do: :constant
  defp parse_kind(22), do: :struct
  defp parse_kind(23), do: :event
  defp parse_kind(24), do: :operator
  defp parse_kind(25), do: :type_parameter
  defp parse_kind(_), do: :text

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
