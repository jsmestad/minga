defmodule Minga.RenderModel.UI.StatusBar.Selection do
  @moduledoc false

  @type mode :: :none | :chars | :lines

  @type t :: %__MODULE__{
          mode: mode(),
          size: non_neg_integer()
        }

  defstruct mode: :none,
            size: 0
end
