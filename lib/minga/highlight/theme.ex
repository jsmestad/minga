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

  # ── Doom One palette ────────────────────────────────────────────────────
  # Sourced from doomemacs/themes doom-one-theme.el.
  # Capture → color MAPPINGS follow the Helix / Neovim / Zed consensus
  # for tree-sitter-native themes (keywords = purple, functions = blue).
  @blue 0x51AFEF
  @red 0xFF6C6B
  @magenta 0xC678DD
  @green 0x98BE65
  @orange 0xDA8548
  @yellow 0xECBE7B
  @cyan 0x46D9FF
  @teal 0x4DB5BD
  @violet 0xA9A1E1
  @fg 0xBBC2CF
  @grey 0x5B6268
  @light_grey 0x818990

  @doc "Returns the Doom One color theme."
  @spec doom_one() :: t()
  def doom_one do
    %{
      # ── Keywords ──────────────────────────────────────────────────────────
      # Helix/Neovim/Zed: keywords = purple/magenta
      "keyword" => [fg: @magenta, bold: true],
      "keyword.function" => [fg: @magenta, bold: true],
      "keyword.operator" => [fg: @magenta],
      "keyword.return" => [fg: @magenta, bold: true],
      "keyword.conditional" => [fg: @magenta, bold: true],
      "keyword.coroutine" => [fg: @magenta, bold: true],
      "keyword.directive" => [fg: @magenta],
      "keyword.exception" => [fg: @magenta],
      "keyword.import" => [fg: @magenta],
      "keyword.modifier" => [fg: @magenta, bold: true],
      "keyword.repeat" => [fg: @magenta, bold: true],
      "keyword.type" => [fg: @magenta, bold: true],

      # Legacy keyword captures (older query formats)
      "conditional" => [fg: @magenta, bold: true],
      "exception" => [fg: @magenta],
      "include" => [fg: @magenta],
      "import" => [fg: @magenta],
      "repeat" => [fg: @magenta, bold: true],

      # ── Strings ───────────────────────────────────────────────────────────
      "string" => [fg: @green],
      "string.special" => [fg: @orange],
      "string.special.symbol" => [fg: @violet],
      "string.special.key" => [fg: @blue],
      "string.special.regex" => [fg: @orange],
      "string.escape" => [fg: @orange],
      "string.regex" => [fg: @orange],
      "character" => [fg: @orange],

      # ── Comments ──────────────────────────────────────────────────────────
      # doc-comments = doom-lighten(base5, 0.25) per doom-one-theme.el
      "comment" => [fg: @grey, italic: true],
      "comment.doc" => [fg: @light_grey, italic: true],
      "comment.documentation" => [fg: @light_grey, italic: true],
      "comment.unused" => [fg: @grey, italic: true],
      "comment.discard" => [fg: @grey, italic: true],

      # ── Functions ─────────────────────────────────────────────────────────
      # Helix/Neovim/Zed: functions = blue, macros = purple
      "function" => [fg: @blue],
      "function.call" => [fg: @blue],
      "function.builtin" => [fg: @teal],
      "function.macro" => [fg: @magenta, bold: true],
      "function.method" => [fg: @blue],
      "function.method.builtin" => [fg: @teal],
      "function.special" => [fg: @magenta],

      # Legacy method captures
      "method" => [fg: @blue],
      "method.call" => [fg: @blue],

      # ── Types ─────────────────────────────────────────────────────────────
      "type" => [fg: @yellow],
      "type.builtin" => [fg: @yellow, bold: true],

      # ── Variables ─────────────────────────────────────────────────────────
      # Helix/Neovim: parameter = red, member = cyan
      "variable" => [fg: @fg],
      "variable.builtin" => [fg: @orange],
      "variable.parameter" => [fg: @red],
      "variable.member" => [fg: @teal],
      "parameter" => [fg: @red],
      "field" => [fg: @teal],

      # ── Constants & numbers ───────────────────────────────────────────────
      # Neovim: constants = orange, constructor = yellow bold
      "constant" => [fg: @orange],
      "constant.builtin" => [fg: @orange, bold: true],
      "boolean" => [fg: @orange, bold: true],
      "number" => [fg: @orange],
      "number.float" => [fg: @orange],
      "float" => [fg: @orange],

      # ── Operators & punctuation ───────────────────────────────────────────
      "operator" => [fg: @blue],
      "punctuation" => [fg: @grey],
      "punctuation.bracket" => [fg: @fg],
      "punctuation.delimiter" => [fg: @fg],
      "punctuation.special" => [fg: @red],
      "delimiter" => [fg: @fg],

      # ── Modules & namespaces ──────────────────────────────────────────────
      "module" => [fg: @yellow],
      "namespace" => [fg: @yellow],

      # ── Attributes & properties ───────────────────────────────────────────
      # Helix/Neovim: attribute = cyan, property = cyan
      "attribute" => [fg: @teal],
      "property" => [fg: @teal],
      "label" => [fg: @red],

      # ── Tags (HTML/XML) ──────────────────────────────────────────────────
      "tag" => [fg: @magenta],
      "tag.attribute" => [fg: @yellow],
      "tag.error" => [fg: @red, bold: true],

      # ── Preprocessor ──────────────────────────────────────────────────────
      "preproc" => [fg: @magenta, bold: true],

      # ── Text / markup ─────────────────────────────────────────────────────
      # Neovim: heading = red bold, Helix: heading = red
      "text.title" => [fg: @red, bold: true],
      "text.strong" => [fg: @orange, bold: true],
      "text.emphasis" => [fg: @magenta, italic: true],
      "text.literal" => [fg: @green],
      "text.uri" => [fg: @cyan, underline: true],
      "text.reference" => [fg: @blue],

      # ── CSS-specific ──────────────────────────────────────────────────────
      "charset" => [fg: @magenta, bold: true],
      "keyframes" => [fg: @magenta, bold: true],
      "media" => [fg: @magenta, bold: true],
      "supports" => [fg: @magenta, bold: true],

      # ── Misc ──────────────────────────────────────────────────────────────
      "escape" => [fg: @orange],
      "embedded" => [fg: @fg],
      "constructor" => [fg: @yellow, bold: true],
      "error" => [fg: @red, bold: true],
      "warning" => [fg: @yellow, bold: true]
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
  defp fallback_lookup(theme, name) when is_binary(name) do
    case String.split(name, ".") do
      [_single] ->
        []

      parts ->
        parent = parts |> Enum.slice(0..-2//1) |> Enum.join(".")
        style_for_capture(theme, parent)
    end
  end
end
