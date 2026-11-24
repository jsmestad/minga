defmodule MingaAgent.Tools.SandboxBackend.SandboxExec do
  @moduledoc """
  macOS sandbox backend using `sandbox-exec` with Seatbelt (SBPL) profiles.

  Generates an allow-default SBPL profile that denies access to private user
  paths and optionally denies all network access, then allows the workspace
  path for read-write. The profile is passed inline via `-p` to avoid
  temporary file management. Overhead is approximately 8ms per invocation.

  Paths in the SBPL profile are canonicalized (symlinks resolved) because
  `sandbox-exec` evaluates canonical paths, not symlink paths.
  """

  @behaviour MingaAgent.Tools.SandboxBackend

  alias MingaAgent.Tools.SandboxPolicy

  @sandbox_exec_path "/usr/bin/sandbox-exec"

  @impl true
  @spec available?() :: boolean()
  def available? do
    File.exists?(@sandbox_exec_path)
  end

  @impl true
  @spec wrap_command(SandboxPolicy.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def wrap_command(%SandboxPolicy{} = policy, command) when is_binary(command) do
    profile = build_profile(policy)
    escaped_profile = shell_escape(profile)
    escaped_command = shell_escape(command)
    wrapped = "#{@sandbox_exec_path} -p #{escaped_profile} /bin/sh -c #{escaped_command}"
    {:ok, wrapped}
  end

  @doc "Builds the SBPL profile string from a sandbox policy. Exposed for testing."
  @spec build_profile(SandboxPolicy.t()) :: String.t()
  def build_profile(%SandboxPolicy{} = policy) do
    workspace = canonical_path(policy.workspace)

    clauses = [
      "(version 1)",
      "(allow default)",
      deny_private_paths(),
      allow_workspace(workspace),
      allow_extra_ro(policy.extra_ro_binds),
      allow_extra_rw(policy.extra_rw_binds),
      network_clause(policy.allow_network)
    ]

    clauses |> List.flatten() |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  @spec deny_private_paths() :: String.t()
  defp deny_private_paths do
    "(deny file-read* file-write* (subpath \"/Users\") (subpath \"/private/var\") (subpath \"/var\"))"
  end

  @spec allow_workspace(String.t()) :: [String.t()]
  defp allow_workspace(workspace) do
    [
      "(allow file-read* file-write* (subpath #{sbpl_quote(workspace)}))"
    ]
  end

  @spec allow_extra_ro([{String.t(), String.t()}]) :: [String.t()]
  defp allow_extra_ro(binds) do
    Enum.map(binds, fn {source, _dest} ->
      path = canonical_path(source)
      "(allow file-read* (subpath #{sbpl_quote(path)}))"
    end)
  end

  @spec allow_extra_rw([{String.t(), String.t()}]) :: [String.t()]
  defp allow_extra_rw(binds) do
    Enum.map(binds, fn {source, _dest} ->
      path = canonical_path(source)
      "(allow file-read* file-write* (subpath #{sbpl_quote(path)}))"
    end)
  end

  @spec network_clause(boolean()) :: String.t()
  defp network_clause(true), do: ""
  defp network_clause(false), do: "(deny network*)"

  @spec sbpl_quote(String.t()) :: String.t()
  defp sbpl_quote(path) do
    escaped = String.replace(path, "\"", "\\\"")
    "\"#{escaped}\""
  end

  @spec shell_escape(String.t()) :: String.t()
  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  @spec canonical_path(String.t()) :: String.t()
  defp canonical_path(path) do
    # Expand the path and resolve symlinks for sandbox-exec compatibility.
    # /var -> /private/var on macOS, /tmp -> /private/tmp, etc.
    expanded = Path.expand(path)

    case :file.read_link_all(String.to_charlist(expanded)) do
      {:ok, target} ->
        target_str = List.to_string(target)

        if Path.type(target_str) == :absolute do
          canonical_path(target_str)
        else
          expanded
          |> Path.dirname()
          |> Path.join(target_str)
          |> canonical_path()
        end

      {:error, _} ->
        # Not a symlink. Try resolving parent components for paths like
        # /var/folders/... where /var itself is a symlink.
        resolve_parent_symlinks(expanded)
    end
  end

  @spec resolve_parent_symlinks(String.t()) :: String.t()
  defp resolve_parent_symlinks(path) do
    parts = Path.split(path)
    resolve_parts(parts, "/")
  end

  @spec resolve_parts([String.t()], String.t()) :: String.t()
  defp resolve_parts([], acc), do: acc

  defp resolve_parts([part | rest], acc) do
    candidate = Path.join(acc, part)

    resolved =
      case :file.read_link_all(String.to_charlist(candidate)) do
        {:ok, target} ->
          target_str = List.to_string(target)

          if Path.type(target_str) == :absolute do
            target_str
          else
            Path.join(acc, target_str)
          end

        {:error, _} ->
          candidate
      end

    resolve_parts(rest, resolved)
  end
end
