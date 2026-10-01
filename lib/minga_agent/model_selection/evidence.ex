defmodule MingaAgent.ModelSelection.Evidence do
  @moduledoc "Minga-owned support evidence for one complete route."
  @enforce_keys [:status, :catalog, :custom]
  defstruct @enforce_keys

  @type t :: %__MODULE__{status: :unverified, catalog: boolean(), custom: boolean()}

  @doc "Builds conservative support evidence."
  @spec new(boolean(), boolean()) :: t()
  def new(catalog, custom) when is_boolean(catalog) and is_boolean(custom) do
    %__MODULE__{status: :unverified, catalog: catalog, custom: custom}
  end
end
