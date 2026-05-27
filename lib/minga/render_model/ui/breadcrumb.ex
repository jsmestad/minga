defmodule Minga.RenderModel.UI.Breadcrumb do
  @moduledoc false

  @type t :: %__MODULE__{
          file_path: String.t() | nil,
          root: String.t()
        }

  @enforce_keys [:root]
  defstruct [:file_path, :root]
end
