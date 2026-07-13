defmodule MingaEditor.Effect.Request do
  @moduledoc """
  Typed scheduler request for one domain-owned slow effect.

  Requests contain data only. Executable closures and document binaries do not
  enter scheduler queues; the domain module named by `handler` owns execution.
  """

  alias MingaEditor.Effect.Policy

  @enforce_keys [:id, :resource, :policy, :handler, :effect]
  defstruct [:id, :resource, :policy, :handler, :effect]

  @typedoc "Stable identity for the mutated or calculated resource."
  @type resource :: term()

  @type t :: %__MODULE__{
          id: reference(),
          resource: resource(),
          policy: Policy.t(),
          handler: module(),
          effect: struct()
        }

  @doc "Builds a scheduler request from a typed domain effect."
  @spec new(struct(), resource(), Policy.t()) :: t()
  def new(%module{} = effect, resource, %Policy{} = policy) do
    %__MODULE__{
      id: make_ref(),
      resource: resource,
      policy: policy,
      handler: module,
      effect: effect
    }
  end

  @doc "Runs the request through its domain handler."
  @spec run(t()) :: {:ok, term()} | {:error, term()}
  def run(%__MODULE__{handler: handler, effect: effect}) do
    handler.run(effect)
  end

  @doc "Combines two queued requests through their shared domain handler."
  @spec coalesce(t(), t()) :: t()
  def coalesce(
        %__MODULE__{handler: handler, effect: older} = old_request,
        %__MODULE__{handler: handler, effect: newer} = new_request
      ) do
    %{new_request | effect: handler.coalesce(older, newer), resource: old_request.resource}
  end
end
