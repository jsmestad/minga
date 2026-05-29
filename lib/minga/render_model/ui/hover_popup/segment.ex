defmodule Minga.RenderModel.UI.HoverPopup.Segment do
  @moduledoc """
  One styled markdown segment in the GUI hover popup model.
  """

  @type style :: atom() | {atom(), term()} | {:syntax, Minga.Core.Face.t()}

  @type t :: %__MODULE__{
          text: String.t(),
          style: style()
        }

  defstruct text: "",
            style: :plain
end
