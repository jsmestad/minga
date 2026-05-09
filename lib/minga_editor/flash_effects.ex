defmodule MingaEditor.FlashEffects do
  @moduledoc """
  Executes timer side effects for ephemeral flash animations.

  Both `NavFlash` and `YankFlash` return side-effect instructions as
  data (`{:send_after, msg, interval}`, `{:cancel_timer, ref}`). This
  module provides the shared execution logic so it is not duplicated
  across the Editor GenServer and command helpers.
  """

  @typedoc "Side-effect instruction from a flash module."
  @type side_effect ::
          {:send_after, atom(), pos_integer()}
          | {:cancel_timer, reference()}

  @doc """
  Executes flash side effects and returns the flash struct with the
  timer reference filled in.

  Skips `Process.send_after` in headless mode (no renderer to update).
  """
  @spec apply(map(), struct(), [side_effect()]) :: struct()
  def apply(state, flash, effects) do
    Enum.reduce(effects, flash, fn
      {:send_after, msg, interval}, acc ->
        if state.backend != :headless do
          ref = Process.send_after(self(), msg, interval)
          %{acc | timer: ref}
        else
          acc
        end

      {:cancel_timer, ref}, acc ->
        Process.cancel_timer(ref)
        acc
    end)
  end

  @doc """
  Executes side effects without updating a flash struct (for cancellation).
  """
  @spec execute(map(), [side_effect()]) :: :ok
  def execute(state, effects) do
    Enum.each(effects, fn
      {:cancel_timer, ref} ->
        Process.cancel_timer(ref)

      {:send_after, msg, interval} ->
        if state.backend != :headless do
          Process.send_after(self(), msg, interval)
        end
    end)
  end

  @doc """
  Linear interpolation between two 24-bit RGB colors.
  """
  @spec lerp_color(non_neg_integer(), non_neg_integer(), float()) :: non_neg_integer()
  def lerp_color(_from, to, t) when t >= 1.0, do: to
  def lerp_color(from, _to, t) when t <= 0.0, do: from

  def lerp_color(from, to, t) do
    r1 = Bitwise.bsr(from, 16) |> Bitwise.band(0xFF)
    g1 = Bitwise.bsr(from, 8) |> Bitwise.band(0xFF)
    b1 = Bitwise.band(from, 0xFF)

    r2 = Bitwise.bsr(to, 16) |> Bitwise.band(0xFF)
    g2 = Bitwise.bsr(to, 8) |> Bitwise.band(0xFF)
    b2 = Bitwise.band(to, 0xFF)

    r = round(r1 + (r2 - r1) * t)
    g = round(g1 + (g2 - g1) * t)
    b = round(b1 + (b2 - b1) * t)

    Bitwise.bsl(r, 16) + Bitwise.bsl(g, 8) + b
  end
end
