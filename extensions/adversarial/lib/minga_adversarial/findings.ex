defmodule MingaAdversarial.Findings do
  @moduledoc """
  Parses the model's reply into findings the diagnostics SDK can publish.

  The model is asked for a strict JSON array of `{"line", "concern"}`, but
  models wander: they wrap output in prose or ```json fences. This parser is
  deliberately tolerant — it extracts the outermost JSON array and drops
  anything malformed — and never raises. A bad reply yields `[]`, which is
  treated as "no findings" (and clears stale ones).

  Line numbers arrive 1-based and are converted to the 0-based lines the
  diagnostics pipeline uses.
  """

  @type finding :: %{line: non_neg_integer(), concern: String.t()}

  @spec parse(String.t()) :: [finding()]
  def parse(text) when is_binary(text) do
    case extract_array(text) do
      nil -> []
      json -> json |> decode() |> Enum.flat_map(&to_finding/1)
    end
  end

  @spec decode(String.t()) :: [term()]
  defp decode(json) do
    case JSON.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  # Grabs the substring from the first "[" to the last "]" so leading prose or
  # a ```json fence doesn't defeat the decode.
  @spec extract_array(String.t()) :: String.t() | nil
  defp extract_array(text) do
    # Byte offsets from :binary.match — slice by bytes, not graphemes.
    with start when start != nil <- index_of(text, "["),
         stop when stop != nil and stop >= start <- last_index_of(text, "]") do
      binary_part(text, start, stop - start + 1)
    else
      _ -> nil
    end
  end

  @spec to_finding(term()) :: [finding()]
  defp to_finding(%{"line" => line, "concern" => concern})
       when is_integer(line) and is_binary(concern) and concern != "" do
    [%{line: max(line - 1, 0), concern: concern}]
  end

  defp to_finding(_other), do: []

  @spec index_of(String.t(), String.t()) :: non_neg_integer() | nil
  defp index_of(text, needle) do
    case :binary.match(text, needle) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  @spec last_index_of(String.t(), String.t()) :: non_neg_integer() | nil
  defp last_index_of(text, needle) do
    case :binary.matches(text, needle) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
