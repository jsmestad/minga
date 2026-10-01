defmodule MingaAgent.ArtifactStore.Stored do
  @moduledoc "The durable result of a terminal artifact capture."

  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Reference

  @type t :: %__MODULE__{reference: Reference.t(), capture: Output.capture_status()}

  @enforce_keys [:reference, :capture]
  defstruct [:reference, :capture]

  @doc false
  @spec new(Reference.t(), Output.capture_status()) :: t()
  def new(%Reference{} = reference, capture),
    do: %__MODULE__{reference: reference, capture: capture}
end
