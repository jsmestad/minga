defmodule Minga.RenderModel.UI.Completion.Item do
  @moduledoc """
  Semantic completion popup item for GUI adapters.
  """

  @type kind :: atom()

  @type t :: %__MODULE__{
          kind: kind(),
          label: String.t(),
          detail: String.t()
        }

  defstruct kind: :text,
            label: "",
            detail: ""
end
