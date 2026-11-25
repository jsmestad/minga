defmodule Minga.RenderModel.UI.EmptyList.Action do
  @moduledoc """
  One next step of an empty list: the key that runs it, its label, and the opaque id a frontend echoes back when the row is clicked or run.
  """

  @type t :: %__MODULE__{id: String.t(), key: String.t(), label: String.t()}

  @enforce_keys [:id, :label]
  defstruct id: "", key: "", label: ""
end
