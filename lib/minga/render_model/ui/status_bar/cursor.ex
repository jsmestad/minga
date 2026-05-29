defmodule Minga.RenderModel.UI.StatusBar.Cursor do
  @moduledoc false

  @type t :: %__MODULE__{
          line: non_neg_integer(),
          col: non_neg_integer(),
          line_count: non_neg_integer()
        }

  defstruct line: 0,
            col: 0,
            line_count: 1
end
