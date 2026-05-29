defmodule Minga.RenderModel.UI.ExtensionPanel.Panel do
  @moduledoc """
  One extension-owned panel in the GUI extension panel model.
  """

  @typedoc "Panel placement in the GUI layout."
  @type position :: :bottom | :right | :float

  @typedoc "Panel size requested by the render model."
  @type size :: {:percent, 1..100} | {:lines, pos_integer()}

  alias Minga.RenderModel.UI.ExtensionPanel.Content

  @typedoc "One normalized semantic content block in an extension panel."
  @type content_block :: Content.t()

  @type t :: %__MODULE__{
          extension: String.t(),
          panel_id: String.t(),
          title: String.t(),
          position: position(),
          size: size(),
          visible?: boolean(),
          content: [content_block()]
        }

  @enforce_keys [:extension, :panel_id, :title, :position, :size, :visible?, :content]
  defstruct [:extension, :panel_id, :title, :position, :size, :visible?, :content]
end
