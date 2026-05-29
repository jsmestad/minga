defmodule Minga.RenderModel.UI.Completion.Item do
  @moduledoc """
  Semantic completion popup item for GUI adapters.
  """

  @type kind ::
          :text
          | :function
          | :method
          | :variable
          | :field
          | :module
          | :keyword
          | :snippet
          | :constant
          | :struct
          | :enum

  @type t :: %__MODULE__{
          kind: kind(),
          label: String.t(),
          detail: String.t()
        }

  defstruct kind: :text,
            label: "",
            detail: ""
end
