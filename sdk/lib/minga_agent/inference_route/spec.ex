defmodule MingaAgent.InferenceRoute.Spec do
  @moduledoc """
  Source-owned declaration of one contributed model route.

  This is a compile-time stub.
  """

  alias MingaAgent.InferenceRoute.SetupAction

  @enforce_keys [:source, :id, :module, :display_name]
  defstruct [:source, :id, :module, :display_name, setup_action: nil]

  @type source :: {:extension, atom()} | {:bundle, atom()}

  @type t :: %__MODULE__{
          source: source(),
          id: String.t(),
          module: module(),
          display_name: String.t(),
          setup_action: SetupAction.t() | nil
        }
end
