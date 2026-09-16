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
  alias Minga.Core.Unicode

  @typedoc "A zero-indexed `{line, col}` position."
  @type position :: Document.position()

  @typedoc "Result of auto-pair analysis on a typed character."
  @type insert_action ::
          {:pair, String.t(), String.t()}
          | {:skip, String.t()}
          | {:passthrough, String.t()}

  @typedoc "Result of auto-pair analysis on backspace."
  @type backspace_action :: :delete_pair | :passthrough

  @typep delimiter ::
           {:opening, String.t()}
           | {:quote, String.t()}
           | {:closing, String.t()}
           | :plain

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
    on_insert_action(classify_delimiter(char), buffer, {line, col}, char)
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

  @spec classify_delimiter(String.t()) :: delimiter()
  defp classify_delimiter(char), do: classify_opening(char, Map.fetch(@pair_map, char))

  @spec classify_opening(String.t(), {:ok, String.t()} | :error) :: delimiter()
  defp classify_opening(_char, {:ok, close}), do: {:opening, close}
  defp classify_opening(char, :error), do: classify_quote(char, Map.fetch(@quote_pairs, char))

  @spec classify_quote(String.t(), {:ok, String.t()} | :error) :: delimiter()
  defp classify_quote(_char, {:ok, close}), do: {:quote, close}

  defp classify_quote(char, :error),
    do: classify_closing(char, MapSet.member?(@closing_chars, char))

  @spec classify_closing(String.t(), boolean()) :: delimiter()
  defp classify_closing(char, true), do: {:closing, char}
  defp classify_closing(_char, false), do: :plain

  @spec on_insert_action(delimiter(), Document.t(), position(), String.t()) ::
          insert_action()
  defp on_insert_action({:opening, close}, _buffer, _position, char),
    do: {:pair, char, close}

  defp on_insert_action({:closing, _close}, buffer, {line, col}, char) do
    closing_insert_action(char, char_at(buffer, line, col))
  end

  defp on_insert_action({:quote, close}, buffer, {line, col}, char) do
    quote_insert_action(buffer, {line, col}, char, close, char_at(buffer, line, col))
  end

  defp on_insert_action(:plain, _buffer, _position, char), do: {:passthrough, char}

  @spec closing_insert_action(String.t(), String.t() | nil) :: insert_action()
  defp closing_insert_action(char, char), do: {:skip, char}
  defp closing_insert_action(char, _at_cursor), do: {:passthrough, char}

  @spec quote_insert_action(Document.t(), position(), String.t(), String.t(), String.t() | nil) ::
          insert_action()
  defp quote_insert_action(_buffer, _position, char, _close, char), do: {:skip, char}

  defp quote_insert_action(buffer, {line, col}, char, close, _at_cursor) do
    quote_insert_action_for_word_char(char, close, word_char?(char_before(buffer, line, col)))
  end

  @spec quote_insert_action_for_word_char(String.t(), String.t(), boolean()) :: insert_action()
  defp quote_insert_action_for_word_char(char, _close, true), do: {:passthrough, char}
  defp quote_insert_action_for_word_char(char, close, false), do: {:pair, char, close}

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Returns the grapheme at {line, byte_col}, or nil if out of bounds.
  @spec char_at(Document.t(), non_neg_integer(), non_neg_integer()) :: String.t() | nil
  defp char_at(buffer, line, byte_col) do
    case Document.line_at(buffer, line) do
      nil -> nil
      text -> Unicode.grapheme_at(text, byte_col)
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
        previous_byte_col = Unicode.prev_grapheme_byte_offset(text, byte_col)
        Unicode.grapheme_at(text, previous_byte_col)
    end
  end

  # Returns true if the grapheme is a word character (alphanumeric or underscore).
  @spec word_char?(String.t() | nil) :: boolean()
  defp word_char?(nil), do: false
  defp word_char?(g), do: g =~ ~r/^[a-zA-Z0-9_]$/
end
