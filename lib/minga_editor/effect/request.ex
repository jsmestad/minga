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
  defstruct [
    :id,
    :operation_id,
    :resource,
    :policy,
    :handler,
    :effect,
    :source,
    :timeout_ms,
    :activity
  ]

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
          source: ContributionCleanup.contribution_source() | nil,
          timeout_ms: pos_integer() | nil,
          activity: atom() | nil
        }

  @typedoc "Optional request metadata supplied to the scheduler."
  @type option ::
          {:operation_id, Operation.id()}
          | {:source, ContributionCleanup.contribution_source() | nil}
          | {:timeout_ms, pos_integer()}
          | {:activity, atom()}

  @doc "Builds a scheduler request for a typed effect and optional metadata."
  @spec new(struct(), resource(), Policy.t(), [option()] | Operation.id()) :: t()
  def new(effect, resource, policy, opts \\ [])

  def new(%module{} = effect, resource, %Policy{} = policy, opts) when is_list(opts) do
    build(
      module,
      effect,
      resource,
      policy,
      Keyword.get(opts, :operation_id),
      Keyword.get(opts, :source),
      Keyword.get(opts, :timeout_ms),
      Keyword.get(opts, :activity)
    )
  end

  def new(%module{} = effect, resource, %Policy{} = policy, operation_id)
      when is_integer(operation_id) and operation_id > 0 do
    build(module, effect, resource, policy, operation_id, nil, nil, nil)
  end

  @spec build(
          module(),
          struct(),
          resource(),
          Policy.t(),
          Operation.id() | nil,
          ContributionCleanup.contribution_source() | nil,
          pos_integer() | nil,
          atom() | nil
        ) :: t()
  defp build(module, effect, resource, policy, operation_id, source, timeout_ms, activity) do
    %__MODULE__{
      id: make_ref(),
      operation_id: operation_id,
      resource: resource,
      policy: policy,
      handler: module,
      effect: effect,
      source: source,
      timeout_ms: validate_timeout(timeout_ms),
      activity: validate_activity(activity)
    }
  end

  @spec validate_timeout(pos_integer() | nil) :: pos_integer() | nil
  defp validate_timeout(nil), do: nil
  defp validate_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0, do: timeout_ms

  defp validate_timeout(timeout_ms),
    do: raise(ArgumentError, "timeout_ms must be a positive integer, got: #{inspect(timeout_ms)}")

  @spec validate_activity(atom() | nil) :: atom() | nil
  defp validate_activity(nil), do: nil
  defp validate_activity(activity) when is_atom(activity), do: activity

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
    chosen_effect =
      if function_exported?(handler, :coalesce, 2),
        do: handler.coalesce(older, newer),
        else: newer

    %{new_request | effect: chosen_effect, resource: old_request.resource}
  end
end
