defmodule Mix.Tasks.Dialyzer.Incremental do
  @shortdoc "Runs OTP's native incremental Dialyzer"

  @moduledoc """
  Runs native OTP incremental Dialyzer with the same project scope, warning
  configuration, and warning filters as Dialyxir.

  Incremental PLTs are kept beneath the active Mix build environment. When
  the current configuration cache is absent, a cache from the same OTP and
  Elixir toolchain seeds the new analysis. Remove all caches with
  `mix dialyzer.incremental.clean`.
  """

  use Mix.Task

  alias Dialyxir.Dialyzer
  alias Dialyxir.Project

  @default_warnings [:unknown]
  @dialyxir_core_apps [:erts, :kernel, :stdlib, :crypto, :elixir]

  @type cache_paths :: %{
          root: Path.t(),
          plt: Path.t(),
          legacy_plt: Path.t(),
          lock: Path.t(),
          compatible_prefix: String.t()
        }

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([]) do
    Mix.ensure_application!(:dialyzer)
    Mix.Task.run("deps.loadpaths")

    apps = Project.cons_apps()
    project_files = Project.dialyzer_files()
    analysis_dirs = application_dirs(Enum.uniq(@dialyxir_core_apps ++ apps))
    cache = cache_paths()

    File.mkdir_p!(cache.root)

    with_lock(cache.lock, fn ->
      initial_plt = initial_plt(cache)
      Mix.shell().info("Incremental Dialyzer seed: #{seed_label(cache, initial_plt)}")
      run_with_cache(cache, initial_plt, project_files, analysis_dirs)
    end)
  end

  def run(_args), do: Mix.raise("mix dialyzer.incremental does not accept arguments")

  @doc "Returns the cache paths for the active toolchain and Dialyzer configuration."
  @spec cache_paths() :: cache_paths()
  def cache_paths do
    root = Path.join(Mix.Project.build_path(), "dialyzer_incremental")
    otp = otp_version()
    elixir = System.version()
    key = cache_key(otp, elixir, lock_contents(), dialyzer_config())
    toolchain = toolchain_key(otp, elixir)
    compatible_prefix = "incremental-#{toolchain}-"

    %{
      root: root,
      plt: Path.join(root, "#{compatible_prefix}#{key}.plt"),
      legacy_plt: Path.join(root, "incremental-#{key}.plt"),
      lock: Path.join(Mix.Project.build_path(), ".dialyzer_incremental.lock"),
      compatible_prefix: compatible_prefix
    }
  end

  @doc "Builds the cache key from toolchain, lockfile, and Dialyzer configuration inputs."
  @spec cache_key(String.t(), String.t(), binary(), keyword()) :: String.t()
  def cache_key(otp_version, elixir_version, lock_contents, config) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({otp_version, elixir_version, lock_contents, config})
    )
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 24)
  end

  @doc "Builds a cache namespace shared only by the same OTP and Elixir versions."
  @spec toolchain_key(String.t(), String.t()) :: String.t()
  def toolchain_key(otp_version, elixir_version) do
    :crypto.hash(:sha256, :erlang.term_to_binary({otp_version, elixir_version}))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  @doc "Returns the current cache or the newest compatible cache to seed an analysis."
  @spec initial_plt(cache_paths()) :: Path.t()
  def initial_plt(%{plt: plt} = cache) do
    initial_plt(File.exists?(plt), cache)
  end

  defp initial_plt(true, %{plt: plt}), do: plt

  defp initial_plt(false, %{legacy_plt: legacy_plt} = cache) do
    initial_plt(File.exists?(legacy_plt), legacy_plt, cache)
  end

  defp initial_plt(true, legacy_plt, _cache), do: legacy_plt
  defp initial_plt(false, _legacy_plt, cache), do: newest_compatible_plt(cache) || cache.plt

  defp seed_label(%{plt: plt}, plt) do
    if File.exists?(plt), do: "current cache", else: "cold start"
  end

  defp seed_label(%{legacy_plt: legacy_plt}, legacy_plt), do: "legacy exact cache"
  defp seed_label(_cache, _initial_plt), do: "same-toolchain cache"

  @doc "Runs a function while exclusively holding the incremental cache lock."
  @spec with_lock(Path.t(), (-> term())) :: term()
  def with_lock(lock_path, fun) when is_function(fun, 0) do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, lock} ->
        try do
          IO.write(lock, "#{System.pid()}\n")
          fun.()
        after
          release_lock!(lock, lock_path)
        end

      {:error, :eexist} ->
        Mix.raise(
          "incremental Dialyzer cache is already locked by another run (#{lock_path}); " <>
            "if no run is active, use `mix dialyzer.incremental.clean --force`"
        )

      {:error, reason} ->
        Mix.raise(
          "could not lock incremental Dialyzer cache #{lock_path}: #{:file.format_error(reason)}"
        )
    end
  end

  @doc "Atomically promotes a completed temporary PLT to the active cache."
  @spec promote_cache(Path.t(), Path.t()) :: :ok | :unchanged
  def promote_cache(temp_path, cache_path), do: promote_cache(temp_path, cache_path, cache_path)

  @doc "Atomically promotes a completed temporary PLT or compatible seed to the active cache."
  @spec promote_cache(Path.t(), Path.t(), Path.t()) :: :ok | :unchanged
  def promote_cache(temp_path, cache_path, seed_path) do
    promote_cache(File.exists?(temp_path), temp_path, cache_path, seed_path)
  end

  defp promote_cache(true, temp_path, cache_path, _seed_path) do
    replace_cache!(temp_path, cache_path)
  end

  # An unchanged incremental run may leave its seed untouched instead of writing the requested output PLT.
  defp promote_cache(false, temp_path, cache_path, seed_path) do
    promote_unchanged_cache(File.exists?(cache_path), temp_path, cache_path, seed_path)
  end

  defp promote_unchanged_cache(true, _temp_path, _cache_path, _seed_path), do: :unchanged

  defp promote_unchanged_cache(false, temp_path, cache_path, seed_path) do
    if File.exists?(seed_path) do
      File.cp!(seed_path, temp_path)
      replace_cache!(temp_path, cache_path)
    else
      Mix.raise("native incremental Dialyzer succeeded without producing a cache")
    end
  end

  defp replace_cache!(temp_path, cache_path) do
    case File.rename(temp_path, cache_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("could not replace incremental Dialyzer cache: #{:file.format_error(reason)}")
    end
  end

  @doc "Formats the recognized native Dialyzer incrementality metrics."
  @spec format_metrics(String.t()) :: String.t() | nil
  def format_metrics(contents) do
    metrics =
      contents
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ": ", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    parts =
      [
        metric(metrics, "changed_or_removed_modules", "changed/removed"),
        metric(metrics, "analysed_modules", "analyzed"),
        metric(metrics, "total_modules", "total")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: "Incrementality: " <> Enum.join(parts, ", ")
  end

  defp run_with_cache(cache, initial_plt, project_files, analysis_dirs) do
    suffix = "#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
    temp_plt = Path.join(cache.root, ".incremental-#{suffix}.plt")
    metrics_path = Path.join(cache.root, ".metrics-#{suffix}.txt")

    args = [
      analysis_type: :incremental,
      init_plt: String.to_charlist(initial_plt),
      output_plt: String.to_charlist(temp_plt),
      files: project_files,
      files_rec: analysis_dirs,
      warning_files: project_files,
      warnings: dialyzer_warnings(),
      metrics_file: String.to_charlist(metrics_path),
      format: [],
      raw: false,
      list_unused_filters: false,
      ignore_exit_status: false,
      quiet_with_result: false
    ]

    try do
      case Dialyzer.dialyze(args, Mix.Tasks.Dialyzer.Incremental.Runner) do
        {status, exit_status, [time | output]} when status in [:ok, :warn] ->
          Mix.shell().info(time)
          Enum.each(output, &report(status, &1))
          metrics = read_metrics!(metrics_path)
          promote_cache(temp_plt, cache.plt, initial_plt)
          Mix.shell().info(metrics)

          if exit_status != 0 do
            Mix.raise("incremental Dialyzer emitted warnings")
          end

          :ok

        {:error, _exit_status, output} ->
          Enum.each(output, fn text -> Mix.shell().error(text) end)
          Mix.raise("native incremental Dialyzer failed; the existing cache was not replaced")
      end
    after
      remove_temporary_file!(temp_plt)
      remove_temporary_file!(metrics_path)
    end
  end

  defp remove_temporary_file!(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "could not remove incremental Dialyzer temporary file #{path}: #{:file.format_error(reason)}"
        )
    end
  end

  defp newest_compatible_plt(%{root: root, compatible_prefix: compatible_prefix}) do
    root
    |> File.ls!()
    |> Enum.filter(fn name ->
      String.starts_with?(name, compatible_prefix) and String.ends_with?(name, ".plt")
    end)
    |> Enum.map(fn name -> cache_with_mtime!(Path.join(root, name)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> List.first()
    |> cache_path()
  end

  defp cache_with_mtime!(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        {path, mtime}

      {:ok, %File.Stat{}} ->
        nil

      {:error, reason} ->
        Mix.raise(
          "could not inspect incremental Dialyzer cache #{path}: #{:file.format_error(reason)}"
        )
    end
  end

  defp cache_path({path, _mtime}), do: path
  defp cache_path(nil), do: nil

  defp application_dirs(apps) do
    apps
    |> Enum.map(fn app -> Application.app_dir(app, "ebin") end)
    |> Enum.uniq()
    |> Enum.map(&String.to_charlist/1)
  end

  defp dialyzer_warnings do
    flags = Enum.map(Project.dialyzer_flags(), &normalize_warning/1)
    flags ++ (@default_warnings -- Project.dialyzer_removed_defaults())
  end

  defp normalize_warning(option) when is_atom(option), do: option

  defp normalize_warning(option) when is_binary(option) do
    option
    |> String.replace_leading("-W", "")
    |> String.replace("--", "")
    |> String.to_atom()
  end

  defp report(:ok, text), do: Mix.shell().info(text)
  defp report(:warn, text), do: Mix.shell().error(text)

  defp release_lock!(lock, lock_path) do
    case File.close(lock) do
      :ok ->
        remove_lock!(lock_path)

      {:error, reason} ->
        Mix.raise(
          "could not close incremental Dialyzer cache lock: #{:file.format_error(reason)}"
        )
    end
  end

  defp remove_lock!(lock_path) do
    case File.rm(lock_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "could not remove incremental Dialyzer cache lock #{lock_path}: #{:file.format_error(reason)}"
        )
    end
  end

  defp read_metrics!(path) do
    case File.read(path) do
      {:ok, contents} ->
        case format_metrics(contents) do
          metrics when is_binary(metrics) -> metrics
          nil -> Mix.raise("native incremental Dialyzer wrote no recognized metrics to #{path}")
        end

      {:error, reason} ->
        Mix.raise(
          "could not read native incremental Dialyzer metrics #{path}: #{:file.format_error(reason)}"
        )
    end
  end

  defp metric(metrics, key, label) do
    case Map.fetch(metrics, key) do
      {:ok, value} -> "#{label} #{value}"
      :error -> nil
    end
  end

  defp otp_version do
    release = :erlang.system_info(:otp_release) |> List.to_string()
    version_file = Path.join([:code.root_dir(), "releases", release, "OTP_VERSION"])

    case File.read(version_file) do
      {:ok, version} -> String.trim(version)
      {:error, _reason} -> release
    end
  end

  defp lock_contents do
    lockfile = Mix.Project.config() |> Keyword.fetch!(:lockfile)

    case File.read(lockfile) do
      {:ok, contents} -> contents
      {:error, :enoent} -> <<>>
      {:error, reason} -> raise File.Error, action: "read file", path: lockfile, reason: reason
    end
  end

  defp dialyzer_config, do: Mix.Project.config()[:dialyzer] || []
end
