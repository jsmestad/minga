defmodule MingaAgent.Tools.SandboxBackend do
  @moduledoc """
  Behaviour for OS-specific sandbox backends.

  Each backend translates a `SandboxPolicy` into a command prefix that
  confines the shell command. `available?/0` checks whether the required
  binary exists on the current system. `wrap_command/2` returns a modified
  command string that runs under confinement.
  """

  alias MingaAgent.Tools.SandboxPolicy

  @doc "Returns true when the sandbox binary is present and usable."
  @callback available?() :: boolean()

  @doc """
  Wraps a shell command string with sandbox confinement arguments.

  Returns `{:ok, wrapped_command}` where `wrapped_command` is a string
  suitable for passing to `/bin/sh -c`. The wrapped command runs the
  original command inside the sandbox.
  """
  @callback wrap_command(SandboxPolicy.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
end
