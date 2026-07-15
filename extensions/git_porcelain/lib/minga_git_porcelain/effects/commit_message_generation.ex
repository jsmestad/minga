defmodule MingaGitPorcelain.Effects.CommitMessageGeneration do
  @moduledoc "Typed scheduler effect for staged-diff commit-message generation."

  @behaviour MingaEditor.Effect

  alias Minga.Extension.ContributionCleanup
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

  @type source :: ContributionCleanup.contribution_source() | nil

  @enforce_keys [:source, :git, :generator, :project, :admission]
  defstruct [:source, :git, :generator, :project, :admission]

  @type t :: %__MODULE__{
          source: source(),
          git: module(),
          generator: module(),
          project: module(),
          admission: module()
        }

  @doc "Builds a single-slot commit-generation request."
  @spec request(keyword()) :: Request.t()
  def request(opts \\ []) when is_list(opts) do
    source = Keyword.get(opts, :source, @source)

    effect = %__MODULE__{
      source: source,
      git: Keyword.get(opts, :git, Git),
      generator: Keyword.get(opts, :generator, @generator),
      project: Keyword.get(opts, :project, Minga.Project),
      admission: Keyword.get(opts, :admission, MingaEditor.UI.Picker.Source)
    }

    Request.new(effect, {:git_porcelain_commit_generation, source}, Policy.fifo(0),
      source: source,
      timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms)
    )
  end

  @doc "Resolves the repository and staged diff before invoking the generator."
  @impl true
  @spec run(t()) :: {:ok, {:generated, String.t()}} | {:error, term()}
  def run(%__MODULE__{source: source, admission: admission} = effect) do
    with :ok <- admission.verify_admission(source),
         {:ok, root} <- resolve_root(effect),
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

  @doc "Applies generation feedback and opens the existing commit prompt."
  @impl true
  @spec apply(EditorState.t(), Outcome.t()) :: {EditorState.t(), Outcome.t()}
  def apply(state, %Outcome{status: :running} = outcome) do
    {publish_notice(state, "Generating commit message…"), outcome}
  end

  def apply(
        %{shell_runtime: %{state: %TraditionalState{modal: modal}}} = state,
        %Outcome{status: :completed, result: {:generated, message}} = outcome
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

  def apply(state, %Outcome{status: :completed, result: {:generated, _message}} = outcome),
    do: {state, outcome}

  def apply(state, %Outcome{status: :failed, reason: reason} = outcome) do
    {publish_notice(state, failure_message(reason)), outcome}
  end

  def apply(state, %Outcome{status: :canceled, reason: :source_canceled} = outcome),
    do: {state, outcome}

  def apply(state, %Outcome{status: :canceled} = outcome) do
    {publish_notice(state, "Commit message generation canceled"), outcome}
  end

  def apply(state, %Outcome{status: :stale} = outcome), do: {state, outcome}

  @impl true
  @spec render?(Outcome.t()) :: boolean()
  def render?(%Outcome{}), do: true

  @spec resolve_root(t()) :: {:ok, String.t()} | {:error, :not_a_repository | term()}
  defp resolve_root(%__MODULE__{git: git, project: project}) do
    case git.root_for(project.resolve_root()) do
      {:ok, root} -> {:ok, root}
      :not_git -> {:error, :not_a_repository}
      {:error, reason} -> {:error, {:root_resolution_failed, reason}}
    end
  end

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

  defp failure_message({:source_admission_denied, _source}),
    do: "Commit message generation canceled"

  defp failure_message(reason), do: "Commit message generation failed: #{inspect(reason)}"

  @spec generation_failure_message(term()) :: String.t()
  defp generation_failure_message(reason) when is_binary(reason), do: reason
  defp generation_failure_message(reason), do: "AI generation failed: #{inspect(reason)}"

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
