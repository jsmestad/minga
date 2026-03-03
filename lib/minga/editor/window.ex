defmodule Minga.Editor.Window do
  @moduledoc """
  A window is a viewport into a buffer.

  Each window holds a reference to a buffer process and its own independent
  viewport (scroll position and dimensions). Multiple windows can reference
  the same buffer — edits in one are visible in all.
  """

  alias Minga.Editor.Viewport

  @typedoc "Unique identifier for a window."
  @type id :: pos_integer()

  @type t :: %__MODULE__{
          id: id(),
          buffer: pid(),
          viewport: Viewport.t()
        }

  @enforce_keys [:id, :buffer, :viewport]
  defstruct [:id, :buffer, :viewport]

  @doc "Creates a new window with the given id, buffer, and viewport dimensions."
  @spec new(id(), pid(), pos_integer(), pos_integer()) :: t()
  def new(id, buffer, rows, cols)
      when is_integer(id) and id > 0 and is_pid(buffer) and
             is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    %__MODULE__{
      id: id,
      buffer: buffer,
      viewport: Viewport.new(rows, cols)
    }
  end

  @doc "Updates the viewport dimensions for this window."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(%__MODULE__{} = window, rows, cols)
      when is_integer(rows) and rows > 0 and is_integer(cols) and cols > 0 do
    %{window | viewport: Viewport.new(rows, cols)}
  end
end
