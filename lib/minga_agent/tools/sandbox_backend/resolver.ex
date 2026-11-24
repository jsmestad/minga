defmodule MingaAgent.Tools.SandboxBackend.Resolver do
  @moduledoc """
  Selects the sandbox backend for the current OS and verifies it is available.

  Returns `{:error, :unsupported_platform}` on operating systems without a
  backend, and `{:error, :backend_unavailable, message}` when the required
  binary is missing. The caller must refuse execution on any error (fail-closed).
  """

  alias MingaAgent.Tools.SandboxBackend.Bubblewrap
  alias MingaAgent.Tools.SandboxBackend.SandboxExec
  alias MingaAgent.Tools.SandboxPolicy

  @type select_result ::
          {:ok, module()} | {:error, :unsupported_platform | :backend_unavailable, String.t()}
  @type wrap_result :: {:ok, String.t()} | {:error, term()}

  @doc """
  Returns the sandbox backend module for the current OS.

  Checks both platform support and binary availability.
  """
  @spec select() :: select_result()
  def select do
    case :os.type() do
      {:unix, :darwin} -> check_available(SandboxExec, "sandbox-exec")
      {:unix, :linux} -> check_available(Bubblewrap, "bwrap")
      {_family, os} -> {:error, :unsupported_platform, "No sandbox backend for #{os}"}
    end
  end

  @doc """
  Selects the backend and wraps the command in one step.

  Returns `{:ok, wrapped_command}` on success. On failure, returns an error
  that the caller must use to refuse execution.
  """
  @spec wrap(SandboxPolicy.t(), String.t()) :: wrap_result()
  def wrap(%SandboxPolicy{} = policy, command) when is_binary(command) do
    case select() do
      {:ok, backend} -> backend.wrap_command(policy, command)
      {:error, reason, message} -> {:error, {reason, message}}
    end
  end

  @spec check_available(module(), String.t()) ::
          {:ok, module()} | {:error, :backend_unavailable, String.t()}
  defp check_available(backend, binary_name) do
    if backend.available?() do
      {:ok, backend}
    else
      {:error, :backend_unavailable,
       "Sandbox backend requires #{binary_name}, which is not installed or not in PATH. Install it to enable sandboxed execution."}
    end
  end
end
