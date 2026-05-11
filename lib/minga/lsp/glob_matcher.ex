defmodule Minga.LSP.GlobMatcher do
  @moduledoc """
  Compiles LSP glob patterns to Elixir `Regex` structs and matches file paths.

  LSP glob syntax differs from POSIX shell globs:

  - `*`       matches any characters except `/`
  - `**`      matches any number of characters, including `/`
  - `?`       matches exactly one character except `/`
  - `{a,b}`   matches any of the comma-separated alternatives
  - `[abc]`   matches any character in the set
  - `[!abc]`  matches any character NOT in the set

  Patterns are compiled to `Regex` at registration time for O(1) matching.
  """

  @typedoc "A compiled glob pattern."
  @type compiled :: Regex.t()

  @type change_type :: :created | :changed | :deleted

  @spec compile(term()) :: {:ok, compiled()} | {:error, :invalid_pattern}
  def compile(pattern) when is_binary(pattern) do
    regex_str =
      pattern
      |> String.to_charlist()
      |> translate([])
      |> IO.chardata_to_string()

    case Regex.compile("^" <> regex_str <> "$") do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> {:error, :invalid_pattern}
    end
  end

  def compile(_pattern), do: {:error, :invalid_pattern}

  @spec matches?(compiled(), String.t()) :: boolean()
  def matches?(%Regex{} = compiled, path) when is_binary(path) do
    Regex.match?(compiled, path)
  end

  @doc """
  Tests whether a WatchKind bitmask includes the given change type.

  WatchKind bits: 1=Create, 2=Change, 4=Delete. Default is 7 (all).
  """
  @spec matches_kind?(non_neg_integer(), change_type()) :: boolean()
  def matches_kind?(kind, :created), do: Bitwise.band(kind, 1) != 0
  def matches_kind?(kind, :changed), do: Bitwise.band(kind, 2) != 0
  def matches_kind?(kind, :deleted), do: Bitwise.band(kind, 4) != 0

  # ── Pattern translation ────────────────────────────────────────────────────

  @spec translate(charlist(), iodata()) :: iodata()
  defp translate([], acc), do: Enum.reverse(acc)

  defp translate([?*, ?* | rest], acc) do
    rest = skip_trailing_slash(rest)
    translate(rest, [".*" | acc])
  end

  defp translate([?* | rest], acc) do
    translate(rest, ["[^/]*" | acc])
  end

  defp translate([?? | rest], acc) do
    translate(rest, ["[^/]" | acc])
  end

  defp translate([?{ | rest], acc) do
    {alternatives, remaining} = parse_alternatives(rest, [], [])
    group = "(?:" <> Enum.join(alternatives, "|") <> ")"
    translate(remaining, [group | acc])
  end

  defp translate([?[ | rest], acc) do
    {class, remaining} = parse_char_class(rest, [])
    translate(remaining, [class | acc])
  end

  defp translate([char | rest], acc) do
    escaped = escape_char(char)
    translate(rest, [escaped | acc])
  end

  @spec skip_trailing_slash(charlist()) :: charlist()
  defp skip_trailing_slash([?/ | rest]), do: rest
  defp skip_trailing_slash(rest), do: rest

  # ── Alternation {a,b,c} ────────────────────────────────────────────────────

  @spec parse_alternatives(charlist(), iodata(), [String.t()]) :: {[String.t()], charlist()}
  defp parse_alternatives([], current, alts) do
    alt = current |> Enum.reverse() |> IO.chardata_to_string()
    {Enum.reverse([alt | alts]), []}
  end

  defp parse_alternatives([?} | rest], current, alts) do
    alt = current |> Enum.reverse() |> IO.chardata_to_string()
    {Enum.reverse([alt | alts]), rest}
  end

  defp parse_alternatives([?, | rest], current, alts) do
    alt = current |> Enum.reverse() |> IO.chardata_to_string()
    parse_alternatives(rest, [], [alt | alts])
  end

  defp parse_alternatives([char | rest], current, alts) do
    parse_alternatives(rest, [escape_char(char) | current], alts)
  end

  # ── Character class [abc] / [!abc] ─────────────────────────────────────────

  @spec parse_char_class(charlist(), iodata()) :: {String.t(), charlist()}
  defp parse_char_class([?! | rest], []) do
    parse_char_class_body(rest, ["[^"])
  end

  defp parse_char_class(rest, []) do
    parse_char_class_body(rest, ["["])
  end

  @spec parse_char_class_body(charlist(), iodata()) :: {String.t(), charlist()}
  defp parse_char_class_body([], acc) do
    {acc |> Enum.reverse() |> IO.chardata_to_string() |> Kernel.<>("]"), []}
  end

  defp parse_char_class_body([?] | rest], acc) do
    {acc |> Enum.reverse() |> IO.chardata_to_string() |> Kernel.<>("]"), rest}
  end

  defp parse_char_class_body([char | rest], acc) do
    parse_char_class_body(rest, [<<char::utf8>> | acc])
  end

  # ── Character escaping ─────────────────────────────────────────────────────

  @regex_meta_chars ~c".+^$|()\\[]"

  @spec escape_char(char()) :: String.t()
  defp escape_char(char) when char in @regex_meta_chars, do: "\\" <> <<char::utf8>>
  defp escape_char(char), do: <<char::utf8>>
end
