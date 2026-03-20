defmodule Minga.Tool.Installer.Cargo do
  @moduledoc """
  Installs Rust tools via `cargo install`.

  Uses `CARGO_INSTALL_ROOT={dest_dir}` to install the binary into
  `{dest_dir}/bin/`, which is then symlinked into `tools/bin/`.

  Requires `cargo` to be on PATH.
  """

  @behaviour Minga.Tool.Installer

  alias Minga.Tool.Recipe

  @impl true
  @spec install(Recipe.t(), String.t(), Minga.Tool.Installer.progress_callback()) ::
          {:ok, String.t()} | {:error, term()}
  def install(%Recipe{package: package} = _recipe, dest_dir, progress) do
    progress.(:installing, "Installing #{package} via cargo...")
    File.mkdir_p!(dest_dir)

    env = [{"CARGO_INSTALL_ROOT", dest_dir}]

    case System.cmd("cargo", ["install", package], stderr_to_stdout: true, env: env) do
      {output, 0} ->
        version = extract_version_from_output(output, package)
        {:ok, version}

      {output, code} ->
        {:error, "cargo install failed (exit #{code}): #{String.slice(output, 0..500)}"}
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
    extract_binary_version(bin_path)
  end

  @impl true
  @spec latest_version(Recipe.t()) :: {:ok, String.t()} | {:error, term()}
  def latest_version(%Recipe{package: package}) do
    url = "https://crates.io/api/v1/crates/#{package}"

    case System.cmd("curl", ["-fsSL", "-H", "User-Agent: minga-tool-manager", url],
           stderr_to_stdout: true
         ) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, %{"crate" => %{"max_version" => version}}} -> {:ok, version}
          _ -> {:error, "Failed to parse crates.io response"}
        end

      {output, _} ->
        {:error, "crates.io request failed: #{String.slice(output, 0..200)}"}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec extract_version_from_output(String.t(), String.t()) :: String.t()
  defp extract_version_from_output(output, _package) do
    case Regex.run(~r/v(\d+\.\d+\.\d+)/, output) do
      [_, version] -> version
      _ -> "unknown"
    end
  end

  @spec extract_binary_version(String.t()) :: {:ok, String.t()} | nil
  defp extract_binary_version(bin_path) do
    with true <- File.exists?(bin_path),
         {output, 0} <- System.cmd(bin_path, ["--version"], stderr_to_stdout: true),
         [_, version] <- Regex.run(~r/(\d+\.\d+\.\d+)/, output) do
      {:ok, version}
    else
      _ -> nil
    end
  end
end
