defmodule MingaAgent.OAuth.ManualReady do
  @moduledoc "Public paste-back instructions for one origin-bound OAuth acquisition."

  alias MingaAgent.Session.ConnectionTarget

  @enforce_keys [:target, :operation_ref, :worker, :flow_ref, :url]
  defstruct [:target, :operation_ref, :worker, :flow_ref, :url]

  @type t :: %__MODULE__{
          target: ConnectionTarget.t(),
          operation_ref: reference(),
          worker: pid(),
          flow_ref: String.t(),
          url: String.t()
        }

  @doc "Creates instructions without retaining PKCE, credentials or redirect input."
  @spec new(ConnectionTarget.t(), reference(), pid(), String.t(), String.t()) :: t()
  def new(target, operation_ref, worker, flow_ref, url) do
    %__MODULE__{
      target: target,
      operation_ref: operation_ref,
      worker: worker,
      flow_ref: flow_ref,
      url: url
    }
  end
end
