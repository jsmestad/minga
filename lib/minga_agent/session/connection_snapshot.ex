defmodule MingaAgent.Session.ConnectionSnapshot do
  @moduledoc """
  Secret-free connection facts derived from Session's existing authorities.

  Configured means local credential availability, not remote authentication.
  Running means an attached provider, not a completed or verified user task.
  Construction and presentation perform no I/O.
  """

  alias MingaAgent.Credentials
  alias MingaAgent.Event
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelSelection
  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.Session.ProviderLifecycle

  @type problem ::
          {:resolution, ModelResolver.resolution_error()}
          | {:provider, Event.Error.kind() | :startup_failed}
  @type operation :: :idle | {:connecting, reference()}
  @type presentation ::
          :unconfigured
          | :checking
          | :connecting
          | :ready
          | :unsupported
          | :credential_failure
          | :provider_failure
  @type t :: %__MODULE__{
          target: ConnectionTarget.t(),
          conversation: reference() | nil,
          credential_readiness: Credentials.readiness(),
          model_selection: ModelSelection.t() | nil,
          provider_phase: :stopped | :starting | :running | :retrying | :terminal_failure,
          operation: operation(),
          problem: problem() | nil,
          persistent_drafts?: boolean(),
          remote_composer_drafts?: boolean()
        }

  @enforce_keys [
    :target,
    :credential_readiness,
    :model_selection,
    :provider_phase,
    :operation,
    :problem
  ]
  defstruct [
    :target,
    :conversation,
    :credential_readiness,
    :model_selection,
    :provider_phase,
    :operation,
    :problem,
    persistent_drafts?: false,
    remote_composer_drafts?: false
  ]

  @doc "Identifies this live conversation instance independently of model selection."
  @spec project_conversation(t(), reference()) :: t()
  def project_conversation(%__MODULE__{} = snapshot, conversation),
    do: %{snapshot | conversation: conversation}

  @doc "Projects already-owned facts without discovery or credential acquisition."
  @spec new(
          ConnectionTarget.t(),
          Credentials.readiness(),
          ModelSelection.t() | nil,
          ProviderLifecycle.t(),
          operation(),
          problem() | nil
        ) :: t()
  def new(target, readiness, selection, provider, operation, problem) do
    %__MODULE__{
      target: target,
      credential_readiness: readiness,
      model_selection: selection,
      provider_phase: ProviderLifecycle.phase(provider),
      operation: operation,
      problem: problem
    }
  end

  @doc "Projects whether this Session can durably save composer presentation."
  @spec project_draft_persistence(t(), boolean()) :: t()
  def project_draft_persistence(%__MODULE__{} = snapshot, enabled?) when is_boolean(enabled?),
    do: %{snapshot | persistent_drafts?: enabled?, remote_composer_drafts?: enabled?}

  @doc "Returns canonical presentation; idle turn status is never connection evidence."
  @spec status(t()) :: presentation()
  def status(%__MODULE__{credential_readiness: :checking}), do: :checking
  def status(%__MODULE__{operation: {:connecting, _operation_ref}}), do: :connecting

  def status(%__MODULE__{problem: {:resolution, {:credential_unavailable, _}}}),
    do: :credential_failure

  def status(%__MODULE__{problem: {:resolution, :no_available_model}}), do: :unconfigured
  def status(%__MODULE__{problem: {:resolution, _}}), do: :unsupported
  def status(%__MODULE__{problem: {:provider, :auth_failed}}), do: :credential_failure
  def status(%__MODULE__{problem: {:provider, _}}), do: :provider_failure

  def status(%__MODULE__{provider_phase: phase}) when phase in [:starting, :retrying],
    do: :connecting

  def status(%__MODULE__{provider_phase: :terminal_failure}), do: :provider_failure

  def status(%__MODULE__{credential_readiness: :configured, provider_phase: :running}),
    do: :ready

  def status(%__MODULE__{credential_readiness: :configured}), do: :connecting
  def status(%__MODULE__{}), do: :unconfigured

  @doc "Returns the session's explanation when it could not resolve a model, otherwise nil."
  @spec resolution_message(t()) :: String.t() | nil
  def resolution_message(%__MODULE__{model_selection: nil, problem: {:resolution, reason}}),
    do: ModelResolver.message(reason)

  def resolution_message(%__MODULE__{}), do: nil
end
