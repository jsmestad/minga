defmodule MingaEditor.Effects.GitMutation do
  @moduledoc """
  Typed, bounded FIFO effect for mutations of one actual git repository.

  The expanded repository root is both execution input and scheduler resource
  identity, so separate repositories remain concurrent while `.git/index`
  mutations for one repository retain request order.
  """

  @behaviour MingaEditor.Effect

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Effects.GitMutationResult
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationFeedback

  @max_queued 16

  @type operation :: :stage | :unstage | :discard | :stage_all | :unstage_all | :commit

  @enforce_keys [:git_root, :operation, :pending_message, :success_message]
  defstruct [
    :git_root,
    :operation,
    :pending_message,
    :success_message,
    :path,
    :message,
    amend?: false
  ]

  @type t :: %__MODULE__{
          git_root: String.t(),
          operation: operation(),
          pending_message: String.t(),
          success_message: String.t(),
          path: String.t() | nil,
          message: String.t() | nil,
          amend?: boolean()
        }

  @doc "Builds a bounded FIFO scheduler request keyed by the actual repository."
  @spec request(String.t(), operation(), Operation.id(), keyword()) :: Request.t()
  def request(git_root, operation, operation_id, opts)
      when is_binary(git_root) and
             operation in [:stage, :unstage, :discard, :stage_all, :unstage_all, :commit] do
    effect = %__MODULE__{
      git_root: Path.expand(git_root),
      operation: operation,
      pending_message: Keyword.fetch!(opts, :pending_message),
      success_message: Keyword.fetch!(opts, :success_message),
      path: Keyword.get(opts, :path),
      message: Keyword.get(opts, :message),
      amend?: Keyword.get(opts, :amend?, false)
    }

    Request.new(
      effect,
      {:git_repository, effect.git_root},
      Policy.fifo(@max_queued),
      operation_id: operation_id,
      activity: :git_syncing
    )
  end

  @impl true
  @spec run(t()) :: {:ok, GitMutationResult.t()} | {:error, GitMutationResult.t()}
  def run(%__MODULE__{} = effect) do
    result =
      Minga.Telemetry.span(
        [:minga, :git, :worktree_action],
        %{git_root: effect.git_root},
        fn -> perform(effect) end
      )

    normalize_result(effect, result)
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(%__MODULE__{}, %__MODULE__{} = newer), do: newer

  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        state,
        %Outcome{
          status: :queued,
          request: %{operation_id: id, effect: effect},
          queue_position: position,
          queue_total: total
        } = outcome
      ) do
    message = "Queued: #{effect.pending_message}"

    {:ok, operation_feedback} =
      OperationFeedback.queued(state.feedback.operation_feedback, id, message, position, total)

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    {state, outcome}
  end

  def apply(
        state,
        %Outcome{status: :running, request: %{operation_id: id, effect: effect}} = outcome
      ) do
    operation_feedback =
      OperationFeedback.running(state.feedback.operation_feedback, id, effect.pending_message)

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)
    }

    {state, outcome}
  end

  def apply(
        state,
        %Outcome{
          status: :completed,
          request: %{operation_id: id},
          result: %GitMutationResult{} = result
        } =
          outcome
      ) do
    MingaEditor.refresh_git_repo(result.git_root)

    {%{
       state
       | feedback:
           Feedback.accept_operation_feedback(
             state.feedback,
             OperationFeedback.finish(
               state.feedback.operation_feedback,
               id,
               :success,
               result.message
             )
           )
     }, outcome}
  end

  def apply(
        state,
        %Outcome{status: :failed, request: %{operation_id: id, effect: effect}, reason: :timeout} =
          outcome
      ) do
    MingaEditor.refresh_git_repo(effect.git_root)

    {%{
       state
       | feedback:
           Feedback.accept_operation_feedback(
             state.feedback,
             OperationFeedback.finish(
               state.feedback.operation_feedback,
               id,
               :timeout,
               "Git action timed out"
             )
           )
     }, outcome}
  end

  def apply(
        state,
        %Outcome{status: :failed, request: %{operation_id: id, effect: effect}, reason: reason} =
          outcome
      ) do
    MingaEditor.refresh_git_repo(effect.git_root)
    message = failure_message(reason)
    Minga.Log.error(:editor, message)

    {%{
       state
       | feedback:
           Feedback.accept_operation_feedback(
             state.feedback,
             OperationFeedback.finish(state.feedback.operation_feedback, id, :error, message)
           )
     }, outcome}
  end

  def apply(
        state,
        %Outcome{status: :canceled, request: %{operation_id: id}, reason: reason} = outcome
      )
      when reason in [:superseded, :coalesced] do
    {%{
       state
       | feedback:
           Feedback.accept_operation_feedback(
             state.feedback,
             OperationFeedback.finish(
               state.feedback.operation_feedback,
               id,
               :stale,
               "Git action skipped"
             )
           )
     }, outcome}
  end

  def apply(state, %Outcome{status: :canceled, request: %{operation_id: id}} = outcome) do
    {%{
       state
       | feedback:
           Feedback.accept_operation_feedback(
             state.feedback,
             OperationFeedback.finish(
               state.feedback.operation_feedback,
               id,
               :canceled,
               "Git action canceled"
             )
           )
     }, outcome}
  end

  def apply(state, %Outcome{status: :stale, request: %{operation_id: id}} = outcome) do
    {%{
       state
       | feedback:
           Feedback.accept_operation_feedback(
             state.feedback,
             OperationFeedback.finish(
               state.feedback.operation_feedback,
               id,
               :stale,
               "Git action skipped"
             )
           )
     }, outcome}
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec perform(t()) :: :ok | {:ok, String.t()} | {:error, term()}
  defp perform(%__MODULE__{operation: :stage, git_root: root, path: path}) do
    Minga.Git.stage(root, path)
  end

  defp perform(%__MODULE__{operation: :unstage, git_root: root, path: path}) do
    Minga.Git.unstage(root, path)
  end

  defp perform(%__MODULE__{operation: :discard, git_root: root, path: path}) do
    Minga.Git.discard(root, path)
  end

  defp perform(%__MODULE__{operation: :stage_all, git_root: root}) do
    Minga.Git.stage(root, ".")
  end

  defp perform(%__MODULE__{operation: :unstage_all, git_root: root}) do
    Minga.Git.unstage_all(root)
  end

  defp perform(%__MODULE__{operation: :commit, git_root: root, message: message, amend?: amend?}) do
    opts = if amend?, do: [amend: true], else: []
    Minga.Git.commit(root, message, opts)
  end

  @spec normalize_result(t(), :ok | {:ok, String.t()} | {:error, term()}) ::
          {:ok, GitMutationResult.t()} | {:error, GitMutationResult.t()}
  defp normalize_result(effect, :ok) do
    {:ok, GitMutationResult.new(effect.git_root, effect.success_message)}
  end

  defp normalize_result(%__MODULE__{operation: :commit} = effect, {:ok, hash}) do
    action = if effect.amend?, do: "Amended", else: "Committed"
    {:ok, GitMutationResult.new(effect.git_root, "#{action} #{hash}")}
  end

  defp normalize_result(effect, {:ok, dynamic_message}) do
    {:ok, GitMutationResult.new(effect.git_root, dynamic_message)}
  end

  defp normalize_result(effect, {:error, reason}) do
    message = mutation_failure_message(effect, reason)
    {:error, GitMutationResult.new(effect.git_root, message, reason)}
  end

  @spec mutation_failure_message(t(), term()) :: String.t()
  defp mutation_failure_message(%__MODULE__{operation: :commit, amend?: true}, reason) do
    "Amend failed: #{reason}"
  end

  defp mutation_failure_message(%__MODULE__{operation: :commit}, reason) do
    "Commit failed: #{reason}"
  end

  defp mutation_failure_message(_effect, reason), do: "Git error: #{reason}"

  @spec failure_message(term()) :: String.t()
  defp failure_message(%GitMutationResult{message: message}), do: message
  defp failure_message({:worker_exit, reason}), do: "Git worker failed: #{inspect(reason)}"

  defp failure_message({:start_failed, reason}),
    do: "Git worker failed to start: #{inspect(reason)}"

  defp failure_message(reason), do: "Git error: #{inspect(reason)}"
end
