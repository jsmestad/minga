defmodule Minga.LSP.SemanticTokens do
  @moduledoc """
  Decodes LSP semantic tokens into highlight spans for the face system.

  LSP semantic tokens use a dense, delta-encoded format:
  each token is 5 integers `[deltaLine, deltaStart, length, tokenType, tokenModifiers]`.
  This module decodes them into absolute positions and maps them to
  tree-sitter-compatible capture names that the Face.Registry can resolve.

  ## Token type mapping

  LSP token types map to tree-sitter capture names with an `@lsp.type.` prefix,
  following the convention established by Neovim and Zed:

  - `namespace` → `@lsp.type.namespace`
  - `type` → `@lsp.type.type`
  - `variable` → `@lsp.type.variable`
  - `parameter` → `@lsp.type.parameter`
  - `property` → `@lsp.type.property`
  - `function` → `@lsp.type.function`
  - `method` → `@lsp.type.method`
  - `keyword` → `@lsp.type.keyword`
  - `comment` → `@lsp.type.comment`
  - `string` → `@lsp.type.string`
  - `number` → `@lsp.type.number`
  - `operator` → `@lsp.type.operator`

  ## Token modifier mapping

  Modifiers append to the capture name with an `@lsp.mod.` prefix:

  - `readonly` → `@lsp.mod.readonly`
  - `deprecated` → `@lsp.mod.deprecated`
  - `async` → `@lsp.mod.async`

  ## Integration with highlight sweep

  Decoded tokens become spans at layer 2 (above tree-sitter layer 0 and
  injection layer 1). The existing `(layer DESC, width ASC, pattern_index DESC)`
  priority ensures semantic tokens override tree-sitter when both cover the
  same range, which is the correct behavior (the LSP server has deeper
  semantic knowledge than the tree-sitter grammar).
  """

  alias Minga.LSP.PositionEncoding

  @semantic_layer 2

  alias Minga.LSP.SemanticToken

  @typedoc "A decoded semantic token with absolute position."
  @type token :: SemanticToken.t()

  @typedoc "A highlight span compatible with the existing highlight sweep."
  @type highlight_span :: Minga.Highlight.Span.t()

  @doc """
  Decodes a delta-encoded semantic token array from LSP.

  The `data` list contains groups of 5 integers:
  `[deltaLine, deltaStart, length, tokenType, tokenModifiers, ...]`

  The `token_types` and `token_modifiers` lists come from the server's
  `semanticTokensProvider.legend` in its capabilities response.

  Returns a list of decoded tokens with absolute positions.

  ## Examples

      iex> types = ["namespace", "type", "variable"]
      iex> mods = ["declaration", "readonly"]
      iex> data = [0, 5, 3, 2, 0, 1, 0, 4, 1, 2]
      iex> tokens = SemanticTokens.decode(data, types, mods)
      iex> length(tokens)
      2
      iex> hd(tokens).line
      0
      iex> hd(tokens).start_char
      5
      iex> hd(tokens).type
      "variable"
  """
  @spec decode([non_neg_integer()], [String.t()], [String.t()]) :: [token()]
  def decode(data, token_types, token_modifiers)
      when is_list(data) and is_list(token_types) and is_list(token_modifiers) do
    do_decode(data, token_types, token_modifiers, 0, 0, [])
  end

  defp do_decode(
         [delta_line, delta_start, length, type_idx, mod_bits | rest],
         types,
         mods,
         prev_line,
         prev_start,
         acc
       ) do
    line = prev_line + delta_line
    start_char = if delta_line > 0, do: delta_start, else: prev_start + delta_start

    type_name = Enum.at(types, type_idx, "unknown")
    modifier_names = decode_modifiers(mod_bits, mods)

    token = %SemanticToken{
      line: line,
      start_char: start_char,
      length: length,
      type: type_name,
      modifiers: modifier_names
    }

    do_decode(rest, types, mods, line, start_char, [token | acc])
  end

  defp do_decode(_, _types, _mods, _prev_line, _prev_start, acc) do
    Enum.reverse(acc)
  end

  @doc """
  Converts decoded semantic tokens to highlight spans.

  ## Parameters

  - `tokens` — decoded tokens from `decode/3`
  - `line_byte_offsets` — maps line numbers to their starting byte offset
    in the buffer (needed for absolute byte position calculation)
  - `capture_name_to_id` — maps capture names (e.g., `"@lsp.type.variable"`)
    to capture IDs in the Highlight struct's `capture_names` list
  - `line_text_fn` — returns the text of a given line number (needed for
    encoding conversion on non-ASCII lines)
  - `encoding` — the negotiated LSP position encoding (`:utf8`, `:utf16`,
    or `:utf32`). Defaults to `:utf16` per the LSP spec default.

  All spans are assigned layer #{@semantic_layer} so they take priority
  over tree-sitter spans in the highlight sweep.
  """
  @spec to_spans(
          [token()],
          %{non_neg_integer() => non_neg_integer()},
          (String.t() -> non_neg_integer()),
          (non_neg_integer() -> String.t()),
          PositionEncoding.encoding()
        ) :: [highlight_span()]
  def to_spans(tokens, line_byte_offsets, capture_name_to_id, line_text_fn, encoding \\ :utf16)
      when is_list(tokens) and is_map(line_byte_offsets) and is_function(capture_name_to_id, 1) and
             is_function(line_text_fn, 1) do
    Enum.flat_map(tokens, fn token ->
      line_offset = Map.get(line_byte_offsets, token.line, 0)
      line_text = line_text_fn.(token.line)

      {_, start_byte_col} =
        PositionEncoding.from_lsp(
          %{"line" => token.line, "character" => token.start_char},
          line_text,
          encoding
        )

      {_, end_byte_col} =
        PositionEncoding.from_lsp(
          %{"line" => token.line, "character" => token.start_char + token.length},
          line_text,
          encoding
        )

      start_byte = line_offset + start_byte_col
      end_byte = line_offset + end_byte_col

      # Build a composite capture name that encodes both the type and
      # its modifiers, e.g., "@lsp.type.variable+deprecated+readonly".
      # The Face.Registry resolves this via style_for_with_modifiers,
      # composing modifier attributes on top of the type's colors.
      capture_name = composite_capture_name(token.type, token.modifiers)
      capture_id = capture_name_to_id.(capture_name)

      [
        %Minga.Highlight.Span{
          start_byte: start_byte,
          end_byte: end_byte,
          capture_id: capture_id,
          pattern_index: 0,
          layer: @semantic_layer
        }
      ]
    end)
  end

  @doc """
  Builds a composite capture name from a token type and its modifiers.

  For tokens without modifiers, returns `"@lsp.type.{type}"`.
  For tokens with modifiers, returns `"@lsp.type.{type}+{mod1}+{mod2}"`.
  The modifiers are sorted for deterministic names.

  ## Examples

      iex> SemanticTokens.composite_capture_name("variable", [])
      "@lsp.type.variable"

      iex> SemanticTokens.composite_capture_name("function", ["deprecated"])
      "@lsp.type.function+deprecated"

      iex> SemanticTokens.composite_capture_name("variable", ["readonly", "deprecated"])
      "@lsp.type.variable+deprecated+readonly"
  """
  @spec composite_capture_name(String.t(), [String.t()]) :: String.t()
  def composite_capture_name(type, []), do: "@lsp.type.#{type}"

  def composite_capture_name(type, modifiers) do
    suffix = modifiers |> Enum.sort() |> Enum.join("+")
    "@lsp.type.#{type}+#{suffix}"
  end

  @doc """
  Returns the capture name for a semantic token type.

  ## Examples

      iex> SemanticTokens.capture_name("variable")
      "@lsp.type.variable"
  """
  @spec capture_name(String.t()) :: String.t()
  def capture_name(type) when is_binary(type), do: "@lsp.type.#{type}"

  @doc """
  Returns the capture name for a semantic token modifier.

  ## Examples

      iex> SemanticTokens.modifier_capture_name("readonly")
      "@lsp.mod.readonly"
  """
  @spec modifier_capture_name(String.t()) :: String.t()
  def modifier_capture_name(mod) when is_binary(mod), do: "@lsp.mod.#{mod}"

  @doc """
  Extracts the semantic token legend from LSP server capabilities.

  Returns `{token_types, token_modifiers}` or `:not_supported` if the
  server doesn't advertise semantic tokens.
  """
  @spec extract_legend(map()) :: {[String.t()], [String.t()]} | :not_supported
  def extract_legend(capabilities) when is_map(capabilities) do
    case get_in(capabilities, ["semanticTokensProvider", "legend"]) do
      %{"tokenTypes" => types, "tokenModifiers" => mods}
      when is_list(types) and is_list(mods) ->
        {types, mods}

      _ ->
        :not_supported
    end
  end

  @doc """
  Returns the standard LSP semantic token types.

  These are the types defined in the LSP spec. Servers may extend this
  list, and the legend from the server capabilities is authoritative.
  """
  @spec standard_token_types() :: [String.t()]
  def standard_token_types do
    [
      "namespace",
      "type",
      "class",
      "enum",
      "interface",
      "struct",
      "typeParameter",
      "parameter",
      "variable",
      "property",
      "enumMember",
      "event",
      "function",
      "method",
      "macro",
      "keyword",
      "modifier",
      "comment",
      "string",
      "number",
      "regexp",
      "operator",
      "decorator"
    ]
  end

  @doc """
  Returns the standard LSP semantic token modifiers.
  """
  @spec standard_token_modifiers() :: [String.t()]
  def standard_token_modifiers do
    [
      "declaration",
      "definition",
      "readonly",
      "static",
      "deprecated",
      "abstract",
      "async",
      "modification",
      "documentation",
      "defaultLibrary"
    ]
  end

  # Decode modifier bitmask into a list of modifier names.
  @spec decode_modifiers(non_neg_integer(), [String.t()]) :: [String.t()]
  defp decode_modifiers(0, _mods), do: []

  defp decode_modifiers(bits, mods) do
    import Bitwise

    mods
    |> Enum.with_index()
    |> Enum.filter(fn {_mod, idx} -> (bits >>> idx &&& 1) == 1 end)
    |> Enum.map(fn {mod, _idx} -> mod end)
  end
end
