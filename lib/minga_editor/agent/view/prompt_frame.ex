defmodule MingaEditor.Agent.View.PromptFrame do
  @moduledoc "The prompt window, source lease and chat metadata from one immutable projection."

  alias Minga.RenderModel.Window
  alias MingaEditor.Agent.View.PromptProjection
  alias MingaEditor.Renderer.TextPresentation

  @enforce_keys [:window, :presentation, :projection]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          window: Window.t(),
          presentation: TextPresentation.t(),
          projection: PromptProjection.t()
        }
end
