defmodule Minga.Tool.Installer.Pip do
  @moduledoc """
  Installs Python tools into isolated venvs.

  Creates a virtual environment at `{dest_dir}/venv/` and installs the
  package into it. Binaries land in `{dest_dir}/venv/bin/` and are
  symlinked into `tools/bin/`.

  Requires `python3` to be on PATH.
  """

  @behaviour Minga.Tool.Installer

  alias Minga.Tool.Recipe

  @impl true
  @spec install(Recipe.t(), String.t(), Minga.Tool.Installer.progress_callback()) ::
          {:ok, String.t()} | {:error, term()}
  def install(%Recipe{package: package} = _recipe, dest_dir, progress) do
    venv_dir = Path.join(dest_dir, "venv")

    progress.(:installing, "Creating Python virtual environment...")
    File.mkdir_p!(dest_dir)

    case System.cmd("python3", ["-m", "venv", venv_dir], stderr_to_stdout: true) do
      {_out, 0} ->
        pip = Path.join([venv_dir, "bin", "pip"])
        progress.(:installing, "Installing #{package} via pip...")
        run_pip_install(pip, package)

      {output, code} ->
        {:error, "venv creation failed (exit #{code}): #{String.slice(output, 0..500)}"}
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
    pip = Path.join([dest_dir, "venv", "bin", "pip"])

    if File.exists?(pip) do
      version = detect_version(pip, package)
      if version != "unknown", do: {:ok, version}, else: nil
    else
      nil
    end
  end

  @impl true
  @spec latest_version(Recipe.t()) :: {:ok, String.t()} | {:error, term()}
  def latest_version(%Recipe{package: package}) do
    url = "https://pypi.org/pypi/#{package}/json"

    case System.cmd("curl", ["-fsSL", url], stderr_to_stdout: true) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, %{"info" => %{"version" => version}}} -> {:ok, version}
          _ -> {:error, "Failed to parse PyPI response"}
        end

      {output, _code} ->
        {:error, "PyPI request failed: #{String.slice(output, 0..200)}"}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @doc "Returns the list of binary names available in the venv bin directory."
  @spec available_binaries(String.t()) :: [String.t()]
  def available_binaries(dest_dir) do
    bin_dir = Path.join([dest_dir, "venv", "bin"])

    case File.ls(bin_dir) do
      {:ok, files} ->
        # Filter out python/pip/activate scripts
        Enum.reject(files, fn f ->
          f in [
            "python",
            "python3",
            "pip",
            "pip3",
            "activate",
            "activate.csh",
            "activate.fish",
            "Activate.ps1"
          ] or
            String.starts_with?(f, "python3.") or
            String.starts_with?(f, "pip3.")
        end)

      {:error, _} ->
        []
    end
  end

  @spec run_pip_install(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp run_pip_install(pip, package) do
    case System.cmd(pip, ["install", "--quiet", package], stderr_to_stdout: true) do
      {_output, 0} ->
        version = detect_version(pip, package)
        {:ok, version}

      {output, code} ->
        {:error, "pip install failed (exit #{code}): #{String.slice(output, 0..500)}"}
    end
  end

  @spec detect_version(String.t(), String.t()) :: String.t()
  defp detect_version(pip, package) do
    case System.cmd(pip, ["show", package], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/Version:\s*(.+)/, output) do
          [_, version] -> String.trim(version)
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end
end
