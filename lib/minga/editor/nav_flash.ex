defmodule Minga.Editor.NavFlash do
  @moduledoc """
  Cursor line flash after large jumps.

  Briefly highlights the landing line with a brighter background after
  the cursor moves more than a configurable threshold. The flash fades
  in steps from a bright highlight back to the normal cursorline tint
  (or editor bg if cursorline is disabled).

  This is a pure calculation module. It returns structs and side-effect
  instructions (`{:send_after, msg, interval}`, `{:cancel_timer, ref}`).
  The Editor GenServer executes the side effects.
  """

  @typedoc "Flash state: nil when inactive, struct when flashing."
  @type t :: %__MODULE__{
          line: non_neg_integer(),
          step: non_neg_integer(),
          max_steps: pos_integer(),
          timer: reference() | nil
        }

  @typedoc "Side-effect instruction returned to the caller."
  @type side_effect ::
          {:send_after, atom(), pos_integer()}
          | {:cancel_timer, reference()}

  @enforce_keys [:line, :step, :max_steps]
  defstruct line: 0, step: 0, max_steps: 3, timer: nil

  @step_interval_ms 100

  @doc """
  Creates a new flash struct for the given line.

  Returns `{flash, side_effects}`. The caller must execute the side
  effects (cancel old timer, schedule new one).
  """
  @spec start(non_neg_integer(), reference() | nil) :: {t(), [side_effect()]}
  def start(line, existing_timer \\ nil) do
    effects =
      if existing_timer do
        [{:cancel_timer, existing_timer}, {:send_after, :nav_flash_step, @step_interval_ms}]
      else
        [{:send_after, :nav_flash_step, @step_interval_ms}]
      end

    {%__MODULE__{line: line, step: 0, max_steps: 3, timer: nil}, effects}
  end

  @doc """
  Advances the flash to the next step.

  Returns `{:continue, updated_flash, side_effects}` if more steps
  remain, or `:done` if the flash is complete.
  """
  @spec advance(t()) :: {:continue, t(), [side_effect()]} | :done
  def advance(%__MODULE__{step: step, max_steps: max_steps}) when step + 1 >= max_steps do
    :done
  end

  def advance(%__MODULE__{} = flash) do
    {:continue, %{flash | step: flash.step + 1, timer: nil},
     [{:send_after, :nav_flash_step, @step_interval_ms}]}
  end

  @doc """
  Returns side effects needed to cancel an active flash.

  Returns an empty list for nil input.
  """
  @spec cancel_effects(t() | nil) :: [side_effect()]
  def cancel_effects(nil), do: []
  def cancel_effects(%__MODULE__{timer: nil}), do: []
  def cancel_effects(%__MODULE__{timer: ref}), do: [{:cancel_timer, ref}]

  @doc """
  Computes the flash background color for the current step.

  Interpolates between `flash_bg` (step 0) and `target_bg` (final step)
  linearly. `target_bg` is the cursorline bg if cursorline is enabled,
  or the editor bg otherwise.
  """
  @spec color_for_step(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def color_for_step(%__MODULE__{step: step, max_steps: max_steps}, flash_bg, target_bg) do
    lerp_color(flash_bg, target_bg, step / max(max_steps - 1, 1))
  end

  # Linear interpolation between two RGB colors.
  @spec lerp_color(non_neg_integer(), non_neg_integer(), float()) :: non_neg_integer()
  defp lerp_color(_from, to, t) when t >= 1.0, do: to
  defp lerp_color(from, _to, t) when t <= 0.0, do: from

  defp lerp_color(from, to, t) do
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
