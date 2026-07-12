defmodule Minga.Parser.EventCorrelation do
  @moduledoc """
  Opaque correlation metadata for parser events delivered to editor presentation.

  The generation changes whenever a buffer PID is registered with different parser
  configuration. The version identifies the parse that produced the event.
  """

  @enforce_keys [:generation, :version]
  defstruct [:generation, :version]

  @type generation :: reference()
  @type t :: %__MODULE__{generation: generation(), version: non_neg_integer()}

  @doc "Creates correlation metadata for a registration generation and parse version."
  @spec new(generation(), non_neg_integer()) :: t()
  def new(generation, version) when is_reference(generation) and version >= 0 do
    %__MODULE__{generation: generation, version: version}
  end
end
