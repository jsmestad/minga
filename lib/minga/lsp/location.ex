defmodule Minga.LSP.Location do
  @moduledoc """
  Decodes LSP Location and LocationLink values without resolving their URIs or
  converting their server-provided positions.
  """

  @type t :: {uri :: String.t(), line :: non_neg_integer(), col :: non_neg_integer()}

  @doc """
  Decodes a single location or the first item of a list.

  An unrecognized first item returns `nil`, even if later items are valid.
  """
  @spec first(term()) :: t() | nil
  def first([location | _]), do: decode(location)
  def first(location), do: decode(location)

  @doc "Decodes one location, using `targetRange` rather than `targetSelectionRange` for links."
  @spec decode(term()) :: t() | nil
  def decode(%{"uri" => uri, "range" => range}), do: with_range_start(uri, range)
  def decode(%{"targetUri" => uri, "targetRange" => range}), do: with_range_start(uri, range)
  def decode(_), do: nil

  @doc """
  Extracts a range's start, defaulting to `{0, 0}` when the start position is
  absent or incomplete.
  """
  @spec range_start(term()) :: {non_neg_integer(), non_neg_integer()}
  def range_start(%{"start" => %{"line" => line, "character" => col}}), do: {line, col}
  def range_start(_), do: {0, 0}

  @spec with_range_start(String.t(), term()) :: t()
  defp with_range_start(uri, range) do
    {line, col} = range_start(range)
    {uri, line, col}
  end
end
