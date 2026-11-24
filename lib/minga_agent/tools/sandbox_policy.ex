defmodule MingaAgent.Tools.SandboxPolicy do
  @moduledoc """
  Declarative sandbox policy for agent shell commands.

  Describes what a sandboxed command is allowed to access: a read-write
  workspace root, optional read-only toolchain paths, network access, and an
  environment variable allowlist. Backend modules translate this policy into
  OS-specific confinement (Bubblewrap on Linux, sandbox-exec on macOS).
  """

  @type t :: %__MODULE__{
          workspace: String.t(),
          toolchain_paths: [String.t()],
          allow_network: boolean(),
          env_allowlist: [String.t()],
          extra_ro_binds: [{String.t(), String.t()}],
          extra_rw_binds: [{String.t(), String.t()}]
        }

  @default_env_allowlist ~w(PATH HOME USER LANG LC_ALL TERM SHELL)

  @enforce_keys [:workspace]
  defstruct [
    :workspace,
    toolchain_paths: [],
    allow_network: false,
    env_allowlist: @default_env_allowlist,
    extra_ro_binds: [],
    extra_rw_binds: []
  ]

  @doc "Returns the default environment variable allowlist."
  @spec default_env_allowlist() :: [String.t()]
  def default_env_allowlist, do: @default_env_allowlist
end
