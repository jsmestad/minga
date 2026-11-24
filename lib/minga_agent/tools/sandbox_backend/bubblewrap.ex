defmodule MingaAgent.Tools.SandboxBackend.Bubblewrap do
  @moduledoc """
  Linux sandbox backend using Bubblewrap (`bwrap`).

  Builds a `bwrap` invocation that isolates the command in a mount namespace
  with read-only system paths, a read-write workspace bind, PID and optional
  network namespace isolation, and a cleaned environment. Overhead is
  approximately 2ms per invocation.
  """

  @behaviour MingaAgent.Tools.SandboxBackend

  alias MingaAgent.Tools.SandboxPolicy

  @default_toolchain_paths ~w(/usr /lib64 /lib /bin /sbin /etc)

  @impl true
  @spec available?() :: boolean()
  def available? do
    System.find_executable("bwrap") != nil
  end

  @impl true
  @spec wrap_command(SandboxPolicy.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def wrap_command(%SandboxPolicy{} = policy, command) when is_binary(command) do
    workspace = resolve_path(policy.workspace)
    toolchain = effective_toolchain(policy.toolchain_paths)

    args =
      toolchain_binds(toolchain) ++
        workspace_bind(workspace) ++
        extra_ro_binds(policy.extra_ro_binds) ++
        extra_rw_binds(policy.extra_rw_binds) ++
        virtual_filesystems() ++
        network_flags(policy.allow_network) ++
        isolation_flags() ++
        env_flags(policy.env_allowlist) ++
        ["--", "/bin/sh", "-c", shell_escape(command)]

    wrapped = Enum.join(["bwrap" | args], " ")
    {:ok, wrapped}
  end

  @spec effective_toolchain([String.t()]) :: [String.t()]
  defp effective_toolchain([]), do: @default_toolchain_paths
  defp effective_toolchain(paths), do: paths

  @spec toolchain_binds([String.t()]) :: [String.t()]
  defp toolchain_binds(paths) do
    Enum.flat_map(paths, fn path ->
      resolved = resolve_path(path)

      if File.exists?(resolved) do
        ["--ro-bind", resolved, resolved]
      else
        []
      end
    end)
  end

  @spec workspace_bind(String.t()) :: [String.t()]
  defp workspace_bind(workspace), do: ["--bind", workspace, workspace]

  @spec extra_ro_binds([{String.t(), String.t()}]) :: [String.t()]
  defp extra_ro_binds(binds) do
    Enum.flat_map(binds, fn {source, dest} ->
      ["--ro-bind", resolve_path(source), dest]
    end)
  end

  @spec extra_rw_binds([{String.t(), String.t()}]) :: [String.t()]
  defp extra_rw_binds(binds) do
    Enum.flat_map(binds, fn {source, dest} ->
      ["--bind", resolve_path(source), dest]
    end)
  end

  @spec virtual_filesystems() :: [String.t()]
  defp virtual_filesystems, do: ~w(--proc /proc --dev /dev --tmpfs /tmp)

  @spec network_flags(boolean()) :: [String.t()]
  defp network_flags(true), do: []
  defp network_flags(false), do: ["--unshare-net"]

  @spec isolation_flags() :: [String.t()]
  defp isolation_flags, do: ~w(--unshare-pid --die-with-parent)

  @spec env_flags([String.t()]) :: [String.t()]
  defp env_flags(allowlist) do
    clear = ["--clearenv"]

    sets =
      Enum.flat_map(allowlist, fn var ->
        case System.get_env(var) do
          nil -> []
          value -> ["--setenv", var, value]
        end
      end)

    clear ++ sets
  end

  @spec shell_escape(String.t()) :: String.t()
  defp shell_escape(command) do
    "'" <> String.replace(command, "'", "'\\''") <> "'"
  end

  @spec resolve_path(String.t()) :: String.t()
  defp resolve_path(path) do
    case File.read_link(path) do
      {:ok, target} ->
        if Path.type(target) == :absolute do
          resolve_path(target)
        else
          path |> Path.dirname() |> Path.join(target) |> Path.expand() |> resolve_path()
        end

      {:error, _} ->
        Path.expand(path)
    end
  end
end
