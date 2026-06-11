defmodule MingaEditor.RenderPipeline.ComposedFrame do
  @moduledoc """
  Product of the Compose stage: the flattened semantic frame the Emit stage
  encodes.

  Holds the frame's `RenderModel.Window` list (already flattened across every
  editor window) and the single resolved `RenderModel.Cursor`. The top-level
  `RenderModel.Builder` reads these two fields directly, so this struct is the
  literal pipeline product handed to frontend adapters (#2241). Chrome and UI
  surfaces ride alongside via the `Chrome` struct passed to the builder, not
  through this frame.
  """

  alias Minga.RenderModel.Cursor
  alias Minga.RenderModel.Window, as: RenderWindow

  @enforce_keys [:cursor]
  defstruct [:cursor, windows: []]

  @type t :: %__MODULE__{
          windows: [RenderWindow.t()],
          cursor: Cursor.t()
        }

  @doc "Builds a composed frame from the flattened window list and resolved cursor."
  @spec new([RenderWindow.t()], Cursor.t()) :: t()
  def new(windows, %Cursor{} = cursor) when is_list(windows) do
    %__MODULE__{windows: windows, cursor: cursor}
  end
end
