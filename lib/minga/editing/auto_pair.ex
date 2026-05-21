defmodule Minga.Editing.AutoPair do
  @moduledoc """
  Pure-function auto-pairing logic for paired delimiters.

  Given a buffer state, cursor position, and a typed character, determines
  whether to insert a pair, skip over a closing delimiter, or pass through
  unchanged. Also handles backspace deletion of empty pairs.

  ## Pair types

  | Open | Close |
  |------|-------|
  | `(`  | `)`   |
  | `[`  | `]`   |
  | `{`  | `}`   |
  | `"`  | `"`   |
  | `'`  | `'`   |
  | `` ` `` | `` ` `` |

  ## Smart quote handling

  Quote characters (`"`, `'`, `` ` ``) are not auto-paired when preceded by a
  word character (alphanumeric or underscore). This prevents unwanted pairing
  in contractions (`don't`), string closings, and similar contexts.

  Language-aware context detection (suppressing auto-pair inside strings or
  comments) is deferred to tree-sitter integration.
  """

  alias Minga.Buffer.Document

  @typedoc "A zero-indexed `{line, col}` position."
  @type position :: Document.position()

  @typedoc "Result of auto-pair analysis on a typed character."
  @type insert_action ::
          {:pair, String.t(), String.t()}
          | {:skip, String.t()}
          | {:passthrough, String.t()}

  @typedoc "Result of auto-pair analysis on backspace."
  @type backspace_action :: :delete_pair | :passthrough

  # Maps opening delimiters to their closing counterpart.
  @pair_map %{
    "(" => ")",
    "[" => "]",
    "{" => "}"
  }

  # Symmetric pairs (open == close).
  @quote_pairs %{
    "\"" => "\"",
    "'" => "'",
    "`" => "`"
  }

  # All opening chars (for reverse lookup on backspace).
  @all_pairs Map.merge(@pair_map, @quote_pairs)

  # Set of closing-only delimiters (asymmetric pairs).
  @closing_chars MapSet.new(Map.values(@pair_map))

  @doc """
  Determines the auto-pair action for a character typed in Insert mode.

  Returns:
  - `{:pair, open, close}` — insert both characters, cursor between
  - `{:skip, char}` — the closing delimiter is already under cursor; skip over it
  - `{:passthrough, char}` — insert the character normally

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello")
      iex> Minga.Editing.AutoPair.on_insert(buf, {0, 5}, "(")
      {:pair, "(", ")"}

      iex> buf = Minga.Buffer.Document.new("()")
      iex> Minga.Editing.AutoPair.on_insert(buf, {0, 1}, ")")
      {:skip, ")"}
  """
  @spec on_insert(Document.t(), position(), String.t()) :: insert_action()
  def on_insert(%Document{} = buffer, {line, col}, char) do
    char_at_cursor = char_at(buffer, line, col)

    on_insert_action(
      buffer,
      {line, col},
      char,
      MapSet.member?(@closing_chars, char) and char_at_cursor == char,
      Map.has_key?(@quote_pairs, char) and char_at_cursor == char,
      Map.has_key?(@pair_map, char),
      Map.has_key?(@quote_pairs, char)
    )
  end

  @doc """
  Determines whether backspace should delete an empty pair.

  When the character before the cursor is an opening delimiter and the
  character at the cursor is its matching closer, returns `:delete_pair`.
  Otherwise returns `:passthrough`.

  ## Examples

      iex> buf = Minga.Buffer.Document.new("()")
      iex> Minga.Editing.AutoPair.on_backspace(buf, {0, 1})
      :delete_pair

      iex> buf = Minga.Buffer.Document.new("(x)")
      iex> Minga.Editing.AutoPair.on_backspace(buf, {0, 1})
      :passthrough
  """
  @spec on_backspace(Document.t(), position()) :: backspace_action()
  def on_backspace(%Document{}, {_line, 0}), do: :passthrough

  def on_backspace(%Document{} = buffer, {line, col}) do
    before = char_at(buffer, line, col - 1)
    at = char_at(buffer, line, col)

    case Map.get(@all_pairs, before) do
      nil -> :passthrough
      expected_close when expected_close == at -> :delete_pair
      _ -> :passthrough
    end
  end

  @doc """
  Returns the closing delimiter for a given opening delimiter, or `nil`.

  Used by Visual mode wrapping to determine the closing character.

  ## Examples

      iex> Minga.Editing.AutoPair.closing_for("(")
      ")"

      iex> Minga.Editing.AutoPair.closing_for("x")
      nil
  """
  @spec closing_for(String.t()) :: String.t() | nil
  def closing_for(char), do: Map.get(@all_pairs, char)

  @spec on_insert_action(
          Document.t(),
          position(),
          String.t(),
          boolean(),
          boolean(),
          boolean(),
          boolean()
        ) ::
          insert_action()
  defp on_insert_action(_buffer, _position, char, true, _quote_match?, _opening?, _quote?),
    do: {:skip, char}

  defp on_insert_action(_buffer, _position, char, false, true, _opening?, _quote?),
    do: {:skip, char}

  defp on_insert_action(_buffer, _position, char, false, false, true, _quote?),
    do: {:pair, char, Map.fetch!(@pair_map, char)}

  defp on_insert_action(buffer, {line, col}, char, false, false, false, true) do
    quote_insert_action(char, char_before(buffer, line, col))
  end

  defp on_insert_action(_buffer, _position, char, false, false, false, false),
    do: {:passthrough, char}

  @spec quote_insert_action(String.t(), String.t() | nil) :: insert_action()
  defp quote_insert_action(char, char_before) do
    quote_insert_action_for_word_char(char, word_char?(char_before))
  end

  @spec quote_insert_action_for_word_char(String.t(), boolean()) :: insert_action()
  defp quote_insert_action_for_word_char(char, true), do: {:passthrough, char}

  defp quote_insert_action_for_word_char(char, false),
    do: {:pair, char, Map.fetch!(@quote_pairs, char)}

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Returns the grapheme at {line, byte_col}, or nil if out of bounds.
  @spec char_at(Document.t(), non_neg_integer(), non_neg_integer()) :: String.t() | nil
  defp char_at(buffer, line, byte_col) do
    case Document.line_at(buffer, line) do
      nil ->
        nil

      text when byte_col >= byte_size(text) ->
        nil

      text ->
        rest = binary_part(text, byte_col, byte_size(text) - byte_col)

        case String.next_grapheme(rest) do
          {g, _} -> g
          nil -> nil
        end
    end
  end

  # Returns the grapheme before the cursor position, or nil.
  @spec char_before(Document.t(), non_neg_integer(), non_neg_integer()) :: String.t() | nil
  defp char_before(_buffer, _line, 0), do: nil

  defp char_before(buffer, line, byte_col) do
    case Document.line_at(buffer, line) do
      nil ->
        nil

      text ->
        # Find grapheme whose byte offset is just before byte_col
        find_grapheme_before(text, byte_col)
    end
  end

  @spec find_grapheme_before(String.t(), non_neg_integer()) :: String.t() | nil
  defp find_grapheme_before(text, target_byte) do
    do_find_grapheme_before(text, target_byte, 0, nil)
  end

  @spec do_find_grapheme_before(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          String.t() | nil
        ) ::
          String.t() | nil
  defp do_find_grapheme_before(text, target, current_byte, prev_g) do
    if current_byte >= target do
      prev_g
    else
      case String.next_grapheme(text) do
        {g, rest} ->
          g_size = byte_size(text) - byte_size(rest)
          do_find_grapheme_before(rest, target, current_byte + g_size, g)

        nil ->
          prev_g
      end
    end
  end

  # Returns true if the grapheme is a word character (alphanumeric or underscore).
  @spec word_char?(String.t() | nil) :: boolean()
  defp word_char?(nil), do: false
  defp word_char?(g), do: g =~ ~r/^[a-zA-Z0-9_]$/
end
