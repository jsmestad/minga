defprotocol Minga.Core.WidthOracle do
  @moduledoc """
  Measures display width for wrap computation.

  The render pipeline passes an oracle value into `Minga.Core.WrapMap` so wrap decisions can stay BEAM-owned while the measurement strategy varies by frontend. The safe production oracle is monospace. Measured oracles are opt-in and only make sense when the caller owns the cache.
  """

  @doc "Returns the display width of a single grapheme."
  @spec grapheme_width(t(), String.t()) :: non_neg_integer()
  def grapheme_width(oracle, grapheme)

  @doc "Returns the display width of a text string."
  @spec display_width(t(), String.t()) :: non_neg_integer()
  def display_width(oracle, text)

  @doc "Returns a compact fingerprint that changes when wrapped text measurement changes."
  @spec fingerprint(t()) :: term()
  def fingerprint(oracle)
end
