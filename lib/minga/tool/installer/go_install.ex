defmodule Minga.Tool.Installer.GoInstall do
  @moduledoc """
  Installs Go tools via `go install`.

  Uses `GOBIN={dest_dir}/bin/` to install the binary directly into
  the tool directory. Symlinked into `tools/bin/` by the Manager.

  Requires `go` to be on PATH.
  """

  @behaviour Minga.Tool.Installer

  alias Minga.Tool.Recipe

  @impl true
  @spec install(Recipe.t(), String.t(), Minga.Tool.Installer.progress_callback()) ::
          {:ok, String.t()} | {:error, term()}
  def install(%Recipe{package: package} = _recipe, dest_dir, progress) do
    progress.(:installing, "Installing #{package} via go install...")
    bin_dir = Path.join(dest_dir, "bin")
    File.mkdir_p!(bin_dir)

    env = [{"GOBIN", bin_dir}]
    install_target = "#{package}@latest"

    case System.cmd("go", ["install", install_target], stderr_to_stdout: true, env: env) do
      {_output, 0} ->
        version = detect_version(bin_dir, package)
        {:ok, version}

      {output, code} ->
        {:error, "go install failed (exit #{code}): #{String.slice(output, 0..500)}"}
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
  def installed_version(%Recipe{provides: [cmd | _]}, dest_dir) do
    bin_path = Path.join([dest_dir, "bin", cmd])
    extract_binary_version(bin_path, ["version"])
  end

  @impl true
  @spec latest_version(Recipe.t()) :: {:ok, String.t()} | {:error, term()}
  def latest_version(%Recipe{package: package}) do
    # Go proxy API for version info
    pkg = String.downcase(package)
    url = "https://proxy.golang.org/#{pkg}/@latest"

    case System.cmd("curl", ["-fsSL", url], stderr_to_stdout: true) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, %{"Version" => version}} ->
            {:ok, String.trim_leading(version, "v")}

          _ ->
            {:error, "Failed to parse Go proxy response"}
        end

      {output, _} ->
        {:error, "Go proxy request failed: #{String.slice(output, 0..200)}"}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec detect_version(String.t(), String.t()) :: String.t()
  defp detect_version(bin_dir, package) do
    bin_name = package |> String.split("/") |> List.last()
    bin_path = Path.join(bin_dir, bin_name)

    case extract_binary_version(bin_path, ["version"]) do
      {:ok, version} -> version
      nil -> "unknown"
    end
  end

  @spec extract_binary_version(String.t(), [String.t()]) :: {:ok, String.t()} | nil
  defp extract_binary_version(bin_path, args) do
    if File.exists?(bin_path) do
      case System.cmd(bin_path, args, stderr_to_stdout: true) do
        {output, 0} -> parse_semver(output)
        _ -> nil
      end
    else
      nil
    end
  end

  @spec parse_semver(String.t()) :: {:ok, String.t()} | nil
  defp parse_semver(output) do
    case Regex.run(~r/v?(\d+\.\d+\.\d+)/, output) do
      [_, version] -> {:ok, version}
      _ -> nil
    end
  end
end
