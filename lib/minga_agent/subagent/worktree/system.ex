defmodule MingaAgent.Subagent.Worktree.System do
  @moduledoc "Git CLI backend for isolated subagent worktrees."

  @behaviour MingaAgent.Subagent.Worktree.Backend

  @impl MingaAgent.Subagent.Worktree.Backend
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(cwd, args, _opts) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc "Runs git and returns stdout only, so warnings on stderr cannot corrupt file content."
  @spec stdout(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def stdout(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: false) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, "git #{Enum.join(args, " ")} exited with status #{status}"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
