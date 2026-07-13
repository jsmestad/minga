defmodule MingaEditor.Shell.Traditional.NavFlash do
  @moduledoc "Pure lifecycle owner for the navigation flash animation."

  @type generation :: non_neg_integer()
  @type t :: %__MODULE__{
          generation: generation(),
          line: non_neg_integer() | nil,
          step: non_neg_integer(),
          max_steps: pos_integer(),
          timer: reference() | nil
        }

  defstruct generation: 0, line: nil, step: 0, max_steps: 3, timer: nil

  @step_interval_ms 100

  @doc "Returns the animation interval used by the workflow."
  @spec step_interval_ms() :: pos_integer()
  def step_interval_ms, do: @step_interval_ms

  @doc "Replaces the active flash and advances its monotonic generation."
  @spec replace(t(), non_neg_integer()) :: t()
  def replace(%__MODULE__{} = flash, line) do
    %__MODULE__{generation: flash.generation + 1, line: line}
  end

  @doc "Records a timer handle only for the current active generation."
  @spec record_timer(t(), generation(), reference()) :: t()
  def record_timer(%__MODULE__{generation: generation, line: line} = flash, generation, timer)
      when is_integer(line) and is_reference(timer),
      do: %{flash | timer: timer}

  def record_timer(%__MODULE__{} = flash, _generation, _timer), do: flash

  @doc "Advances a matching generation, rejecting stale timer delivery."
  @spec advance(t(), generation()) :: {:continue, t()} | {:done, t()} | {:stale, t()}
  def advance(%__MODULE__{generation: generation, line: line} = flash, generation)
      when is_integer(line) do
    if flash.step + 1 >= flash.max_steps do
      {:done, deactivate(flash)}
    else
      {:continue, %{flash | step: flash.step + 1, timer: nil}}
    end
  end

  def advance(%__MODULE__{} = flash, _generation), do: {:stale, flash}

  @doc "Cancels the active flash value while retaining its generation."
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = flash), do: deactivate(flash)

  @doc "Returns whether a navigation flash is active."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{line: line}), do: is_integer(line)

  @doc "Computes the current animation color."
  @spec color_for_step(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def color_for_step(%__MODULE__{step: step, max_steps: max_steps}, flash_bg, target_bg) do
    lerp_color(flash_bg, target_bg, step / max(max_steps - 1, 1))
  end

  @spec deactivate(t()) :: t()
  defp deactivate(%__MODULE__{} = flash), do: %{flash | line: nil, step: 0, timer: nil}

  @spec lerp_color(non_neg_integer(), non_neg_integer(), float()) :: non_neg_integer()
  defp lerp_color(_from, to, fraction) when fraction >= 1.0, do: to
  defp lerp_color(from, _to, fraction) when fraction <= 0.0, do: from

  defp lerp_color(from, to, fraction) do
    interpolate = fn shift ->
      from_channel = Bitwise.band(Bitwise.bsr(from, shift), 0xFF)
      to_channel = Bitwise.band(Bitwise.bsr(to, shift), 0xFF)
      round(from_channel + (to_channel - from_channel) * fraction)
    end

    Bitwise.bsl(interpolate.(16), 16) + Bitwise.bsl(interpolate.(8), 8) + interpolate.(0)
  end
end
