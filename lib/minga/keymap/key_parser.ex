defmodule Minga.Keymap.KeyParser do
  @moduledoc """
  Parses human-readable key sequence strings into trie key tuples.

  Converts strings like `"SPC g s"` or `"C-x C-s"` into the
  `[{codepoint, modifiers}]` format used by `Minga.Keymap.Trie`.

  ## Supported tokens

  | Token   | Meaning                    |
  |---------|----------------------------|
  | `SPC`   | Space (codepoint 32)       |
  | `TAB`   | Tab (codepoint 9)          |
  | `RET`   | Return/Enter (codepoint 13)|
  | `ESC`   | Escape (codepoint 27)      |
  | `DEL`   | Delete (codepoint 127)     |
  | `C-x`   | Ctrl + x                   |
  | `M-x`   | Alt/Meta + x               |
  | `a`     | Single character           |

  ## Examples

      iex> Minga.Keymap.KeyParser.parse("SPC g s")
      {:ok, [{32, 0}, {103, 0}, {115, 0}]}

      iex> Minga.Keymap.KeyParser.parse("C-s")
      {:ok, [{115, 2}]}

      iex> Minga.Keymap.KeyParser.parse("")
      {:error, "empty key sequence"}
  """

  alias Minga.Keymap.Trie

  import Bitwise

  # Modifier bitmasks
  @mod_shift 0x01
  @mod_ctrl 0x02
  @mod_alt 0x04

  # Named key mappings
  @named_keys %{
    "SPC" => 32,
    "TAB" => 9,
    "RET" => 13,
    "ESC" => 27,
    "DEL" => 127
  }

  @doc """
  Parses a key sequence string into a list of `{codepoint, modifiers}` tuples.

  Returns `{:ok, keys}` on success or `{:error, reason}` on failure.
  """
  @spec parse(String.t()) :: {:ok, [Trie.key()]} | {:error, String.t()}
  def parse(str) when is_binary(str) do
    str = String.trim(str)

    if str == "" do
      {:error, "empty key sequence"}
    else
      tokens = String.split(str, " ", trim: true)
      parse_tokens(tokens, [])
    end
  end

  @doc """
  Like `parse/1` but raises on error.
  """
  @spec parse!(String.t()) :: [Trie.key()]
  def parse!(str) do
    case parse(str) do
      {:ok, keys} -> keys
      {:error, msg} -> raise ArgumentError, "invalid key sequence #{inspect(str)}: #{msg}"
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec parse_tokens([String.t()], [Trie.key()]) ::
          {:ok, [Trie.key()]} | {:error, String.t()}
  defp parse_tokens([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_tokens([token | rest], acc) do
    case parse_token(token) do
      {:ok, key} -> parse_tokens(rest, [key | acc])
      {:error, _} = err -> err
    end
  end

  @spec parse_token(String.t()) :: {:ok, Trie.key()} | {:error, String.t()}

  # Named keys: SPC, TAB, RET, ESC, DEL
  defp parse_token(token) when is_map_key(@named_keys, token) do
    {:ok, {Map.fetch!(@named_keys, token), 0}}
  end

  # Ctrl modifier: C-x
  defp parse_token("C-" <> <<char::utf8>>) do
    {:ok, {char, @mod_ctrl}}
  end

  # Alt/Meta modifier: M-x
  defp parse_token("M-" <> <<char::utf8>>) do
    {:ok, {char, @mod_alt}}
  end

  # Ctrl+Shift: C-S-x (less common but valid)
  defp parse_token("C-S-" <> <<char::utf8>>) do
    {:ok, {char, @mod_ctrl ||| @mod_shift}}
  end

  # Single character
  defp parse_token(<<char::utf8>>) do
    {:ok, {char, 0}}
  end

  # Uppercase single character (carries implicit shift for documentation but
  # the codepoint already encodes the uppercase letter)
  defp parse_token(token) do
    {:error, "unrecognized key token: #{inspect(token)}"}
  end
end
