defmodule MingaAgent.ArtifactStore.Fetched do
  @moduledoc "An exact bounded slice fetched from a durable retained artifact."

  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference

  @type t :: %__MODULE__{
          bytes: binary(),
          selection: Range.t(),
          reference: Reference.t(),
          capture: Output.capture_status()
        }

  @enforce_keys [:bytes, :selection, :reference, :capture]
  defstruct [:bytes, :selection, :reference, :capture]

  @doc false
  @spec new(binary(), Range.t(), Reference.t(), Output.capture_status()) :: t()
  def new(bytes, %Range{} = selection, %Reference{} = reference, capture)
      when is_binary(bytes),
      do: %__MODULE__{bytes: bytes, selection: selection, reference: reference, capture: capture}
end
