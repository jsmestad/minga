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
end
