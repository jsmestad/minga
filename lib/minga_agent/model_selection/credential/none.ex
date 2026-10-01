defmodule MingaAgent.ModelSelection.Credential.None do
  @moduledoc "Explicit credential-free route identity."
  @enforce_keys [:provider]
  defstruct @enforce_keys

  @type t :: %__MODULE__{provider: String.t()}

  @doc "Declares that this provider route must not resolve credentials."
  @spec new(String.t()) :: t()
  def new(provider) when is_binary(provider) and provider != "" do
    %__MODULE__{provider: provider}
  end
end
