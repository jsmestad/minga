defmodule Minga.Core.Color do
  @moduledoc "Pure calculations for packed RGB colors."

  @doc "Interpolates between two packed RGB colors and clamps the fraction to the endpoints."
  @spec interpolate(non_neg_integer(), non_neg_integer(), float()) :: non_neg_integer()
  def interpolate(_from, to, fraction) when fraction >= 1.0, do: to
  def interpolate(from, _to, fraction) when fraction <= 0.0, do: from

  def interpolate(from, to, fraction) do
    interpolate_channel = fn shift ->
      from_channel = Bitwise.band(Bitwise.bsr(from, shift), 0xFF)
      to_channel = Bitwise.band(Bitwise.bsr(to, shift), 0xFF)
      round(from_channel + (to_channel - from_channel) * fraction)
    end

    Bitwise.bsl(interpolate_channel.(16), 16) +
      Bitwise.bsl(interpolate_channel.(8), 8) +
      interpolate_channel.(0)
  end
end
