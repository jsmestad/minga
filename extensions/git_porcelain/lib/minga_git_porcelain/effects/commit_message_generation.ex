defmodule MingaGitPorcelain.Effects.CommitMessageGeneration do
  @moduledoc "Typed scheduler effect for staged-diff commit-message generation."

  @behaviour MingaEditor.Effect

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay
  alias Minga.Git

  @source {:extension, :minga_git_porcelain}
  @timeout_ms 15_000
  @generator MingaGitPorcelain.Git.CommitMessageGenerator

  @type source :: CallbackInvoker.source()
  @type repository_context :: {
          project_root :: String.t() | nil,
          original_root :: String.t() | nil,
          root_generation :: non_neg_integer()
        }
  @type repository_resolution :: {:ok, String.t()} | {:error, term()}

  @enforce_keys [:source, :git, :generator, :admission, :repository_context, :repository]
  defstruct [:source, :git, :generator, :admission, :repository_context, :repository]

  @type t :: %__MODULE__{
          source: source(),
          git: module(),
          generator: module(),
          admission: GenServer.server(),
          repository_context: repository_context(),
          repository: repository_resolution()
        }

  @doc "Builds a single-slot request correlated to an exact root lifecycle and repository."
  @spec request(repository_context(), repository_resolution(), keyword()) :: Request.t()
  def request(
        {project_root, original_root, generation} = repository_context,
        repository,
        opts \\ []
      )
      when (is_binary(project_root) or is_nil(project_root)) and
             (is_binary(original_root) or is_nil(original_root)) and
             is_integer(generation) and generation >= 0 and is_list(opts) do
    {:extension, _name} = source = Keyword.get(opts, :source, @source)

    effect = %__MODULE__{
      source: source,
      git: Keyword.get(opts, :git, Git),
      generator: Keyword.get(opts, :generator, @generator),
      admission: Keyword.get(opts, :admission, CodeLease),
      repository_context: repository_context,
      repository: repository
    }

    Request.new(effect, {:git_porcelain_commit_generation, source}, Policy.fifo(0),
      source: source,
      timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms)
    )
  end

  @doc "Runs generation work through the extension callback trust boundary."
  @impl true
  @spec run(t()) :: {:ok, {:generated, String.t()}} | {:error, term()}
  def run(%__MODULE__{source: source, admission: admission} = effect) do
    case CallbackInvoker.invoke(
           source,
           __MODULE__,
           :execute,
           [effect],
           :effect_execution,
           admission
         ) do
      {:ok, {:ok, {:generated, message}} = result} when is_binary(message) ->
        result

      {:ok, {:error, _reason} = error} ->
        error

      {:ok, returned} ->
        {:error, CallbackInvoker.invalid_return(source, __MODULE__, :execute, returned)}

      {:error, failure} ->
        {:error, failure}
    end
  end

  @doc false
  @spec execute(t()) :: {:ok, {:generated, String.t()}} | {:error, term()}
  def execute(%__MODULE__{} = effect) do
    with {:ok, root} <- effect.repository,
         {:ok, diff} <- staged_diff(effect.git, root),
         {:non_empty, true} <- {:non_empty, diff != ""},
         {:ok, message} <- generate(effect.generator, diff) do
      {:ok, {:generated, message}}
    else
      {:non_empty, false} -> {:error, :empty_staged_diff}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec coalesce(t(), t()) :: t()
  def coalesce(_older, newer), do: newer

  @doc "Returns the exact project roots that identify the active repository context."
  @spec repository_context(EditorState.t()) :: repository_context()
  def repository_context(%EditorState{workspace: %{file_tree: file_tree}}) do
    {file_tree.project_root, file_tree.original_root,
     MingaEditor.State.FileTree.root_generation(file_tree)}
  end

  @doc "Resolves the exact repository root captured before worker admission."
  @spec resolve_repository(module(), module()) :: repository_resolution()
  def resolve_repository(git, project) when is_atom(git) and is_atom(project) do
    case git.root_for(project.resolve_root()) do
      {:ok, root} -> {:ok, root}
      :not_git -> {:error, :not_a_repository}
      {:error, reason} -> {:error, {:root_resolution_failed, reason}}
    end
  end

  @doc "Applies generation feedback only while the originating repository remains active."
  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(
        %EditorState{} = state,
        %Outcome{
          request: %Request{effect: %__MODULE__{repository_context: expected_context}}
        } = outcome
      ) do
    case repository_context(state) do
      ^expected_context -> apply_current(state, outcome)
      _current_context -> stale_repository_result(state, outcome)
    end
  end

  @spec apply_current(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  defp apply_current(state, %Outcome{value: :running} = outcome) do
    {publish_notice(state, "Generating commit message…"), outcome}
  end

  defp apply_current(
         %{shell_runtime: %{state: %TraditionalState{modal: modal}}} = state,
         %Outcome{value: {:completed, {:generated, message}}} = outcome
       ) do
    state =
      if ModalOverlay.active?(modal) do
        NoticeWorkflow.publish(state, "Commit message ready (prompt already open)")
      else
        state
        |> open_commit_prompt(message)
        |> NoticeWorkflow.publish("Commit message generated")
      end

    {state, outcome}
  end

  defp apply_current(
         state,
         %Outcome{value: {:completed, {:generated, _message}}} = outcome
       ),
       do: {state, outcome}

  defp apply_current(state, %Outcome{value: {:failed, reason}} = outcome) do
    {publish_notice(state, failure_message(reason)), outcome}
  end

  defp apply_current(state, %Outcome{value: {:canceled, :source_canceled}} = outcome),
    do: {state, outcome}

  defp apply_current(state, %Outcome{value: {:canceled, _reason}} = outcome) do
    {publish_notice(state, "Commit message generation canceled"), outcome}
  end

  defp apply_current(state, %Outcome{value: {:stale, _reason}} = outcome), do: {state, outcome}

  @spec stale_repository_result(EditorState.t(), Outcome.t()) ::
          {EditorState.t(), Outcome.t()}
  defp stale_repository_result(state, outcome) do
    state = publish_notice(state, "Commit message result ignored after repository changed")
    {state, Outcome.stale(outcome, :repository_changed)}
  end

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec staged_diff(module(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp staged_diff(git, root) do
    case git.diff(root, staged: true) do
      {:ok, diff} when is_binary(diff) -> {:ok, diff}
      {:error, reason} -> {:error, {:diff_read_failed, reason}}
      other -> {:error, {:diff_read_failed, other}}
    end
  end

  @spec generate(module(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp generate(generator, diff) do
    case generator.generate(diff) do
      {:ok, message} when is_binary(message) and message != "" -> {:ok, message}
      {:ok, ""} -> {:error, {:generation_failed, :empty_generated_message}}
      {:error, reason} -> {:error, {:generation_failed, reason}}
      other -> {:error, {:generation_failed, other}}
    end
  end

  @spec failure_message(term()) :: String.t()
  defp failure_message(:not_a_repository), do: "Not in a git repository"
  defp failure_message(:empty_staged_diff), do: "Nothing staged to generate a message for"
  defp failure_message(:timeout), do: "Commit message generation timed out"

  defp failure_message({:root_resolution_failed, reason}),
    do: "Failed to find git repository: #{format_reason(reason)}"

  defp failure_message({:diff_read_failed, reason}),
    do: "Failed to read staged diff: #{format_reason(reason)}"

  defp failure_message({:generation_failed, reason}), do: generation_failure_message(reason)

  defp failure_message({:worker_exit, reason}),
    do: "Commit message generation failed unexpectedly: #{inspect(reason)}"

  defp failure_message({:start_failed, reason}),
    do: "Commit message generation failed to start: #{inspect(reason)}"

  defp failure_message({:source_unavailable, source, _module, _function, reason}),
    do: "Commit message source unavailable: #{inspect(source)} (#{inspect(reason)})"

  defp failure_message({:callback_failed, _source, _module, _function, kind, reason}),
    do: "Commit message generation callback #{kind}: #{format_callback_reason(reason)}"

  defp failure_message({:invalid_return, _source, _module, _function, returned}),
    do: "Commit message generation callback returned invalid value: #{inspect(returned)}"

  defp failure_message(reason), do: "Commit message generation failed: #{inspect(reason)}"

  @spec generation_failure_message(term()) :: String.t()
  defp generation_failure_message(reason) when is_binary(reason), do: reason
  defp generation_failure_message(reason), do: "AI generation failed: #{inspect(reason)}"

  @spec format_callback_reason(term()) :: String.t()
  defp format_callback_reason(%{__exception__: true} = exception),
    do: Exception.message(exception)

  defp format_callback_reason(reason), do: inspect(reason)

  @spec format_reason(term()) :: String.t()
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  @spec publish_notice(EditorState.t(), String.t()) :: EditorState.t()
  defp publish_notice(%{shell_runtime: %{state: %TraditionalState{}}} = state, message),
    do: NoticeWorkflow.publish(state, message)

  defp publish_notice(state, _message), do: state

  @spec open_commit_prompt(EditorState.t(), String.t()) :: EditorState.t()
  defp open_commit_prompt(state, message) do
    prompt = MingaGitPorcelain.UI.Prompt.GitCommit

    if Code.ensure_loaded?(prompt) do
      MingaEditor.PromptUI.open(state, prompt, default: message)
    else
      state
    end
  end
end
