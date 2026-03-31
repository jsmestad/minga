defmodule MingaAgent.ContextArtifact do
  @moduledoc """
  Generates condensed context artifacts from agent sessions.

  Unlike session export (#284) which produces a full transcript for humans,
  context artifacts produce a compact summary designed for feeding to a
  future agent session via `@.minga/context/session-summary-{id}.md`.

  A 50K-token session with dozens of tool calls collapses into a 1-2K
  token context file that a fresh session can consume efficiently.
  """

  @context_dir ".minga/context"

  @summary_prompt """
  Summarize this conversation session into a concise context file that another AI agent can use to understand what happened. Use the following format:

  # Session Context: {brief title based on what was discussed}

  ## Decisions
  - {what was decided and why, one bullet per decision}

  ## Changes Made
  - {files changed, what was done, one bullet per change}

  ## Patterns & Conventions Discovered
  - {coding patterns, architecture notes, conventions found during the session}

  ## Open Questions
  - {unresolved issues, things left for future sessions}

  ## Key Context
  - {any important context that would be lost if this session ended}

  Be concise. Skip sections that have nothing to report. Focus on information that would be most valuable to an agent starting a fresh session on the same codebase. Do not include tool call details or file contents, just the decisions and outcomes.
  """

  @typedoc "Options for artifact generation."
  @type artifact_opts :: [
          project_root: String.t(),
          session_id: String.t() | nil
        ]

  @doc """
  Returns the meta-prompt to inject for summary generation.
  """
  @spec summary_prompt() :: String.t()
  def summary_prompt, do: @summary_prompt

  @doc """
  Saves a generated summary to the `.minga/context/` directory.

  Returns `{:ok, path}` or `{:error, reason}`.
  """
  @spec save(String.t(), artifact_opts()) :: {:ok, String.t()} | {:error, String.t()}
  def save(summary_text, opts) do
    root = Keyword.get(opts, :project_root, File.cwd!())
    session_id = Keyword.get(opts, :session_id) || short_id()
    date = Date.utc_today() |> Date.to_iso8601()
    filename = "session-summary-#{session_id}-#{date}.md"

    context_dir = Path.join(root, @context_dir)
    File.mkdir_p!(context_dir)

    path = Path.join(context_dir, filename)
    File.write!(path, summary_text)

    {:ok, path}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Lists existing context artifacts in the project.
  """
  @spec list(String.t()) :: [String.t()]
  def list(project_root) do
    dir = Path.join(project_root, @context_dir)

    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.sort()
      |> Enum.map(&Path.join(dir, &1))
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Returns true if the conversation has enough content to be worth summarizing.

  Requires at least 2 non-system messages (one user + one assistant).
  """
  @spec summarizable?([ReqLLM.Message.t()]) :: boolean()
  def summarizable?(messages) do
    non_system = Enum.reject(messages, &(&1.role == :system))
    length(non_system) >= 2
  end

  @spec short_id() :: String.t()
  defp short_id do
    :crypto.strong_rand_bytes(4)
    |> Base.hex_encode32(case: :lower, padding: false)
    |> String.slice(0, 6)
  end
end
