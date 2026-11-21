defmodule MingaAgent.InferenceRoute.Spec do
  @moduledoc """
  Source-owned declaration of one contributed model route.

  This is a compile-time stub.
  """

  @enforce_keys [:source, :id, :module, :display_name]
  defstruct @enforce_keys

  @type source :: {:extension, atom()} | {:bundle, atom()}

  @type t :: %__MODULE__{
          source: source(),
          id: String.t(),
          module: module(),
          display_name: String.t()
        }
end
