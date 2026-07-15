defmodule MingaEditor.Effect.Request do
  @moduledoc """
  Typed scheduler request for one domain-owned slow effect.

  Requests contain data only. Executable closures and document binaries do not
  enter scheduler queues; the domain module named by `handler` owns execution.
  """

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.Effect.Policy
  alias MingaEditor.State.Operation

  @enforce_keys [:id, :operation_id, :resource, :policy, :handler, :effect]
  defstruct [:id, :operation_id, :resource, :policy, :handler, :effect, :source]

  @typedoc "Scheduler-local request identity."
  @type id :: reference()

  @typedoc "Stable identity for the mutated or calculated resource."
  @type resource :: term()

  @type t :: %__MODULE__{
          id: id(),
          operation_id: Operation.id() | nil,
          resource: resource(),
          policy: Policy.t(),
          handler: module(),
          effect: struct(),
          source: ContributionCleanup.contribution_source() | nil
        }

  @typedoc "Optional request metadata supplied to the scheduler."
  @type option ::
          {:operation_id, Operation.id()}
          | {:source, ContributionCleanup.contribution_source()}

  @doc "Builds a scheduler request for a typed effect and optional metadata."
  @spec new(struct(), resource(), Policy.t(), [option()]) :: t()
  @spec new(struct(), resource(), Policy.t(), Operation.id()) :: t()
  def new(effect, resource, policy, opts \\ [])

  def new(%module{} = effect, resource, %Policy{} = policy, opts) when is_list(opts) do
    build(
      module,
      effect,
      resource,
      policy,
      Keyword.get(opts, :operation_id),
      Keyword.get(opts, :source)
    )
  end

  def new(%module{} = effect, resource, %Policy{} = policy, operation_id)
      when is_integer(operation_id) and operation_id > 0 do
    build(module, effect, resource, policy, operation_id, nil)
  end

  @spec build(
          module(),
          struct(),
          resource(),
          Policy.t(),
          Operation.id() | nil,
          ContributionCleanup.contribution_source() | nil
        ) :: t()
  defp build(module, effect, resource, policy, operation_id, source) do
    %__MODULE__{
      id: make_ref(),
      operation_id: operation_id,
      resource: resource,
      policy: policy,
      handler: module,
      effect: effect,
      source: source
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
