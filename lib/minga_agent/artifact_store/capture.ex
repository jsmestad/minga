defmodule MingaAgent.ArtifactStore.Capture do
  @moduledoc "An opaque handle for one namespace-bound streamed capture."

  @type t :: %__MODULE__{id: String.t(), namespace: String.t()}

  @enforce_keys [:id, :namespace]
  defstruct [:id, :namespace]

  @doc false
  @spec new(String.t(), String.t()) :: t()
  def new(id, namespace) when is_binary(id) and is_binary(namespace),
    do: %__MODULE__{id: id, namespace: namespace}
end
