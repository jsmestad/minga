defmodule MingaGitPorcelain.Effects.RemoteOperation do
  @moduledoc "Typed scheduler effect for one Git Porcelain remote operation."

  @behaviour MingaEditor.Effect

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Shell.Traditional.GitToastWorkflow
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias Minga.Git

  @source {:extension, :minga_git_porcelain}
  @timeout_ms 120_000
  @pull_retry_markers [
    "non-fast-forward",
    "fetch first",
    "remote contains work",
    "tip of your current branch is behind"
  ]

  @type operation :: :push | :pull | :fetch | :pull_and_retry
  @type source :: CallbackInvoker.source()

  @enforce_keys [:operation, :git_root, :source, :git, :admission, :refresher]
  defstruct [:operation, :git_root, :source, :git, :admission, :refresher]

  @type t :: %__MODULE__{
          operation: operation(),
          git_root: String.t(),
          source: source(),
          git: module(),
          admission: GenServer.server(),
          refresher: module()
        }

  @doc "Builds a single-slot FIFO remote request."
  @spec request(String.t(), operation(), keyword()) :: Request.t()
  def request(git_root, operation, opts \\ [])
      when is_binary(git_root) and operation in [:push, :pull, :fetch, :pull_and_retry] do
    {:extension, _name} = source = Keyword.get(opts, :source, @source)

    effect = %__MODULE__{
      operation: operation,
      git_root: Path.expand(git_root),
      source: source,
      git: Keyword.get(opts, :git, Git),
      admission: Keyword.get(opts, :admission, CodeLease),
      refresher: Keyword.get(opts, :refresher, MingaEditor)
    }

    Request.new(effect, {:git_porcelain_remote, source}, Policy.fifo(0),
      source: source,
      timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms),
      activity: :git_syncing
    )
  end

  @doc "Runs remote work through the extension callback trust boundary."
  @impl true
  @spec run(t()) :: :ok | {:error, term()}
  def run(%__MODULE__{source: source, admission: admission} = effect) do
    case CallbackInvoker.invoke(
           source,
           __MODULE__,
           :execute,
           [effect],
           :effect_execution,
           admission
         ) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, _reason} = error} ->
        error

      {:ok, returned} ->
        {:error, CallbackInvoker.invalid_return(source, __MODULE__, :execute, returned)}

      {:error, failure} ->
        {:error, failure}
    end
  end

  @doc false
  @spec execute(t()) :: :ok | {:error, term()}
  def execute(%__MODULE__{} = effect), do: perform(effect)

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(_older, newer), do: newer

  @doc "Applies remote feedback, refreshes the repository, and offers retry recovery."
  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{status: :running, request: %{effect: effect}} = outcome) do
    state = GitToastWorkflow.dismiss(state)
    {publish_notice(state, progress_message(effect.operation)), outcome}
  end

  def apply(
        state,
        %Outcome{status: :completed, request: %{effect: effect}, result: :ok} = outcome
      ) do
    refresh_repo(effect)
    message = success_message(effect.operation)

    state =
      state
      |> publish_notice(message)
      |> publish_toast(message, :success, nil)

    {state, outcome}
  end

  def apply(
        state,
        %Outcome{status: :failed, request: %{effect: effect}, reason: reason} = outcome
      ) do
    refresh_repo(effect)
    message = failure_message(effect.operation, reason)
    action = retry_action(effect.operation, reason)
    Minga.Log.warning(:ext, message)

    state = publish_notice(state, message)
    {publish_toast(state, message, :error, action), outcome}
  end

  def apply(state, %Outcome{status: :canceled, reason: :source_canceled} = outcome),
    do: {state, outcome}

  def apply(state, %Outcome{status: :canceled, request: %{effect: effect}} = outcome) do
    refresh_repo(effect)
    message = "Git operation canceled"

    state =
      state
      |> publish_notice(message)
      |> publish_toast(message, :error, nil)

    {state, outcome}
  end

  def apply(state, %Outcome{status: :stale} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec perform(t()) :: :ok | {:error, term()}
  defp perform(%__MODULE__{operation: :push, git_root: root, git: git}), do: git.push(root)
  defp perform(%__MODULE__{operation: :pull, git_root: root, git: git}), do: git.pull(root)

  defp perform(%__MODULE__{operation: :fetch, git_root: root, git: git}),
    do: git.fetch_remotes(root)

  defp perform(%__MODULE__{operation: :pull_and_retry, git_root: root, git: git}) do
    case git.pull(root) do
      :ok -> git.push(root)
      {:error, reason} -> {:error, "pull failed: #{reason}"}
    end
  end

  @spec progress_message(operation()) :: String.t()
  defp progress_message(:push), do: "Pushing…"
  defp progress_message(:pull), do: "Pulling…"
  defp progress_message(:fetch), do: "Fetching…"
  defp progress_message(:pull_and_retry), do: "Pulling and retrying…"

  @spec success_message(operation()) :: String.t()
  defp success_message(:push), do: "Pushed"
  defp success_message(:pull), do: "Pulled"
  defp success_message(:fetch), do: "Fetched"
  defp success_message(:pull_and_retry), do: "Pushed"

  @spec failure_message(operation(), term()) :: String.t()
  defp failure_message(_operation, {:worker_exit, reason}),
    do: "Git operation failed unexpectedly: #{format_down_reason(reason)}"

  defp failure_message(_operation, {:start_failed, reason}),
    do: "Git operation failed unexpectedly: #{format_down_reason(reason)}"

  defp failure_message(_operation, :timeout), do: "Git operation timed out"
  defp failure_message(:push, reason), do: "Push failed: #{format_reason(reason)}"
  defp failure_message(:pull, reason), do: "Pull failed: #{format_reason(reason)}"
  defp failure_message(:fetch, reason), do: "Fetch failed: #{format_reason(reason)}"

  defp failure_message(:pull_and_retry, reason),
    do: "Pull and retry failed: #{format_reason(reason)}"

  @spec format_down_reason(term()) :: String.t()
  defp format_down_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_down_reason(reason), do: inspect(reason, charlists: :as_lists, limit: 5)

  @spec format_reason(term()) :: String.t()
  defp format_reason({:source_unavailable, source, _module, _function, reason}),
    do: "source unavailable (#{inspect(source)}: #{inspect(reason)})"

  defp format_reason({:callback_failed, _source, _module, _function, kind, reason}),
    do: "extension callback #{kind}: #{format_callback_reason(reason)}"

  defp format_reason({:invalid_return, _source, _module, _function, returned}),
    do: "extension callback returned invalid value: #{inspect(returned)}"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  @spec format_callback_reason(term()) :: String.t()
  defp format_callback_reason(%{__exception__: true} = exception),
    do: Exception.message(exception)

  defp format_callback_reason(reason), do: inspect(reason)

  @spec retry_action(operation(), term()) :: :pull_and_retry | nil
  defp retry_action(:push, reason) do
    lowered = String.downcase(format_reason(reason))

    if Enum.any?(@pull_retry_markers, &String.contains?(lowered, &1)),
      do: :pull_and_retry,
      else: nil
  end

  defp retry_action(_operation, _reason), do: nil

  @spec publish_notice(EditorState.t(), String.t()) :: EditorState.t()
  defp publish_notice(%{shell_runtime: %{state: %TraditionalState{}}} = state, message),
    do: NoticeWorkflow.publish(state, message)

  defp publish_notice(state, _message), do: state

  @spec publish_toast(EditorState.t(), String.t(), atom(), atom() | nil) :: EditorState.t()
  defp publish_toast(
         %{shell_runtime: %{state: %TraditionalState{}}} = state,
         message,
         level,
         action
       ),
       do: GitToastWorkflow.publish(state, message, level, action)

  defp publish_toast(state, _message, _level, _action), do: state

  @spec refresh_repo(t()) :: :ok
  defp refresh_repo(%__MODULE__{refresher: refresher, git_root: git_root}) do
    refresher.refresh_git_repo(git_root)
  end
end
