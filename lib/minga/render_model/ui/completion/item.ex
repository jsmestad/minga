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
          id: String.t(),
          source: String.t(),
          kind: kind(),
          label: String.t(),
          detail: String.t(),
          match_ranges: [%{start: non_neg_integer(), length: pos_integer()}]
        }

  defstruct id: "",
            source: "",
            kind: :text,
            label: "",
            detail: "",
            match_ranges: []
end
