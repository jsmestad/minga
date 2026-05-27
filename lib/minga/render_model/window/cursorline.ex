defmodule Minga.RenderModel.Window.Cursorline do
  @moduledoc """
  Cursorline highlight state for a GUI window.
  """

  @enforce_keys [:row, :bg_rgb]
  defstruct row: 0xFFFF,
            bg_rgb: 0

  @type t :: %__MODULE__{
          row: non_neg_integer(),
          bg_rgb: non_neg_integer()
        }

  @doc "Returns the disabled cursorline sentinel."
  @spec disabled() :: t()
  def disabled, do: %__MODULE__{row: 0xFFFF, bg_rgb: 0}
end
