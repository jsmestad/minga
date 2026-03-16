defmodule Minga.Git.Backend do
  @moduledoc """
  Behaviour for git operations.

  The default implementation (`Minga.Git.System`) shells out to the `git`
  CLI. In tests, `Minga.Git.Stub` returns inert responses without
  spawning OS processes.

  Configure via:

      config :minga, git_module: Minga.Git.System   # default
      config :minga, git_module: Minga.Git.Stub      # tests
  """

  @callback root_for(path :: String.t()) :: {:ok, String.t()} | :not_git

  @callback show_head(git_root :: String.t(), relative_path :: String.t()) ::
              {:ok, String.t()} | :error

  @callback blame_line(
              git_root :: String.t(),
              relative_path :: String.t(),
              line :: non_neg_integer()
            ) ::
              {:ok, String.t()} | :error

  @callback status(git_root :: String.t()) ::
              {:ok, [Minga.Git.status_entry()]} | {:error, String.t()}

  @callback diff(git_root :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, String.t()}

  @callback log(git_root :: String.t(), opts :: keyword()) ::
              {:ok, [Minga.Git.log_entry()]} | {:error, String.t()}

  @callback stage(git_root :: String.t(), paths :: String.t() | [String.t()]) ::
              :ok | {:error, String.t()}

  @callback commit(git_root :: String.t(), message :: String.t()) ::
              {:ok, String.t()} | {:error, String.t()}

  @callback stage_patch(git_root :: String.t(), patch :: String.t()) ::
              :ok | {:error, String.t()}

  @callback current_branch(git_root :: String.t()) ::
              {:ok, String.t()} | :error
end
