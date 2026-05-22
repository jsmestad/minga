defmodule Minga.Keymap.Sigil do
  @moduledoc """
  Compile-time sigils for readable keymap definitions.

  `~k` parses the same human-readable key tokens accepted by `Minga.Keymap.KeyParser` and expands to the internal `{codepoint, modifiers}` tuples used by keymap tries.

  `~K` does the same parsing but requires exactly one key and returns the single tuple instead of a list.
  """

  alias Minga.Keymap.KeyParser

  @doc """
  Parses a literal key sequence into keymap tuples at compile time.

  ## Examples

      iex> import Minga.Keymap.Sigil
      iex> ~k(s p)
      [{115, 0}, {112, 0}]

      iex> import Minga.Keymap.Sigil
      iex> ~k(C-d)
      [{100, 2}]
  """
  @spec sigil_k(Macro.t(), charlist()) :: Macro.t()
  defmacro sigil_k({:<<>>, _meta, [string]}, modifiers) when is_binary(string) do
    validate_modifiers!(modifiers, "~k")

    string
    |> KeyParser.parse!()
    |> Macro.escape()
  end

  defmacro sigil_k(_term, _modifiers) do
    raise ArgumentError, "~k only supports literal key sequences"
  end

  @doc """
  Parses a literal key sequence into a single key tuple at compile time.

  ## Examples

      iex> import Minga.Keymap.Sigil
      iex> ~K(SPC)
      {32, 0}

      iex> import Minga.Keymap.Sigil
      iex> ~K(C-d)
      {100, 2}
  """
  @spec sigil_K(Macro.t(), charlist()) :: Macro.t()
  defmacro sigil_K({:<<>>, _meta, [string]}, modifiers) when is_binary(string) do
    validate_modifiers!(modifiers, "~K")

    parsed_keys =
      if String.trim(string) == "" do
        []
      else
        KeyParser.parse!(string)
      end

    case parsed_keys do
      [key] ->
        Macro.escape(key)

      [] ->
        raise ArgumentError,
              "~K requires exactly one key, but #{inspect(string)} parsed to zero keys"

      keys ->
        raise ArgumentError,
              "~K requires exactly one key, but #{inspect(string)} parsed to #{length(keys)} keys"
    end
  end

  defmacro sigil_K(_term, _modifiers) do
    raise ArgumentError, "~K only supports literal key sequences"
  end

  @spec validate_modifiers!(charlist(), String.t()) :: :ok
  defp validate_modifiers!([], _sigil), do: :ok

  defp validate_modifiers!(modifiers, sigil) do
    raise ArgumentError,
          "#{sigil} does not support sigil modifiers: #{inspect(List.to_string(modifiers))}"
  end
end
