defmodule Minga.Test.Storyboard.Keys do
  @moduledoc """
  Parses the key notation used in `docs/design/scenarios.toml` into key presses.

  The inventory writes keys the way the design docs do: `SPC a a`, `esc`, `↩`, `⌃.`, `]h`, `g.` and `SPC (pause)`. Tokens are separated by spaces. A named token (`SPC`, `esc`, `↩`, `TAB`, `backspace`) is one key; a token with a modifier glyph (`⌃`, `⌥`, `⌘`, `⇧`) is one chord; any other token is one key per character, so `]h` is `]` then `h`. `(pause)` waits long enough for which-key to open.

  Exits that are not key presses (`any key`, `1-9`, `insert mode typing`, `:checkhealth`, `(reconnected)`, or a key described in words such as `↩ on a failed block (Normal)`) parse to `:not_a_key_path`, and the factory reports them instead of guessing.
  """

  import Bitwise

  @shift 0x01
  @ctrl 0x02
  @alt 0x04
  @cmd 0x08

  @typedoc "One step of a key path: a key press or a which-key pause."
  @type step :: {:key, non_neg_integer(), non_neg_integer()} | :pause

  @named %{
    "SPC" => 32,
    "esc" => 27,
    "ESC" => 27,
    "↩" => 13,
    "RET" => 13,
    "TAB" => 9,
    "⇥" => 9,
    "backspace" => 127,
    "BS" => 127,
    "⌫" => 127
  }

  @modifiers %{"⌃" => @ctrl, "⌥" => @alt, "⌘" => @cmd, "⇧" => @shift}

  @not_keys ["any key", "insert mode typing", "1-9", "(reconnected)"]

  @prose_words ["or", "on", "of", "the", "out", "any", "exit"]

  @doc """
  Parses one exit's `key` field.

  Returns `{:ok, steps}` for a key path, or `:not_a_key_path` for an empty field, an event, a range or an ex command.
  """
  @spec parse(String.t()) :: {:ok, [step()]} | :not_a_key_path
  def parse(notation) when is_binary(notation) do
    notation = String.trim(notation)

    if notation == "" or notation in @not_keys or ex_command?(notation) or prose?(notation),
      do: :not_a_key_path,
      else: {:ok, notation |> String.split(" ", trim: true) |> Enum.flat_map(&token/1)}
  end

  @doc "Like `parse/1`, but raises for notation that is not a key path."
  @spec parse!(String.t()) :: [step()]
  def parse!(notation) do
    case parse(notation) do
      {:ok, steps} -> steps
      :not_a_key_path -> raise ArgumentError, "not a key path: #{inspect(notation)}"
    end
  end

  @doc "Formats key steps back into the inventory notation, for reports."
  @spec format([step()]) :: String.t()
  def format(steps), do: Enum.map_join(steps, " ", &format_step/1)

  # Exits sometimes describe a key in words ("↩ on a failed block (Normal)", "]] / [["); those are not one key path.
  @spec prose?(String.t()) :: boolean()
  defp prose?(notation) do
    tokens = String.split(notation, " ", trim: true)

    # A "/" between two tokens offers alternatives ("]] / [["); as the last token it is the key itself ("SPC /").
    Enum.any?(tokens, &(&1 in @prose_words or (String.contains?(&1, "(") and &1 != "(pause)"))) or
      "/" in Enum.drop(tokens, -1)
  end

  @spec ex_command?(String.t()) :: boolean()
  defp ex_command?(":"), do: false
  defp ex_command?(notation), do: String.starts_with?(notation, ":")

  @spec token(String.t()) :: [step()]
  defp token("(pause)"), do: [:pause]
  defp token(name) when is_map_key(@named, name), do: [{:key, Map.fetch!(@named, name), 0}]

  defp token(token) do
    case chord(token, 0) do
      {:ok, step} -> [step]
      :plain -> token |> String.graphemes() |> Enum.map(&plain_key/1)
    end
  end

  @spec chord(String.t(), non_neg_integer()) :: {:ok, step()} | :plain
  defp chord(token, mods) do
    case String.next_grapheme(token) do
      {glyph, rest} when is_map_key(@modifiers, glyph) and rest != "" ->
        chord(rest, mods ||| Map.fetch!(@modifiers, glyph))

      _ when mods == 0 ->
        :plain

      _ ->
        [{:key, codepoint, _}] = token(token)
        {:ok, {:key, codepoint, mods}}
    end
  end

  @spec plain_key(String.t()) :: step()
  defp plain_key(<<codepoint::utf8>>), do: {:key, codepoint, 0}

  @spec format_step(step()) :: String.t()
  defp format_step(:pause), do: "(pause)"

  defp format_step({:key, codepoint, mods}) do
    prefix = for {glyph, bit} <- @modifiers, (mods &&& bit) != 0, into: "", do: glyph
    prefix <> key_name(codepoint)
  end

  @spec key_name(non_neg_integer()) :: String.t()
  defp key_name(32), do: "SPC"
  defp key_name(27), do: "esc"
  defp key_name(13), do: "↩"
  defp key_name(9), do: "TAB"
  defp key_name(127), do: "backspace"
  defp key_name(codepoint), do: <<codepoint::utf8>>
end
