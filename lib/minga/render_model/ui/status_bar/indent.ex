defmodule Minga.RenderModel.UI.StatusBar.Indent do
  @moduledoc false

  @type indent_type :: :spaces | :tabs

  @type t :: %__MODULE__{
          type: indent_type(),
          size: pos_integer()
        }

  defstruct type: :spaces,
            size: 2
end
