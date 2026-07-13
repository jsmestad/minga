defmodule MingaEditor.Shell.Traditional.YankFlash do
  @moduledoc "Pure lifecycle owner for the yank-region flash animation."

  @type position :: {non_neg_integer(), non_neg_integer()}
  @type range_type :: :charwise | :linewise
  @type generation :: non_neg_integer()
  @type t :: %__MODULE__{
          generation: generation(),
          buf: pid() | nil,
          start_pos: position(),
          end_pos: position(),
          range_type: range_type(),
          step: non_neg_integer(),
          max_steps: pos_integer(),
          timer: reference() | nil
        }

  defstruct generation: 0,
            buf: nil,
            start_pos: {0, 0},
            end_pos: {0, 0},
            range_type: :charwise,
            step: 0,
            max_steps: 4,
            timer: nil

  @step_interval_ms 60
  @flash_group :yank_flash
  @default_flash_bg 0x4B5263

  @doc "Returns the animation interval used by the workflow."
  @spec step_interval_ms() :: pos_integer()
  def step_interval_ms, do: @step_interval_ms

  @doc "Returns the decoration group owned by the yank flash workflow."
  @spec flash_group() :: atom()
  def flash_group, do: @flash_group

  @doc "Returns the fallback yank flash color."
  @spec default_flash_bg() :: non_neg_integer()
  def default_flash_bg, do: @default_flash_bg

  @doc "Replaces the active yank flash and advances its monotonic generation."
  @spec replace(t(), pid(), position(), position(), range_type()) :: t()
  def replace(%__MODULE__{} = flash, buf, start_pos, end_pos, range_type) do
    %__MODULE__{
      generation: flash.generation + 1,
      buf: buf,
      start_pos: start_pos,
      end_pos: end_pos,
      range_type: range_type
    }
  end

  @doc "Records a timer handle only for the current active generation."
  @spec record_timer(t(), generation(), reference()) :: t()
  def record_timer(%__MODULE__{generation: generation, buf: buf} = flash, generation, timer)
      when is_pid(buf) and is_reference(timer),
      do: %{flash | timer: timer}

  def record_timer(%__MODULE__{} = flash, _generation, _timer), do: flash

  @doc "Advances a matching generation, rejecting stale timer delivery."
  @spec advance(t(), generation()) :: {:continue, t()} | {:done, t()} | {:stale, t()}
  def advance(%__MODULE__{generation: generation, buf: buf} = flash, generation)
      when is_pid(buf) do
    if flash.step + 1 >= flash.max_steps do
      {:done, deactivate(flash)}
    else
      {:continue, %{flash | step: flash.step + 1, timer: nil}}
    end
  end

  def advance(%__MODULE__{} = flash, _generation), do: {:stale, flash}

  @doc "Cancels the active yank flash while retaining its generation."
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = flash), do: deactivate(flash)

  @doc "Returns whether a yank flash is active."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{buf: buf}), do: is_pid(buf)

  @doc "Computes the current animation color."
  @spec color_for_step(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def color_for_step(%__MODULE__{step: step, max_steps: max_steps}, flash_bg, target_bg) do
    lerp_color(flash_bg, target_bg, step / max(max_steps - 1, 1))
  end

  @doc "Computes charwise or linewise highlight bounds from workflow-provided line length."
  @spec highlight_bounds(position(), position(), range_type(), non_neg_integer()) ::
          {position(), position()}
  def highlight_bounds(start_pos, end_pos, :charwise, _end_line_length),
    do: {start_pos, end_pos}

  def highlight_bounds({start_line, _}, {end_line, _}, :linewise, end_line_length),
    do: {{start_line, 0}, {end_line, end_line_length}}

  @spec deactivate(t()) :: t()
  defp deactivate(%__MODULE__{} = flash), do: %{flash | buf: nil, step: 0, timer: nil}

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
