defmodule Minga.Tool.Installer.Npm do
  @moduledoc """
  Installs tools from npm into a sandboxed directory.

  Uses `npm install --prefix {dest_dir}` to install packages locally.
  Binaries from `node_modules/.bin/` are symlinked into `tools/bin/`.
  No global installs. Each tool gets its own isolated node_modules.

  Requires `npm` to be on PATH.
  """

  @behaviour Minga.Tool.Installer

  alias Minga.Tool.Recipe

  @impl true
  @spec install(Recipe.t(), String.t(), Minga.Tool.Installer.progress_callback()) ::
          {:ok, String.t()} | {:error, term()}
  def install(%Recipe{package: package} = _recipe, dest_dir, progress) do
    progress.(:installing, "Installing #{package} via npm...")
    File.mkdir_p!(dest_dir)

    case System.cmd("npm", ["install", "--prefix", dest_dir, package],
           stderr_to_stdout: true,
           env: [{"NODE_ENV", "production"}]
         ) do
      {_output, 0} ->
        progress.(:linking, "Linking binaries...")

        case detect_version(dest_dir, package) do
          {:ok, version} -> {:ok, version}
          nil -> {:ok, "unknown"}
        end

      {output, code} ->
        {:error, "npm install failed (exit #{code}): #{String.slice(output, 0..500)}"}
    end
  end

  @impl true
  @spec uninstall(Recipe.t(), String.t()) :: :ok | {:error, term()}
  def uninstall(_recipe, dest_dir) do
    case File.rm_rf(dest_dir) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  @impl true
  @spec installed_version(Recipe.t(), String.t()) :: {:ok, String.t()} | nil
  def installed_version(%Recipe{package: package}, dest_dir) do
    detect_version(dest_dir, package)
  end

  @impl true
  @spec latest_version(Recipe.t()) :: {:ok, String.t()} | {:error, term()}
  def latest_version(%Recipe{package: package}) do
    case System.cmd("npm", ["view", package, "version"], stderr_to_stdout: true) do
      {version, 0} -> {:ok, String.trim(version)}
      {output, _} -> {:error, "npm view failed: #{String.slice(output, 0..200)}"}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @doc "Returns the list of binary names available in the npm .bin directory."
  @spec available_binaries(String.t()) :: [String.t()]
  def available_binaries(dest_dir) do
    bin_dir = Path.join([dest_dir, "node_modules", ".bin"])

    case File.ls(bin_dir) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end

  @spec detect_version(String.t(), String.t()) :: {:ok, String.t()} | nil
  defp detect_version(dest_dir, package) do
    pkg_json = Path.join([dest_dir, "node_modules", package, "package.json"])

    with {:ok, content} <- File.read(pkg_json),
         {:ok, %{"version" => version}} <- Jason.decode(content) do
      {:ok, version}
    else
      _ -> nil
    end
  end
end
