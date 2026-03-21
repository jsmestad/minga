defmodule Minga.Tool.Installer.GitHubRelease do
  @moduledoc """
  Installs tools from GitHub release assets.

  Downloads pre-built binaries from a GitHub repository's latest release.
  Detects the current platform (OS + architecture) and selects the
  matching asset. Handles .tar.gz, .tar.xz, .gz, and .zip archives.

  ## Platform detection

  Maps `{:os.type(), :erlang.system_info(:system_architecture)}` to
  canonical platform names, then matches against common synonyms used
  in release asset naming:

  - OS: `"darwin"` also matches `"macos"` in asset names
  - Arch: `"arm64"` also matches `"aarch64"`;
          `"amd64"` also matches `"x86_64"` and `"x64"`

  Only recognized archive formats (.tar.gz, .tar.xz, .gz, .zip) are
  considered, filtering out signature files (.minisig, .sha256) and
  editor extensions (.vsix).

  Recipes with non-standard naming can provide an `:asset_pattern`
  function for custom matching.
  """

  @behaviour Minga.Tool.Installer

  alias Minga.Tool.Recipe

  @github_api "https://api.github.com"

  @impl true
  @spec install(Recipe.t(), String.t(), Minga.Tool.Installer.progress_callback()) ::
          {:ok, String.t()} | {:error, term()}
  def install(%Recipe{package: repo} = recipe, dest_dir, progress) do
    progress.(:downloading, "Fetching latest release from #{repo}...")

    with {:ok, release} <- fetch_latest_release(repo),
         {:ok, asset} <- find_platform_asset(release, recipe),
         {:ok, version} <- extract_version(release) do
      progress.(:downloading, "Downloading #{asset["name"]}...")
      download_url = asset["browser_download_url"]

      bin_dir = Path.join(dest_dir, "bin")
      File.mkdir_p!(bin_dir)

      with {:ok, tmp_path} <- download_asset(download_url),
           :ok <- progress.(:extracting, "Extracting #{asset["name"]}..."),
           :ok <- extract_asset(tmp_path, asset["name"], bin_dir) do
        File.rm(tmp_path)

        progress.(:verifying, "Setting permissions...")
        make_binaries_executable(bin_dir)

        {:ok, version}
      end
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
  def installed_version(_recipe, _dest_dir) do
    # Version is tracked by the receipt.json, not detectable from binaries
    nil
  end

  @impl true
  @spec latest_version(Recipe.t()) :: {:ok, String.t()} | {:error, term()}
  def latest_version(%Recipe{package: repo}) do
    case fetch_latest_release(repo) do
      {:ok, release} -> extract_version(release)
      error -> error
    end
  end

  # ── Platform detection ──────────────────────────────────────────────────────

  @doc "Returns the platform suffix for the current system (e.g., `darwin_arm64`)."
  @spec platform_suffix() :: String.t()
  def platform_suffix do
    os = detect_os()
    arch = detect_arch()
    "#{os}_#{arch}"
  end

  @spec detect_os() :: String.t()
  defp detect_os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, :linux} -> "linux"
      {:win32, _} -> "windows"
      _ -> "unknown"
    end
  end

  @spec detect_arch() :: String.t()
  defp detect_arch do
    arch_str = :erlang.system_info(:system_architecture) |> to_string()
    classify_arch(arch_str)
  end

  @spec classify_arch(String.t()) :: String.t()
  defp classify_arch(arch) do
    if String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") do
      "arm64"
    else
      "amd64"
    end
  end

  # ── GitHub API ──────────────────────────────────────────────────────────────

  @spec fetch_latest_release(String.t()) :: {:ok, map()} | {:error, term()}
  defp fetch_latest_release(repo) do
    url = "#{@github_api}/repos/#{repo}/releases/latest"
    headers = base_headers()

    case http_get(url, headers) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, release} -> {:ok, release}
          {:error, _} -> {:error, "Failed to parse GitHub API response"}
        end

      {:error, reason} ->
        {:error, "GitHub API request failed: #{inspect(reason)}"}
    end
  end

  @spec find_platform_asset(map(), Recipe.t()) :: {:ok, map()} | {:error, term()}
  defp find_platform_asset(%{"assets" => assets}, %Recipe{asset_pattern: pattern}) do
    suffix = platform_suffix()
    matcher = build_asset_matcher(pattern, suffix)

    case Enum.find(assets, matcher) do
      nil ->
        names = Enum.map_join(assets, ", ", & &1["name"])
        {:error, "No matching asset for #{suffix}. Available: #{names}"}

      asset ->
        {:ok, asset}
    end
  end

  @spec build_asset_matcher((String.t(), String.t() -> boolean()) | nil, String.t()) ::
          (map() -> boolean())
  defp build_asset_matcher(pattern, suffix) when is_function(pattern, 2) do
    fn asset -> pattern.(asset["name"], suffix) end
  end

  defp build_asset_matcher(_pattern, _suffix) do
    os_names = os_synonyms(detect_os())
    arch_names = arch_synonyms(detect_arch())

    fn asset ->
      name = String.downcase(asset["name"] || "")

      recognized_archive?(name) and
        Enum.any?(os_names, &String.contains?(name, &1)) and
        Enum.any?(arch_names, &String.contains?(name, &1))
    end
  end

  @spec os_synonyms(String.t()) :: [String.t()]
  defp os_synonyms("darwin"), do: ["darwin", "macos"]
  defp os_synonyms("linux"), do: ["linux"]
  defp os_synonyms("windows"), do: ["windows", "win32", "win"]
  defp os_synonyms(other), do: [other]

  @spec arch_synonyms(String.t()) :: [String.t()]
  defp arch_synonyms("arm64"), do: ["arm64", "aarch64"]
  defp arch_synonyms("amd64"), do: ["amd64", "x86_64", "x64"]
  defp arch_synonyms(other), do: [other]

  @spec recognized_archive?(String.t()) :: boolean()
  defp recognized_archive?(name) do
    String.ends_with?(name, ".tar.gz") or
      String.ends_with?(name, ".tgz") or
      String.ends_with?(name, ".tar.xz") or
      String.ends_with?(name, ".gz") or
      String.ends_with?(name, ".zip")
  end

  @spec extract_version(map()) :: {:ok, String.t()} | {:error, term()}
  defp extract_version(%{"tag_name" => tag}) when is_binary(tag) do
    # Strip leading "v" if present
    version = String.trim_leading(tag, "v")
    {:ok, version}
  end

  defp extract_version(_), do: {:error, "No tag_name in release"}

  # ── Download and extract ────────────────────────────────────────────────────

  @spec download_asset(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp download_asset(url) do
    tmp_path = Path.join(System.tmp_dir!(), "minga_tool_#{:erlang.unique_integer([:positive])}")

    case System.cmd("curl", ["-fSL", "-o", tmp_path, url], stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, tmp_path}

      {output, code} ->
        {:error, "Download failed (exit #{code}): #{String.slice(output, 0..200)}"}
    end
  end

  @spec extract_asset(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defp extract_asset(tmp_path, asset_name, dest_dir) do
    name_lower = String.downcase(asset_name)
    archive_type = detect_archive_type(name_lower)
    result = run_extraction(archive_type, tmp_path, asset_name, dest_dir)

    case result do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, "Extraction failed (exit #{code}): #{String.slice(output, 0..200)}"}
    end
  end

  @type archive_type :: :tar_gz | :tar_xz | :gz | :zip | :raw

  @spec detect_archive_type(String.t()) :: archive_type()
  defp detect_archive_type(name) do
    detect_tar(name) || detect_single_compressed(name) || detect_zip_or_raw(name)
  end

  @spec detect_tar(String.t()) :: :tar_gz | :tar_xz | nil
  defp detect_tar(name) do
    if String.ends_with?(name, ".tar.gz") or String.ends_with?(name, ".tgz") do
      :tar_gz
    else
      if String.ends_with?(name, ".tar.xz") or String.ends_with?(name, ".txz"),
        do: :tar_xz
    end
  end

  @spec detect_single_compressed(String.t()) :: :gz | nil
  defp detect_single_compressed(name) do
    if String.ends_with?(name, ".gz"), do: :gz, else: nil
  end

  @spec detect_zip_or_raw(String.t()) :: :zip | :raw
  defp detect_zip_or_raw(name) do
    if String.ends_with?(name, ".zip"), do: :zip, else: :raw
  end

  @spec run_extraction(archive_type(), String.t(), String.t(), String.t()) ::
          {String.t(), integer()}
  defp run_extraction(:tar_gz, tmp_path, _asset_name, dest_dir) do
    System.cmd("tar", ["xzf", tmp_path, "-C", dest_dir], stderr_to_stdout: true)
  end

  defp run_extraction(:tar_xz, tmp_path, _asset_name, dest_dir) do
    System.cmd("tar", ["xJf", tmp_path, "-C", dest_dir], stderr_to_stdout: true)
  end

  defp run_extraction(:gz, tmp_path, asset_name, dest_dir) do
    base_name = String.replace(asset_name, ~r/\.gz$/i, "")
    out_path = Path.join(dest_dir, base_name)
    System.cmd("sh", ["-c", "gunzip -c #{tmp_path} > #{out_path}"], stderr_to_stdout: true)
  end

  defp run_extraction(:zip, tmp_path, _asset_name, dest_dir) do
    System.cmd("unzip", ["-o", tmp_path, "-d", dest_dir], stderr_to_stdout: true)
  end

  defp run_extraction(:raw, tmp_path, asset_name, dest_dir) do
    dest = Path.join(dest_dir, asset_name)
    File.cp!(tmp_path, dest)
    {"", 0}
  end

  @spec make_binaries_executable(String.t()) :: :ok
  defp make_binaries_executable(bin_dir) do
    case File.ls(bin_dir) do
      {:ok, files} ->
        files
        |> Enum.map(&Path.join(bin_dir, &1))
        |> Enum.filter(&File.regular?/1)
        |> Enum.each(&File.chmod!(&1, 0o755))

        :ok

      {:error, _} ->
        :ok
    end
  end

  # ── HTTP ────────────────────────────────────────────────────────────────────

  @spec http_get(String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, term()}
  defp http_get(url, headers) do
    header_args =
      Enum.flat_map(headers, fn {k, v} -> ["-H", "#{k}: #{v}"] end)

    case System.cmd("curl", ["-fsSL" | header_args] ++ [url], stderr_to_stdout: true) do
      {body, 0} ->
        {:ok, body}

      {output, code} ->
        {:error, "HTTP GET failed (exit #{code}): #{String.slice(output, 0..200)}"}
    end
  end

  @spec base_headers() :: [{String.t(), String.t()}]
  defp base_headers do
    headers = [{"Accept", "application/vnd.github+json"}, {"User-Agent", "minga-tool-manager"}]

    # Use gh auth token if available for higher rate limits
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} ->
        token = String.trim(token)
        [{"Authorization", "Bearer #{token}"} | headers]

      _ ->
        headers
    end
  end
end
