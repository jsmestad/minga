defmodule MingaAgent.Subagent.Worktree.Backend do
  @moduledoc """
  Command boundary used by subagent worktree lifecycle orchestration.

  Production uses the Git CLI backend. Tests may provide a deterministic backend
  so lifecycle decisions do not require OS processes.
  """

  @callback run(cwd :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {:ok, String.t()} | {:error, String.t()}
end
