defmodule MingaGitPorcelain.Git.CommitMessageGenerator do
  @moduledoc """
  Generates conventional commit messages synchronously from staged diffs using
  the configured AI provider. The effect scheduler owns the worker lifecycle.
  """

  alias Minga.Extension.AI

  @max_diff_chars 4000
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

  @doc """
  Generates a commit message synchronously for one staged diff.

  Generation goes through `Minga.Extension.AI.complete/2`, which resolves the user's model, catalog base URL, and stored or environment credentials. `ai_opts` are passed through to it; production callers pass none.
  """
  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def generate(staged_diff, ai_opts \\ []) when is_binary(staged_diff) and is_list(ai_opts) do
    opts = Keyword.merge(ai_opts, system: @system_prompt, max_tokens: 300)

    [%{role: "user", content: truncate_diff(staged_diff)}]
    |> AI.complete(opts)
    |> generation_result()
  rescue
    e ->
      Minga.Log.warning(:agent, "AI commit message generation failed: #{Exception.message(e)}")
      {:error, "AI generation error: #{Exception.message(e)}"}
  end

  @spec generation_result({:ok, String.t()} | {:error, AI.error()}) ::
          {:ok, String.t()} | {:error, String.t()}
  defp generation_result({:ok, text}), do: {:ok, text}

  defp generation_result({:error, :empty_response}),
    do: {:error, "AI returned an empty commit message"}

  defp generation_result({:error, {:provider_error, reason}}),
    do: {:error, "AI generation failed: #{inspect(reason)}"}

  @spec truncate_diff(String.t()) :: String.t()
  defp truncate_diff(diff) when byte_size(diff) <= @max_diff_chars, do: diff

  defp truncate_diff(diff) do
    truncated = binary_slice(diff, 0, @max_diff_chars)
    truncated <> "\n\n[diff truncated at #{@max_diff_chars} bytes]"
  end
end
