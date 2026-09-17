defmodule Minga.Editing.Completion.Item do
  @moduledoc """
  One completion candidate with stable provider and semantic edit identity.

  The identifier is the full identity tuple, not a display label or truncated hash. Documentation is intentionally excluded because `completionItem/resolve` may add it without changing the candidate's identity. Detail remains part of the identity because providers commonly use it to distinguish overloads.
  """

  @typedoc "Identity of the provider within one completion session."
  @type provider_id :: term()

  @typedoc "Stable identity of one provider-owned completion candidate."
  @type id ::
          {provider_id(),
           {String.t(), String.t(), map() | nil, term(), term(), term(), String.t()}}

  @typedoc "A half-open match range expressed in Unicode codepoint offsets."
  @type match_range :: {start :: non_neg_integer(), length :: pos_integer()}

  @max_match_ranges 255

  defmodule Search do
    @moduledoc "Normalized ranking fields and their optional mapping back to the displayed label."

    @enforce_keys [:label, :filter_text, :sort_text, :filter_to_label]
    defstruct [:label, :filter_text, :sort_text, :filter_to_label]

    @type t :: %__MODULE__{
            label: String.t(),
            filter_text: String.t(),
            sort_text: String.t(),
            filter_to_label: [non_neg_integer()] | nil
          }
  end

  @typedoc "LSP CompletionItemKind as an atom."
  @type kind ::
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

  @enforce_keys [
    :id,
    :provider_id,
    :source,
    :label,
    :insert_text,
    :filter_text,
    :sort_text,
    :search
  ]
  defstruct id: nil,
            provider_id: nil,
            source: "",
            label: "",
            kind: :text,
            insert_text: "",
            filter_text: "",
            detail: "",
            documentation: "",
            sort_text: "",
            search: nil,
            preselect: false,
            match_ranges: [],
            text_edit: nil,
            raw: nil

  @type t :: %__MODULE__{
          id: id(),
          provider_id: provider_id(),
          source: String.t(),
          label: String.t(),
          kind: kind(),
          insert_text: String.t(),
          filter_text: String.t(),
          detail: String.t(),
          documentation: String.t(),
          sort_text: String.t(),
          search: Search.t(),
          preselect: boolean(),
          match_ranges: [match_range()],
          text_edit: text_edit() | nil,
          raw: map() | nil
        }

  @doc "Parses one LSP CompletionItem and assigns its provider-qualified stable identity."
  @spec from_lsp(provider_id(), map()) :: t()
  def from_lsp(provider_id, raw) when is_map(raw) do
    label = Map.get(raw, "label", "")
    insert_text = raw |> Map.get("insertText", label) |> strip_snippet_markers()
    text_edit = parse_text_edit(Map.get(raw, "textEdit"))
    filter_text = Map.get(raw, "filterText", label)
    sort_text = Map.get(raw, "sortText", label)
    detail = Map.get(raw, "detail", "") || ""

    %__MODULE__{
      id: identity(provider_id, raw, label, insert_text, text_edit, detail),
      provider_id: provider_id,
      source: source_label(provider_id),
      label: label,
      kind: parse_kind(Map.get(raw, "kind", 1)),
      insert_text: insert_text,
      filter_text: filter_text,
      detail: detail,
      documentation: extract_documentation(Map.get(raw, "documentation")),
      sort_text: sort_text,
      search: build_search(label, filter_text, sort_text),
      preselect: Map.get(raw, "preselect", false) == true,
      text_edit: text_edit,
      raw: raw
    }
  end

  @doc "Builds a non-LSP completion item from the same stable field contract."
  @spec from_fields(provider_id(), map()) :: t()
  def from_fields(provider_id, fields) when is_map(fields) do
    label = Map.fetch!(fields, :label)
    insert_text = Map.get(fields, :insert_text, label)
    text_edit = Map.get(fields, :text_edit)
    raw = Map.get(fields, :raw)
    filter_text = Map.get(fields, :filter_text, label)
    sort_text = Map.get(fields, :sort_text, label)
    detail = Map.get(fields, :detail, "") || ""
    kind = Map.get(fields, :kind, :text)

    %__MODULE__{
      id: {provider_id, {label, insert_text, text_edit, nil, kind, nil, detail}},
      provider_id: provider_id,
      source: Map.get(fields, :source, source_label(provider_id)),
      label: label,
      kind: kind,
      insert_text: insert_text,
      filter_text: filter_text,
      detail: detail,
      documentation: Map.get(fields, :documentation, ""),
      sort_text: sort_text,
      search: build_search(label, filter_text, sort_text),
      preselect: Map.get(fields, :preselect, false) == true,
      text_edit: text_edit,
      raw: raw
    }
  end

  @doc "Returns this candidate with resolved documentation while preserving its identity."
  @spec resolve(t(), String.t()) :: t()
  def resolve(%__MODULE__{} = item, documentation) when is_binary(documentation),
    do: %{item | documentation: documentation}

  @doc "Returns this candidate with at most 255 display-label match ranges for the wire snapshot."
  @spec with_match_ranges(t(), [match_range()]) :: t()
  def with_match_ranges(%__MODULE__{} = item, ranges) when is_list(ranges),
    do: %{item | match_ranges: Enum.take(ranges, @max_match_ranges)}

  @doc "Maps normalized filter-text ranges onto the displayed label, omitting non-mappable ranges."
  @spec with_normalized_match_ranges(t(), [match_range()]) :: t()
  def with_normalized_match_ranges(%__MODULE__{search: search} = item, ranges)
      when is_list(ranges) do
    with_match_ranges(item, map_ranges_to_label(search.filter_to_label, ranges))
  end

  @doc "Returns the provider-aware semantic key used to collapse true duplicates."
  @spec semantic_key(t()) :: id()
  def semantic_key(%__MODULE__{id: id}), do: id

  @doc "Returns a compact stable identifier suitable for native protocol payloads."
  @spec wire_id(t() | id()) :: String.t()
  def wire_id(%__MODULE__{id: id}), do: wire_id(id)

  def wire_id(id) do
    id
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  @spec identity(provider_id(), map(), String.t(), String.t(), text_edit() | nil, String.t()) ::
          id()
  defp identity(provider_id, raw, label, insert_text, text_edit, detail) do
    {provider_id,
     {label, insert_text, text_edit, Map.get(raw, "data"), Map.get(raw, "kind"),
      Map.get(raw, "insertTextFormat"), detail}}
  end

  @spec normalize(String.t()) :: String.t()
  defp normalize(text), do: String.downcase(text)

  @spec build_search(String.t(), String.t(), String.t()) :: Search.t()
  defp build_search(label, filter_text, sort_text) do
    normalized_label = normalize(label)
    normalized_filter_text = normalize(filter_text)

    %Search{
      label: normalized_label,
      filter_text: normalized_filter_text,
      sort_text: normalize(sort_text),
      filter_to_label:
        filter_to_label_mapping(label, filter_text, normalized_label, normalized_filter_text)
    }
  end

  @spec filter_to_label_mapping(String.t(), String.t(), String.t(), String.t()) ::
          [non_neg_integer()] | nil
  defp filter_to_label_mapping(label, label, normalized, normalized) do
    {parts, offsets, _next_offset} =
      label
      |> String.to_charlist()
      |> Enum.reduce({[], [], 0}, fn codepoint, {parts, offsets, label_offset} ->
        normalized_part = normalize(List.to_string([codepoint]))
        normalized_codepoints = String.to_charlist(normalized_part)

        mapped_offsets =
          Enum.reduce(normalized_codepoints, offsets, fn _codepoint, acc ->
            [label_offset | acc]
          end)

        {[normalized_part | parts], mapped_offsets, label_offset + 1}
      end)

    if parts |> Enum.reverse() |> IO.iodata_to_binary() == normalized do
      Enum.reverse(offsets)
    else
      nil
    end
  end

  defp filter_to_label_mapping(_label, _filter_text, _normalized_label, _normalized_filter_text),
    do: nil

  @spec map_ranges_to_label([non_neg_integer()] | nil, [match_range()]) :: [match_range()]
  defp map_ranges_to_label(nil, _ranges), do: []

  defp map_ranges_to_label(offset_mapping, ranges) do
    positions =
      ranges
      |> Enum.flat_map(fn {start, length} -> Enum.slice(offset_mapping, start, length) end)
      |> Enum.uniq()
      |> Enum.sort()

    compact_match_positions(positions)
  end

  @doc "Compacts sorted match positions into half-open ranges."
  @spec compact_match_positions([non_neg_integer()]) :: [match_range()]
  def compact_match_positions([]), do: []

  def compact_match_positions([first | rest]) do
    rest
    |> Enum.reduce([{first, 1}], fn position, [{start, length} | ranges] ->
      if position == start + length,
        do: [{start, length + 1} | ranges],
        else: [{position, 1}, {start, length} | ranges]
    end)
    |> Enum.reverse()
  end

  @spec source_label(provider_id()) :: String.t()
  defp source_label({:lsp_client, pid}) when is_pid(pid), do: "lsp:#{inspect(pid)}"
  defp source_label(provider_id) when is_atom(provider_id), do: Atom.to_string(provider_id)
  defp source_label(provider_id), do: inspect(provider_id)

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
    |> String.replace(~r/\$\{\d+:([^}]*)\}/, "\\1")
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

  defp parse_text_edit(%{"insert" => insert_range, "newText" => new_text}),
    do: parse_text_edit(%{"range" => insert_range, "newText" => new_text})

  defp parse_text_edit(_), do: nil

  @spec parse_kind(integer()) :: kind()
  defp parse_kind(kind) do
    Map.get(
      %{
        1 => :text,
        2 => :method,
        3 => :function,
        4 => :constructor,
        5 => :field,
        6 => :variable,
        7 => :class,
        8 => :interface,
        9 => :module,
        10 => :property,
        11 => :unit,
        12 => :value,
        13 => :enum,
        14 => :keyword,
        15 => :snippet,
        16 => :color,
        17 => :file,
        18 => :reference,
        19 => :folder,
        20 => :enum_member,
        21 => :constant,
        22 => :struct,
        23 => :event,
        24 => :operator,
        25 => :type_parameter
      },
      kind,
      :text
    )
  end
end
