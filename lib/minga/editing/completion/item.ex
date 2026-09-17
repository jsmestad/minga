defmodule Minga.Editing.Completion.Item do
  @moduledoc """
  One completion candidate with stable provider and semantic edit identity.

  The identifier is the full identity tuple, not a display label or truncated hash. Documentation and detail are intentionally excluded because `completionItem/resolve` may add them without changing the candidate's identity.
  """

  @typedoc "Identity of the provider within one completion session."
  @type provider_id :: term()

  @typedoc "Stable identity of one provider-owned completion candidate."
  @type id ::
          {provider_id(), {String.t(), String.t(), map() | nil, term(), term(), term()}}

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

  @enforce_keys [:id, :provider_id, :label, :insert_text, :filter_text, :sort_text]
  defstruct id: nil,
            provider_id: nil,
            label: "",
            kind: :text,
            insert_text: "",
            filter_text: "",
            detail: "",
            documentation: "",
            sort_text: "",
            text_edit: nil,
            raw: nil

  @type t :: %__MODULE__{
          id: id(),
          provider_id: provider_id(),
          label: String.t(),
          kind: kind(),
          insert_text: String.t(),
          filter_text: String.t(),
          detail: String.t(),
          documentation: String.t(),
          sort_text: String.t(),
          text_edit: text_edit() | nil,
          raw: map() | nil
        }

  @doc "Parses one LSP CompletionItem and assigns its provider-qualified stable identity."
  @spec from_lsp(provider_id(), map()) :: t()
  def from_lsp(provider_id, raw) when is_map(raw) do
    label = Map.get(raw, "label", "")
    insert_text = raw |> Map.get("insertText", label) |> strip_snippet_markers()
    text_edit = parse_text_edit(Map.get(raw, "textEdit"))

    %__MODULE__{
      id: identity(provider_id, raw, label, insert_text, text_edit),
      provider_id: provider_id,
      label: label,
      kind: parse_kind(Map.get(raw, "kind", 1)),
      insert_text: insert_text,
      filter_text: Map.get(raw, "filterText", label),
      detail: Map.get(raw, "detail", ""),
      documentation: extract_documentation(Map.get(raw, "documentation")),
      sort_text: Map.get(raw, "sortText", label),
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

    %__MODULE__{
      id: {provider_id, {label, insert_text, text_edit, nil, Map.get(fields, :kind), nil}},
      provider_id: provider_id,
      label: label,
      kind: Map.get(fields, :kind, :text),
      insert_text: insert_text,
      filter_text: Map.get(fields, :filter_text, label),
      detail: Map.get(fields, :detail, ""),
      documentation: Map.get(fields, :documentation, ""),
      sort_text: Map.get(fields, :sort_text, label),
      text_edit: text_edit,
      raw: raw
    }
  end

  @doc "Returns this candidate with resolved documentation while preserving its identity."
  @spec resolve(t(), String.t()) :: t()
  def resolve(%__MODULE__{} = item, documentation) when is_binary(documentation),
    do: %{item | documentation: documentation}

  @spec identity(provider_id(), map(), String.t(), String.t(), text_edit() | nil) :: id()
  defp identity(provider_id, raw, label, insert_text, text_edit) do
    {provider_id,
     {label, insert_text, text_edit, Map.get(raw, "data"), Map.get(raw, "kind"),
      Map.get(raw, "insertTextFormat")}}
  end

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
