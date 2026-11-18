defmodule MingaAgent.Session.Connection do
  @moduledoc """
  Owns the nonpersistent target epoch and one explicitly requested setup operation.

  This is not a readiness lifecycle. Resolver and provider facts are retained only
  to preserve their structured kinds for the derived public snapshot. Transitions
  are pure; Session owns monitoring, cancellation delivery and credential effects.
  """

  alias MingaAgent.Event
  alias MingaAgent.ModelResolver
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget

  @type method :: {:api_key, String.t()} | :oauth_browser | :oauth_manual
  @type dependency :: {pid(), reference()}
  @type notification :: {pid(), term()} | nil
  @type admission :: {dependency(), notification()}
  @type operation ::
          :none
          | {:pending, reference(), ConnectionTarget.t(), method(), admission(),
             dependency() | nil}
          | {:cancelled, reference(), ConnectionTarget.t()}
          | {:committed, reference(), ConnectionTarget.t()}
          | {:failed, reference(), ConnectionTarget.t()}
  @type refusal ::
          :stale_target
          | :superseded
          | :cancelled
          | :already_committed
          | :method_mismatch
          | :worker_already_registered
          | :credential_store_failed

  @type t :: %__MODULE__{
          epoch: reference(),
          operation: operation(),
          resolver_problem: ModelResolver.resolution_error() | nil,
          provider_problem: Event.Error.kind() | :startup_failed | nil,
          published: ConnectionSnapshot.t() | nil
        }

  @enforce_keys [:epoch]
  defstruct [:epoch, :resolver_problem, :provider_problem, :published, operation: :none]

  @doc "Creates an isolated live target generation."
  @spec new(ModelResolver.resolution_error() | nil) :: t()
  def new(problem \\ nil), do: %__MODULE__{epoch: make_ref(), resolver_problem: problem}

  @doc "Invalidates a committed conversation replacement, including old commit receipts."
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{operation: {:pending, ref, target, _, _, _}} = connection),
    do: %{connection | epoch: make_ref(), operation: {:cancelled, ref, target}}

  def invalidate(%__MODULE__{operation: {:committed, _, _}} = connection),
    do: %{connection | epoch: make_ref(), operation: :none}

  def invalidate(%__MODULE__{} = connection), do: %{connection | epoch: make_ref()}

  @doc "Changes selection generation without losing a successful writer receipt."
  @spec selection_changed(t()) :: t()
  def selection_changed(%__MODULE__{operation: {:committed, _, _}} = connection),
    do: %{connection | epoch: make_ref()}

  def selection_changed(%__MODULE__{} = connection), do: invalidate(connection)

  @doc "Admits a new operation after the caller has validated its method and target."
  @spec begin(t(), ConnectionTarget.t(), method(), dependency(), notification()) ::
          {:ok, t(), reference()}
  def begin(%__MODULE__{} = connection, target, method, owner, notify \\ nil) do
    ref = make_ref()
    {:ok, %{connection | operation: {:pending, ref, target, method, {owner, notify}, nil}}, ref}
  end

  @doc "Checks the exact operation receipt and then the current target."
  @spec authorize(t(), ConnectionTarget.t(), reference(), ConnectionTarget.t()) ::
          :ok | {:error, refusal()}
  def authorize(%__MODULE__{operation: {:committed, ref, target}}, target, ref, _current),
    do: {:error, :already_committed}

  def authorize(%__MODULE__{operation: {:cancelled, ref, target}}, target, ref, current)
      when target == current, do: {:error, :cancelled}

  def authorize(%__MODULE__{operation: {:failed, ref, target}}, target, ref, current)
      when target == current, do: {:error, :credential_store_failed}

  def authorize(%__MODULE__{operation: {:pending, ref, target, _, _, _}}, target, ref, target),
    do: :ok

  def authorize(%__MODULE__{}, target, _ref, current) when target != current,
    do: {:error, :stale_target}

  def authorize(%__MODULE__{}, _target, _ref, _current), do: {:error, :superseded}

  @doc "Checks the credential writer against the method that was admitted."
  @spec match_method(t(), method() | :oauth) :: :ok | {:error, :method_mismatch}
  def match_method(%__MODULE__{operation: {:pending, _, _, method, _, _}}, :oauth)
      when method in [:oauth_browser, :oauth_manual],
      do: :ok

  def match_method(%__MODULE__{operation: {:pending, _, _, method, _, _}}, method), do: :ok
  def match_method(%__MODULE__{}, _method), do: {:error, :method_mismatch}

  @doc "Binds acquisition once, never replacing an already owned worker."
  @spec register_worker(t(), dependency()) :: {:ok, t()} | {:error, :worker_already_registered}
  def register_worker(
        %__MODULE__{operation: {:pending, ref, target, method, owner, nil}} = c,
        worker
      ),
      do: {:ok, %{c | operation: {:pending, ref, target, method, owner, worker}}}

  def register_worker(%__MODULE__{}, _worker), do: {:error, :worker_already_registered}
  @doc "Cancels admitted work; receipts distinguish cancellation from persistence."
  @spec cancel(t()) :: {:cancelled, t()} | {:error, refusal()}
  def cancel(%__MODULE__{operation: {:pending, ref, target, _, _, _}} = c),
    do: {:cancelled, %{c | operation: {:cancelled, ref, target}}}

  def cancel(%__MODULE__{operation: {:committed, _, _}}), do: {:error, :already_committed}
  def cancel(%__MODULE__{operation: {:cancelled, _, _}}), do: {:error, :cancelled}
  def cancel(%__MODULE__{operation: {:failed, _, _}}), do: {:error, :credential_store_failed}
  def cancel(%__MODULE__{operation: :none}), do: {:error, :superseded}

  @doc "Retains a secret-free receipt only after the credential writer succeeds."
  @spec committed(t()) :: {:committed, t()} | {:error, refusal()}
  def committed(%__MODULE__{operation: {:pending, ref, target, _, _, _}} = c),
    do: {:committed, %{c | operation: {:committed, ref, target}, provider_problem: nil}}

  def committed(%__MODULE__{operation: {:committed, _, _}}), do: {:error, :already_committed}
  def committed(%__MODULE__{operation: {:cancelled, _, _}}), do: {:error, :cancelled}
  def committed(%__MODULE__{operation: {:failed, _, _}}), do: {:error, :credential_store_failed}
  def committed(%__MODULE__{operation: :none}), do: {:error, :superseded}

  @doc "Retires a failed writer without retaining its material or error text."
  @spec failed(t()) :: {:failed, t()} | {:error, refusal()}
  def failed(%__MODULE__{operation: {:pending, ref, target, _, _, _}} = c),
    do: {:failed, %{c | operation: {:failed, ref, target}}}

  def failed(%__MODULE__{operation: {:committed, _, _}}), do: {:error, :already_committed}
  def failed(%__MODULE__{operation: {:cancelled, _, _}}), do: {:error, :cancelled}
  def failed(%__MODULE__{operation: {:failed, _, _}}), do: {:error, :credential_store_failed}
  def failed(%__MODULE__{operation: :none}), do: {:error, :superseded}

  @doc "Matches dependency death by both monitor and PID."
  @spec dependency_down(t(), dependency()) :: {:cancelled, t()} | :unrelated
  def dependency_down(
        %__MODULE__{operation: {:pending, _, _, _, {owner, _}, worker}} = c,
        dependency
      )
      when dependency == owner or dependency == worker, do: cancel(c)

  def dependency_down(%__MODULE__{}, _dependency), do: :unrelated

  @doc "Returns the captured operation identity and exact dependencies for cleanup."
  @spec pending(t()) ::
          {reference(), ConnectionTarget.t(), method(), admission(), dependency() | nil} | nil
  def pending(%__MODULE__{operation: {:pending, ref, target, method, owner, worker}}),
    do: {ref, target, method, owner, worker}

  def pending(%__MODULE__{}), do: nil

  @doc "Projects exact setup identity without worker, owner or acquisition material."
  @spec activity(t()) :: ConnectionSnapshot.operation()
  def activity(%__MODULE__{operation: {:pending, ref, _, _, _, _}}), do: {:connecting, ref}
  def activity(%__MODULE__{}), do: :idle

  @doc "Retains typed resolver facts, never reverse-engineering display strings."
  @spec resolved(t(), ModelResolver.resolution_error() | nil) :: t()
  def resolved(%__MODULE__{} = c, problem), do: %{c | resolver_problem: problem}

  @doc "Retains only connection-relevant provider kinds, not ordinary tool/turn errors."
  @spec provider_failed(t(), Event.Error.kind() | :startup_failed) :: t()
  def provider_failed(%__MODULE__{} = c, kind)
      when kind in [
             :auth_failed,
             :rate_limited,
             :unreachable,
             :invalid_model,
             :provider_error,
             :startup_failed
           ],
      do: %{c | provider_problem: kind}

  def provider_failed(%__MODULE__{} = c, _kind), do: c

  @doc "Clears the old provider problem after successful attachment or explicit retry."
  @spec provider_recovered(t()) :: t()
  def provider_recovered(%__MODULE__{} = c), do: %{c | provider_problem: nil}

  @doc "Projects the retained structured connection problem."
  @spec problem(t()) :: ConnectionSnapshot.problem() | nil
  def problem(%__MODULE__{resolver_problem: reason}) when reason != nil,
    do: {:resolution, reason}

  def problem(%__MODULE__{provider_problem: kind}) when kind != nil, do: {:provider, kind}
  def problem(%__MODULE__{}), do: nil

  @doc "Remembers the last emitted derived value to avoid duplicate change events."
  @spec published(t(), ConnectionSnapshot.t()) :: t()
  def published(%__MODULE__{} = c, snapshot), do: %{c | published: snapshot}
end
