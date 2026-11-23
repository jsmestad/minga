defmodule MingaAgent.Providers.Native.ToolResultBound do
  @moduledoc """
  Bounds the text one tool result sends to the model.

  A small-context route cannot spend its whole context on one file read. A bounded result keeps whole lines from the start of the text and ends with an explicit truncation marker that names the original and kept sizes, so the model knows it saw part of the result and how to ask for more.
  """

  @typedoc "The most result bytes one tool result may send, or no bound."
  @type t :: :unbounded | {:bytes, pos_integer()}

  @doc "Returns `text` unchanged within the bound, otherwise a marked prefix of whole lines."
  @spec limit(String.t(), t()) :: String.t()
  def limit(text, :unbounded) when is_binary(text), do: text
  def limit(text, {:bytes, max}) when is_binary(text) and byte_size(text) <= max, do: text

  def limit(text, {:bytes, max}) when is_binary(text) and is_integer(max) and max > 0 do
    kept = text |> binary_part(0, max) |> utf8_prefix() |> line_prefix()

    kept <>
      "\n[Minga truncated this result from #{byte_size(text)} to #{byte_size(kept)} bytes to fit the model's context. Request a smaller part, such as read_file with offset and limit, to see more.]"
  end

  # Drops a trailing partial UTF-8 sequence left by a byte cut.
  @spec utf8_prefix(binary()) :: String.t()
  defp utf8_prefix(bytes) do
    case :unicode.characters_to_binary(bytes) do
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  # Ends on a whole line when one exists, so a cut never splits a line the model may quote.
  @spec line_prefix(String.t()) :: String.t()
  defp line_prefix(text) do
    case :binary.matches(text, "\n") do
      [] -> text
      matches -> binary_part(text, 0, matches |> List.last() |> elem(0))
    end
  end
end
