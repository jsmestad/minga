defmodule MingaAgent.InferenceRoute.ToolDeclaration do
  @moduledoc "A tool the model may call. `input_schema` is a JSON Schema map with string keys."

  @enforce_keys [:name, :description, :input_schema]
  defstruct @enforce_keys

  @type t :: %__MODULE__{name: String.t(), description: String.t(), input_schema: map()}
end
