defmodule MingaEditor.UI.PrettifySymbols do
  @moduledoc """
  Prettify-symbols: conceal operator text and display Unicode replacements.

  Scans highlight spans for operators/punctuation that match substitution
  rules and creates `ConcealRange` decorations with replacement characters.
  The existing conceal rendering in the line renderer handles display.

  This uses tree-sitter highlight captures as a proxy for node type: a
  span captured as "operator" containing "->" is known to be an actual
  operator (not text inside a string or comment). This avoids regex
  matching against raw buffer content.

  ## Substitution rules

  Rules are defined per filetype. Each rule maps a source string to a
  Unicode replacement character and specifies which capture names match.
  Rules are only applied when the span's capture name matches and the
  span's text content exactly equals the source string.

  ## Integration

  Called from `HighlightEvents.handle_spans/3` after highlights are stored.
  Clears previous prettify conceals (group `:prettify_symbols`) and applies
  new ones based on the current highlight spans.
  """

  alias Minga.Buffer
  alias Minga.Config
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias MingaEditor.UI.Highlight

  @typedoc "A substitution rule: source text, replacement character, and matching captures."
  @type rule :: %{
          source: String.t(),
          replacement: String.t(),
          captures: [String.t()]
        }

  @type position :: {non_neg_integer(), non_neg_integer()}
  @type conceal :: {position(), position(), String.t()}
  @type update :: :clear | {:replace, [conceal()]}

  @doc """
  Returns the substitution rules for a filetype.

  Rules are organized by source string length (longest first) for
  greedy matching when multiple rules could apply.
  """
  @spec rules_for(atom()) :: [rule()]
  def rules_for(filetype) do
    base = common_rules()
    extra = filetype_rules(filetype)
    (extra ++ base) |> Enum.sort_by(&(&1.source |> byte_size()), :desc)
  end

  # Common operator substitutions shared across most languages.
  @spec common_rules() :: [rule()]
  defp common_rules do
    operator = ["operator", "keyword.operator"]
    punctuation = ["punctuation.delimiter", "punctuation.special"]

    [
      %{source: "->", replacement: "→", captures: operator},
      %{source: "=>", replacement: "⇒", captures: operator ++ punctuation},
      %{source: "<-", replacement: "←", captures: operator},
      %{source: "!=", replacement: "≠", captures: operator},
      %{source: "!==", replacement: "≢", captures: operator},
      %{source: "===", replacement: "≡", captures: operator},
      %{source: ">=", replacement: "≥", captures: operator},
      %{source: "<=", replacement: "≤", captures: operator},
      %{source: "&&", replacement: "∧", captures: operator},
      %{source: "||", replacement: "∨", captures: operator},
      %{source: "|>", replacement: "▷", captures: operator}
    ]
  end

  # Per-filetype overrides and additions.
  @spec filetype_rules(atom()) :: [rule()]
  defp filetype_rules(:elixir) do
    [
      %{source: "fn", replacement: "λ", captures: ["keyword"]},
      %{source: "|>", replacement: "▷", captures: ["operator"]}
    ]
  end

  defp filetype_rules(:haskell) do
    [
      %{source: "\\", replacement: "λ", captures: ["punctuation.delimiter"]},
      %{source: "::", replacement: "∷", captures: ["operator"]},
      %{source: ".", replacement: "∘", captures: ["operator"]}
    ]
  end

  defp filetype_rules(:javascript), do: arrow_fn_rules()
  defp filetype_rules(:typescript), do: arrow_fn_rules()
  defp filetype_rules(:jsx), do: arrow_fn_rules()
  defp filetype_rules(:tsx), do: arrow_fn_rules()

  defp filetype_rules(:python) do
    [
      %{source: "lambda", replacement: "λ", captures: ["keyword"]},
      %{source: "not", replacement: "¬", captures: ["keyword.operator"]}
    ]
  end

  defp filetype_rules(:rust) do
    [
      %{source: "fn", replacement: "λ", captures: ["keyword.function"]}
    ]
  end

  defp filetype_rules(_), do: []

  @spec arrow_fn_rules() :: [rule()]
  defp arrow_fn_rules do
    [
      %{source: "=>", replacement: "⇒", captures: ["punctuation.delimiter", "operator"]}
    ]
  end

  @doc "Builds the decoration update for the current buffer content and highlights."
  @spec prepare(pid(), Highlight.t(), atom()) :: update()
  def prepare(buf, %Highlight{} = hl, filetype) when is_pid(buf) and is_atom(filetype) do
    build_update(buf, hl, rules_for(filetype))
  end

  @doc "Applies a prepared prettify-symbol update atomically."
  @spec apply_update(pid(), update()) :: :ok
  def apply_update(buf, :clear) when is_pid(buf), do: clear(buf)

  def apply_update(buf, {:replace, conceals}) when is_pid(buf) and is_list(conceals) do
    Buffer.batch_decorations(buf, fn decs ->
      decs
      |> Decorations.remove_conceal_group(:prettify_symbols)
      |> add_all_conceals(conceals)
    end)
  end

  @doc "Clears the `:prettify_symbols` conceal group from a buffer."
  @spec clear(pid()) :: :ok
  def clear(buf), do: Buffer.remove_conceal_group(buf, :prettify_symbols)

  @spec build_update(pid(), Highlight.t(), [rule()]) :: update()
  defp build_update(_buf, %Highlight{}, []), do: :clear

  defp build_update(buf, %Highlight{} = hl, rules) do
    content = Buffer.content(buf)
    lines = String.split(content, "\n")
    capture_names = Tuple.to_list(hl.capture_names)
    spans = Tuple.to_list(hl.spans)

    {:replace, find_conceals(spans, rules, capture_names, content, lines)}
  end

  @doc "Returns true if prettify-symbols is enabled in config."
  @spec enabled?() :: boolean()
  def enabled? do
    Config.get(:prettify_symbols)
  end

  @spec add_all_conceals(Decorations.t(), [{position(), position(), String.t()}]) ::
          Decorations.t()
  defp add_all_conceals(decs, conceals) do
    Enum.reduce(conceals, decs, fn {start_pos, end_pos, replacement}, acc ->
      {_id, new_decs} =
        Decorations.add_conceal(acc, start_pos, end_pos,
          replacement: replacement,
          replacement_style: %Face{name: "_", fg: 0x98BE65},
          group: :prettify_symbols,
          priority: 10
        )

      new_decs
    end)
  end

  # Scans highlight spans and finds matching conceals.
  @spec find_conceals(
          [map()],
          [rule()],
          [String.t()],
          String.t(),
          [String.t()]
        ) :: [{position(), position(), String.t()}]
  defp find_conceals(spans, rules, capture_names, content, lines) do
    rule_index = build_rule_index(rules)

    spans
    |> Enum.reduce([], fn span, acc ->
      capture_name = Enum.at(capture_names, span.capture_id, "")

      case Map.get(rule_index, capture_name) do
        nil ->
          acc

        matching_rules ->
          text = binary_part(content, span.start_byte, span.end_byte - span.start_byte)
          check_rules(matching_rules, text, span, lines, content, acc)
      end
    end)
  end

  # Build a map from capture_name to list of rules that match it.
  @spec build_rule_index([rule()]) :: %{String.t() => [rule()]}
  defp build_rule_index(rules) do
    Enum.reduce(rules, %{}, fn rule, acc ->
      Enum.reduce(rule.captures, acc, fn capture, inner_acc ->
        Map.update(inner_acc, capture, [rule], &[rule | &1])
      end)
    end)
  end

  @spec check_rules([rule()], String.t(), map(), [String.t()], String.t(), list()) :: list()
  defp check_rules(rules, text, span, lines, content, acc) do
    case Enum.find(rules, fn r -> r.source == text end) do
      nil ->
        acc

      rule ->
        {start_line, start_col} = byte_to_position(span.start_byte, lines, content)
        {end_line, end_col} = byte_to_position(span.end_byte, lines, content)
        [{{start_line, start_col}, {end_line, end_col}, rule.replacement} | acc]
    end
  end

  # Converts a byte offset to {line, col} position.
  @spec byte_to_position(non_neg_integer(), [String.t()], String.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp byte_to_position(byte_offset, lines, _content) do
    do_byte_to_position(lines, byte_offset, 0)
  end

  @spec do_byte_to_position([String.t()], non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp do_byte_to_position([], _remaining, line_idx), do: {max(line_idx - 1, 0), 0}

  defp do_byte_to_position([line | rest], remaining, line_idx) do
    line_bytes = byte_size(line) + 1

    if remaining < line_bytes do
      col = grapheme_col(line, remaining)
      {line_idx, col}
    else
      do_byte_to_position(rest, remaining - line_bytes, line_idx + 1)
    end
  end

  # Converts a byte offset within a line to a grapheme column.
  @spec grapheme_col(String.t(), non_neg_integer()) :: non_neg_integer()
  defp grapheme_col(line, byte_offset) do
    prefix = binary_part(line, 0, min(byte_offset, byte_size(line)))
    String.length(prefix)
  end
end
