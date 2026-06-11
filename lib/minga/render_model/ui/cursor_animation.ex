defmodule Minga.RenderModel.UI.CursorAnimation do
  @moduledoc false

  # Whether GUI frontends should animate cursor movement. Reduce Motion can still
  # disable animation on the frontend regardless of this preference.
  @type t :: %__MODULE__{
          enabled?: boolean()
        }

  @enforce_keys [:enabled?]
  defstruct enabled?: true
end
