defmodule MingaEditor.RenderPipeline.WindowContent do
  @moduledoc """
  Per-window product of the Content stage.

  Carries the semantic `RenderModel.Window` structs a single editor window
  produces (the buffer/chat window model plus any additional models such as
  the agent prompt input) and the buffer cursor that window resolves, if it is
  the active window. Compose flattens the models into the frame's window list
  and resolves the final cursor from the per-window cursors and chrome.
  """

  alias Minga.RenderModel.Cursor
  alias Minga.RenderModel.Window, as: RenderWindow

  @enforce_keys [:models]
  defstruct models: [], cursor: nil

  @type t :: %__MODULE__{
          models: [RenderWindow.t()],
          cursor: Cursor.t() | nil
        }

  @doc """
  Builds a window content entry from a primary model, additional models, and
  the window's resolved cursor.

  The primary model may be nil (e.g. a suppressed agent help frame); it is
  dropped from the model list when so.
  """
  @spec new(RenderWindow.t() | nil, [RenderWindow.t()], Cursor.t() | nil) :: t()
  def new(window_model, additional_models, cursor)
      when is_list(additional_models) do
    models = Enum.reject([window_model | additional_models], &is_nil/1)
    %__MODULE__{models: models, cursor: cursor}
  end
end
