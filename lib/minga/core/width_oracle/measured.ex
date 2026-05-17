defmodule Minga.Core.WidthOracle.Measured do
  @moduledoc """
  Width oracle backed by cached frontend text measurements.

  A measured oracle carries per-instance state, so proportional font wrapping can use GUI measurements without changing `Minga.Core.WrapMap`. Only use it when the caller owns the cache and can keep it in sync. Cache misses deliberately fall back to monospace widths; callers can populate the cache from `measure_text` and recompute wrap maps when `text_width` responses arrive.
  """

  alias Minga.Core.Unicode

  defstruct cache: %{}

  @type t :: %__MODULE__{cache: %{String.t() => non_neg_integer()}}

  @doc "Creates a measured oracle with an owned width cache."
  @spec new(%{String.t() => non_neg_integer()}) :: t()
  def new(cache \\ %{}) when is_map(cache), do: %__MODULE__{cache: cache}

  @doc "Stores a measured width for text in the oracle cache."
  @spec put_width(t(), String.t(), non_neg_integer()) :: t()
  def put_width(%__MODULE__{cache: cache} = oracle, text, width)
      when is_binary(text) and is_integer(width) and width >= 0 do
    %{oracle | cache: Map.put(cache, text, width)}
  end

  @doc "Clears cached measurements, for example after font or resize changes."
  @spec clear_cache(t()) :: t()
  def clear_cache(%__MODULE__{} = oracle), do: %{oracle | cache: %{}}

  @doc "Returns a cached width or the monospace fallback when absent."
  @spec cached_or_fallback(t(), String.t()) :: non_neg_integer()
  def cached_or_fallback(%__MODULE__{cache: cache}, text) when is_binary(text) do
    Map.get(cache, text, Unicode.display_width(text))
  end
end

defimpl Minga.Core.WidthOracle, for: Minga.Core.WidthOracle.Measured do
  @moduledoc false

  alias Minga.Core.WidthOracle.Measured

  @spec grapheme_width(Measured.t(), String.t()) :: non_neg_integer()
  def grapheme_width(%Measured{} = oracle, grapheme),
    do: Measured.cached_or_fallback(oracle, grapheme)

  @spec display_width(Measured.t(), String.t()) :: non_neg_integer()
  def display_width(%Measured{} = oracle, text), do: Measured.cached_or_fallback(oracle, text)
end
