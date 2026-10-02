defmodule MingaAgent.ModelSelection.Evidence do
  @moduledoc "Minga-owned support evidence for one complete route."
  @enforce_keys [:status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{status: :unverified}

  @doc "Builds conservative catalog support evidence."
  @spec new() :: t()
  def new, do: %__MODULE__{status: :unverified}
end
