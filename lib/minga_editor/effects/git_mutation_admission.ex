defmodule MingaEditor.Effects.GitMutationAdmission do
  @moduledoc """
  Ordered, nonblocking resolution flow for repository-keyed git mutations.

  Requests resolve repository identity in a supervised worker. Resolution is
  FIFO per Editor generation; applying a resolved candidate admits the typed
  mutation to its actual repository lane before the next resolver starts. This
  preserves dispatch order without running git or filesystem discovery in the
  Editor and still lets mutations for different repositories run concurrently.
  """

  @behaviour MingaEditor.Effect

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.Feedback, as: EffectFeedback
  alias MingaEditor.Effects.GitMutation
  alias MingaEditor.GitRepositoryIdentity
  alias MingaEditor.GitRepositoryResolver
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Operation

  @max_queued 16

  @enforce_keys [
    :scheduler,
    :operation_id,
    :resolver,
    :resolver_input,
    :operation,
    :pending_message,
    :success_message
  ]
  defstruct [
    :scheduler,
    :operation_id,
    :resolver,
    :resolver_input,
    :operation,
    :pending_message,
    :success_message,
    :path,
    :message,
    amend?: false
  ]

  @type t :: %__MODULE__{
          scheduler: GenServer.server(),
          operation_id: Operation.id(),
          resolver: module(),
          resolver_input: GitRepositoryResolver.input(),
          operation: GitMutation.operation(),
          pending_message: String.t(),
          success_message: String.t(),
          path: String.t() | nil,
          message: String.t() | nil,
          amend?: boolean()
        }

  @doc "Builds a generation-ordered repository resolution request."
  @spec request(GenServer.server(), GitMutation.operation(), Operation.id(), keyword()) ::
          Request.t()
  def request(scheduler, operation, operation_id, opts)
      when operation in [:stage, :unstage, :discard, :stage_all, :unstage_all, :commit] do
    effect = %__MODULE__{
      scheduler: scheduler,
      operation_id: operation_id,
      resolver: Keyword.get(opts, :resolver, GitRepositoryResolver),
      resolver_input: Keyword.get(opts, :resolver_input, :current_project),
      operation: operation,
      pending_message: Keyword.fetch!(opts, :pending_message),
      success_message: Keyword.fetch!(opts, :success_message),
      path: Keyword.get(opts, :path),
      message: Keyword.get(opts, :message),
      amend?: Keyword.get(opts, :amend?, false)
    }

    Request.new(
      effect,
      {:git_repository_resolution, scheduler},
      Policy.fifo(@max_queued),
      operation_id: operation_id,
      activity: :git_syncing
    )
  end

  @impl true
  @spec run(t()) :: {:ok, Request.t()} | {:error, term()}
  def run(%__MODULE__{} = effect) do
    case effect.resolver.resolve(effect.resolver_input) do
      {:ok, %GitRepositoryIdentity{} = identity} ->
        {:ok, mutation_request(effect, identity, effect.operation_id)}

      :not_git ->
        {:error, :not_git}

      {:error, reason} ->
        {:error, {:resolution_failed, reason}}
    end
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{}, %__MODULE__{} = newer), do: newer

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{
          value: {:queued, queue},
          request: %{operation_id: id, effect: effect}
        } = outcome
      ) do
    message = "Queued: #{effect.pending_message}"

    {EffectFeedback.queued(state, id, message, queue), outcome}
  end

  def apply(
        state,
        %Outcome{value: :running, request: %{operation_id: id, effect: effect}} = outcome
      ) do
    {EffectFeedback.running(state, id, effect.pending_message), outcome}
  end

  def apply(state, %Outcome{value: {:completed, %Request{} = request}} = outcome) do
    case EffectScheduler.finalize_and_schedule(state.effect_scheduler, outcome, request) do
      {:ok, _request_id, :running} ->
        {state, outcome}

      {:ok, _request_id, :queued} ->
        {state, outcome}

      {:error, reason} ->
        message = admission_error_message(reason)

        state = EffectFeedback.finished(state, outcome.request.operation_id, :error, message)

        {state, Outcome.failed(outcome.request, reason)}
    end
  end

  def apply(
        state,
        %Outcome{value: {:failed, :not_git}, request: %{operation_id: id}} = outcome
      ) do
    {EffectFeedback.finished(state, id, :error, "Not in a git repository"), outcome}
  end

  def apply(
        state,
        %Outcome{value: {:failed, :timeout}, request: %{operation_id: id}} = outcome
      ) do
    {EffectFeedback.finished(state, id, :timeout, "Git repository resolution timed out"), outcome}
  end

  def apply(
        state,
        %Outcome{value: {:failed, reason}, request: %{operation_id: id}} = outcome
      ) do
    message = "Git repository resolution failed: #{inspect(reason)}"
    Minga.Log.error(:editor, message)

    {EffectFeedback.finished(state, id, :error, message), outcome}
  end

  def apply(state, %Outcome{value: {:canceled, _reason}, request: %{operation_id: id}} = outcome) do
    {EffectFeedback.finished(state, id, :canceled, "Git action canceled"), outcome}
  end

  def apply(state, %Outcome{value: {:stale, _reason}, request: %{operation_id: id}} = outcome) do
    {EffectFeedback.finished(state, id, :stale, "Git action skipped"), outcome}
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec mutation_request(t(), GitRepositoryIdentity.t(), Operation.id()) :: Request.t()
  defp mutation_request(effect, identity, operation_id) do
    opts =
      [
        pending_message: effect.pending_message,
        success_message: effect.success_message,
        message: effect.message,
        amend?: effect.amend?
      ]
      |> maybe_put_relative_path(effect.path, identity)

    GitMutation.request(identity.git_root, effect.operation, operation_id, opts)
  end

  @spec maybe_put_relative_path(keyword(), String.t() | nil, GitRepositoryIdentity.t()) ::
          keyword()
  defp maybe_put_relative_path(opts, nil, _identity), do: opts

  defp maybe_put_relative_path(opts, path, identity) do
    base = path_base(identity)
    relative_path = base |> Path.join(path) |> Path.relative_to(identity.git_root)
    Keyword.put(opts, :path, relative_path)
  end

  @spec path_base(GitRepositoryIdentity.t()) :: String.t()
  defp path_base(%GitRepositoryIdentity{git_root: git_root, source_root: source_root}) do
    if source_root == git_root or String.starts_with?(source_root, git_root <> "/") do
      source_root
    else
      git_root
    end
  end

  @spec admission_error_message(EffectScheduler.admission_error() | :not_found) :: String.t()
  defp admission_error_message(:queue_full), do: "Git action queue is full"
  defp admission_error_message(:scheduler_full), do: "Git effect scheduler is full"
  defp admission_error_message(reason), do: "Git action not scheduled: #{reason}"
end
