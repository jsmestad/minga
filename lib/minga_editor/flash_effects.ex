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
end
