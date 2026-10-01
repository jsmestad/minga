defmodule MingaAgent.ModelSelection.Credential.ApiKey do
  @moduledoc "Exact API-key source identity; the key value is never retained."
  @enforce_keys [:provider, :source]
  defstruct @enforce_keys

  @type t :: %__MODULE__{provider: String.t(), source: :env | :file}

  @doc "Pins the provider and source without retaining its secret."
  @spec new(String.t(), :env | :file) :: t()
  def new(provider, source)
      when is_binary(provider) and provider != "" and source in [:env, :file] do
    %__MODULE__{provider: provider, source: source}
  end
end
