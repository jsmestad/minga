defmodule Minga.RenderModel.UI.StatusBar.Diagnostics do
  @moduledoc false

  @type counts :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          counts: counts(),
          hint: String.t() | nil
        }

  defstruct counts: {0, 0, 0, 0},
            hint: nil
end
