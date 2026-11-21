defmodule MingaAgent.InferenceRoute.Spec do
  @moduledoc """
  Source-owned declaration of one contributed model route. `short_name` is the optional name used inside sentences, such as "Claude"; without it, sentences use `display_name`.

  This is a compile-time stub.
  """

  alias MingaAgent.InferenceRoute.SetupAction

  @enforce_keys [:source, :id, :module, :display_name]
  defstruct [:source, :id, :module, :display_name, short_name: nil, setup_action: nil]

  @type source :: {:extension, atom()} | {:bundle, atom()}

  @type t :: %__MODULE__{
          source: source(),
          id: String.t(),
          module: module(),
          display_name: String.t(),
          short_name: String.t() | nil,
          setup_action: SetupAction.t() | nil
        }
end
