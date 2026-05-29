defmodule Minga.RenderModel.UI.StatusBar.File do
  @moduledoc false

  @type t :: %__MODULE__{
          name: String.t(),
          filetype: atom(),
          icon: String.t(),
          icon_color: non_neg_integer()
        }

  defstruct name: "",
            filetype: :text,
            icon: "",
            icon_color: 0
end
