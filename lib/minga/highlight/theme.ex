defmodule Minga.Highlight.Theme do
  @moduledoc """
  Syntax highlighting theme — maps tree-sitter capture names to styles.

  A theme is a map of `%{capture_name => style}` where style is a keyword
  list compatible with `Minga.Port.Protocol.style()`.

  Capture name resolution uses suffix fallback: `"keyword.function"` tries
  exact match first, then `"keyword"`, then falls back to `[]`.
  """

  @typedoc "A theme: capture name → style mapping."
  @type t :: %{String.t() => Minga.Port.Protocol.style()}

  @doc "Returns the Doom One color theme."
  @spec doom_one() :: t()
  def doom_one do
    %{
      # Keywords
      "keyword" => [fg: 0x51AFEF, bold: true],
      "keyword.function" => [fg: 0xC678DD, bold: true],
      "keyword.operator" => [fg: 0x51AFEF],
      "keyword.return" => [fg: 0xC678DD, bold: true],

      # Strings
      "string" => [fg: 0x98BE65],
      "string.special" => [fg: 0xDA8548],
      "string.special.symbol" => [fg: 0xA9A1E1],
      "string.escape" => [fg: 0xDA8548],
      "string.regex" => [fg: 0xDA8548],

      # Comments
      "comment" => [fg: 0x5B6268, italic: true],

      # Functions
      "function" => [fg: 0xC678DD],
      "function.call" => [fg: 0x51AFEF],
      "function.builtin" => [fg: 0xC678DD],
      "function.macro" => [fg: 0xC678DD, bold: true],

      # Types
      "type" => [fg: 0xECBE7B],
      "type.builtin" => [fg: 0xECBE7B, bold: true],

      # Variables
      "variable" => [fg: 0xBBC2CF],
      "variable.builtin" => [fg: 0xDA8548],
      "variable.parameter" => [fg: 0xDCBFFF],

      # Constants
      "constant" => [fg: 0xDA8548],
      "constant.builtin" => [fg: 0xDA8548, bold: true],
      "boolean" => [fg: 0xDA8548, bold: true],
      "number" => [fg: 0xDA8548],
      "float" => [fg: 0xDA8548],

      # Operators & punctuation
      "operator" => [fg: 0x51AFEF],
      "punctuation" => [fg: 0x5B6268],
      "punctuation.bracket" => [fg: 0xBBC2CF],
      "punctuation.delimiter" => [fg: 0x5B6268],
      "punctuation.special" => [fg: 0x51AFEF],

      # Modules & namespaces
      "module" => [fg: 0xECBE7B],
      "namespace" => [fg: 0xECBE7B],

      # Attributes & properties
      "attribute" => [fg: 0xDA8548],
      "property" => [fg: 0xBBC2CF],
      "label" => [fg: 0x51AFEF],

      # Tags (HTML/XML)
      "tag" => [fg: 0xC678DD],
      "tag.attribute" => [fg: 0xDA8548],

      # Misc
      "escape" => [fg: 0xDA8548],
      "embedded" => [fg: 0xBBC2CF],
      "constructor" => [fg: 0xECBE7B],
      "error" => [fg: 0xFF6C6B, bold: true]
    }
  end

  @doc """
  Returns the style for a capture name, using suffix fallback.

  Tries exact match first. If not found, strips the last `.segment` and
  retries. Returns `[]` if no match is found.

  ## Examples

      iex> theme = Minga.Highlight.Theme.doom_one()
      iex> Minga.Highlight.Theme.style_for_capture(theme, "keyword")
      [fg: 0x51AFEF, bold: true]

      iex> theme = Minga.Highlight.Theme.doom_one()
      iex> Minga.Highlight.Theme.style_for_capture(theme, "keyword.function")
      [fg: 0xC678DD, bold: true]

      iex> theme = Minga.Highlight.Theme.doom_one()
      iex> Minga.Highlight.Theme.style_for_capture(theme, "keyword.unknown.deep")
      [fg: 0x51AFEF, bold: true]

      iex> theme = Minga.Highlight.Theme.doom_one()
      iex> Minga.Highlight.Theme.style_for_capture(theme, "nonexistent")
      []
  """
  @spec style_for_capture(t(), String.t()) :: Minga.Port.Protocol.style()
  def style_for_capture(theme, name) when is_map(theme) and is_binary(name) do
    case Map.get(theme, name) do
      nil -> fallback_lookup(theme, name)
      style -> style
    end
  end

  @spec fallback_lookup(t(), String.t()) :: Minga.Port.Protocol.style()
  defp fallback_lookup(_theme, name) when not is_binary(name), do: []

  defp fallback_lookup(theme, name) do
    case String.split(name, ".") do
      [_single] ->
        []

      parts ->
        parent = parts |> Enum.slice(0..-2//1) |> Enum.join(".")
        style_for_capture(theme, parent)
    end
  end
end
