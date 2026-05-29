defmodule Minga.RenderModel.UI.HoverPopup.Segment do
  @moduledoc """
  One styled markdown segment in the GUI hover popup model.
  """

  @type language :: String.t() | nil

  @type style ::
          :plain
          | :bold
          | :italic
          | :bold_italic
          | :code
          | :code_block
          | {:code_content, language()}
          | :header1
          | :header2
          | :header3
          | :blockquote
          | :list_bullet
          | :rule
          | {:syntax, Minga.Core.Face.t()}

  @type t :: %__MODULE__{
          text: String.t(),
          style: style()
        }

  defstruct text: "",
            style: :plain
end
