defmodule Minga.Agent.Tools.Git do
  @moduledoc """
  Structured git tools for the agent.

  Wraps `Minga.Git` functions to provide clean, parseable output instead of
  raw CLI text. Each function returns a formatted string suitable for tool
  results that the model can reason about easily.
  """

  alias Minga.Git

  @doc """
  Returns a structured list of changed files with their status.
  """
  @spec status(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def status(project_root) do
    git_root = resolve_git_root(project_root)

    case Git.status(git_root) do
      {:ok, []} ->
        {:ok, "Working tree clean. No changes."}

      {:ok, entries} ->
        staged = Enum.filter(entries, & &1.staged)
        unstaged = Enum.reject(entries, & &1.staged)

        parts =
          [
            if(staged != [],
              do: "Staged changes:\n" <> Enum.map_join(staged, "\n", &format_status_entry/1)
            ),
            if(unstaged != [],
              do: "Unstaged changes:\n" <> Enum.map_join(unstaged, "\n", &format_status_entry/1)
            )
          ]
          |> Enum.reject(&is_nil/1)

        {:ok, Enum.join(parts, "\n\n")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the diff for a specific file or all changes.
  """
  @spec diff(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(project_root, opts \\ []) do
    git_root = resolve_git_root(project_root)

    case Git.diff(git_root, opts) do
      {:ok, ""} -> {:ok, "No differences."}
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns recent commits as formatted entries.
  """
  @spec log(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def log(project_root, opts \\ []) do
    git_root = resolve_git_root(project_root)

    case Git.log(git_root, opts) do
      {:ok, []} ->
        {:ok, "No commits found."}

      {:ok, entries} ->
        formatted =
          Enum.map_join(entries, "\n", fn e ->
            "#{e.short_hash} #{e.date} #{e.author}: #{e.message}"
          end)

        {:ok, formatted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stages specific files.
  """
  @spec stage(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def stage(project_root, paths) when is_list(paths) do
    git_root = resolve_git_root(project_root)

    case Git.stage(git_root, paths) do
      :ok -> {:ok, "Staged #{length(paths)} file(s): #{Enum.join(paths, ", ")}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a commit with the given message.

  NOTE: This does not verify git identity. When the agent commits code, it
  uses whatever git identity is currently configured. The git-identity skill
  is a human workflow tool and cannot be automated here.
  """
  @spec commit(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def commit(project_root, message) do
    git_root = resolve_git_root(project_root)

    case Git.commit(git_root, message) do
      {:ok, short_hash} -> {:ok, "Committed #{short_hash}: #{message}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec format_status_entry(Git.status_entry()) :: String.t()
  defp format_status_entry(%{path: path, status: status}) do
    label =
      case status do
        :added -> "A"
        :modified -> "M"
        :deleted -> "D"
        :renamed -> "R"
        :copied -> "C"
        :untracked -> "?"
        :unknown -> "!"
      end

    "  #{label} #{path}"
  end

  @spec resolve_git_root(String.t()) :: String.t()
  defp resolve_git_root(project_root) do
    case Git.root_for(project_root) do
      {:ok, root} -> root
      :not_git -> project_root
    end
  end
end
