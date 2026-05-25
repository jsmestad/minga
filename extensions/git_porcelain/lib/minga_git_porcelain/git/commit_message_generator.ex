defmodule MingaGitPorcelain.Git.CommitMessageGenerator do
  @moduledoc """
  Generates conventional commit messages from staged diffs using the configured AI provider.

  Spawns a one-shot LLM task via Eval.TaskSupervisor that sends the result
  back to the Editor GenServer as {:git_commit_message_generated, result}.
  """

  alias ReqLLM.StreamResponse

  @max_diff_chars 4000
  @timeout_ms 15_000

  @system_prompt """
  You are a commit message generator. Given a git diff, write a commit message following the conventional commit format:

  type(scope): short description

  Optional body explaining what changed and why.

  Types: feat, fix, refactor, test, docs, chore, perf, style, build, ci
  Scope: infer from the file paths and module names in the diff.
  Rules:
  - First line under 72 characters
  - Use imperative mood ("add", not "added")
  - Body lines under 72 characters
  - No period at the end of the subject line
  - Only include a body if the change is non-obvious
  - Output ONLY the commit message, no explanation or markdown formatting
  """

  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  @doc """
  Spawns an async task that generates a commit message from the staged diff.

  On completion, sends `{:git_commit_message_generated, result}` to `reply_to`
  where result is `{:ok, message}` or `{:error, reason}`.
  """
  @spec generate(String.t(), GenServer.server()) :: {:ok, pid()} | {:error, term()}
  def generate(staged_diff, reply_to) do
    model = MingaAgent.ProviderResolver.configured_model() || MingaAgent.Config.default_model()

    spawn_task(model, staged_diff, reply_to)
  end

  @spec spawn_task(String.t(), String.t(), GenServer.server()) :: {:ok, pid()} | {:error, term()}
  defp spawn_task(model, staged_diff, reply_to) do
    Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn ->
      result = run_generation(model, staged_diff)
      send(reply_to, {:git_commit_message_generated, result})
    end)
  end

  @spec run_generation(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp run_generation(model, staged_diff) do
    diff_text = truncate_diff(staged_diff)
    config = MingaAgent.Config.resolve()

    messages = [
      %{role: "system", content: @system_prompt},
      %{role: "user", content: diff_text}
    ]

    stream_opts = [max_tokens: 300]
    stream_opts = maybe_add_base_url(stream_opts, model, config)

    call_llm(model, messages, stream_opts)
  rescue
    e ->
      Minga.Log.warning(:agent, "AI commit message generation failed: #{Exception.message(e)}")
      {:error, "AI generation error: #{Exception.message(e)}"}
  end

  @spec call_llm(String.t(), [map()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  defp call_llm(model, messages, stream_opts) do
    with {:ok, stream_response} <- ReqLLM.stream_text(model, messages, stream_opts),
         {:ok, response} <- StreamResponse.process_stream(stream_response),
         text when text != "" <- String.trim(ReqLLM.Response.text(response) || "") do
      {:ok, text}
    else
      "" -> {:error, "AI returned an empty commit message"}
      {:error, reason} -> {:error, "AI generation failed: #{inspect(reason)}"}
    end
  end

  @spec truncate_diff(String.t()) :: String.t()
  defp truncate_diff(diff) when byte_size(diff) <= @max_diff_chars, do: diff

  defp truncate_diff(diff) do
    truncated = binary_slice(diff, 0, @max_diff_chars)
    truncated <> "\n\n[diff truncated at #{@max_diff_chars} bytes]"
  end

  @spec maybe_add_base_url(keyword(), String.t(), MingaAgent.Config.t()) :: keyword()
  defp maybe_add_base_url(opts, _model, config) do
    url = non_empty(config.api_base_url_override) || non_empty(config.api_base_url)

    if url do
      Keyword.put(opts, :base_url, url)
    else
      opts
    end
  end

  @spec non_empty(String.t() | nil) :: String.t() | nil
  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(s) when is_binary(s), do: s
end
