defmodule MingaAgent.ModelSelection.Stored do
  @moduledoc "Decoded persisted selection data that cannot be executed directly."
  @enforce_keys [:backend_id, :route, :credential, :policy, :evidence]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          backend_id: String.t(),
          route: MingaAgent.ModelSelection.Route.t(),
          credential: MingaAgent.ModelSelection.credential_ref(),
          policy: MingaAgent.ModelSelection.Policy.t(),
          evidence: MingaAgent.ModelSelection.Evidence.t()
        }

  @doc "Retains validated selection data without an executable request model."
  @spec new(
          String.t(),
          MingaAgent.ModelSelection.Route.t(),
          MingaAgent.ModelSelection.credential_ref(),
          MingaAgent.ModelSelection.Policy.t(),
          MingaAgent.ModelSelection.Evidence.t()
        ) :: t()
  def new(backend_id, route, credential, policy, evidence)
      when is_binary(backend_id) and backend_id != "" do
    %__MODULE__{
      backend_id: backend_id,
      route: route,
      credential: credential,
      policy: policy,
      evidence: evidence
    }
  end
end
