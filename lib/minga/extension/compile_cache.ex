defmodule Minga.Extension.CompileCache do
  @moduledoc """
  On-disk compile cache for path/git-sourced extensions.

  Path and git extensions ship as `.ex` source and were recompiled from
  scratch on every boot (`Kernel.ParallelCompiler`), costing hundreds of
  milliseconds per extension on the startup critical path. This module
  compiles each extension once, writes the resulting `.beam` files to a
  cache keyed by a hash of the source plus the Elixir/ERTS versions, and on
  later boots loads those beams directly (a few milliseconds) instead of
  recompiling.

  ## Invalidation

  The cache key is derived from the *content* of every source file (and the
  toolchain version), so editing an extension produces a new key and forces a
  recompile. This keeps dev hot-reload correct: a changed file is a cache
  miss. After a successful compile we prune the extension's other (stale) keys
  so the cache holds one entry per extension.

  Beams are toolchain- and minga-specific, so the key also includes the Elixir
  and ERTS versions and minga's own application version. A runtime upgrade or a
  minga release (which bumps `:minga`'s version) invalidates every entry
  automatically, so an extension compiled against an older minga API is never
  loaded against a newer one.

  Caching can be disabled with `config :minga, extension_compile_cache: false`,
  which falls back to the previous in-memory behaviour. Dev and test disable it:
  dev so that in-progress edits to minga's own modules always recompile
  extensions (no stale-beam surprises during hot-reload), and test for
  hermeticity.
  """

  alias Minga.Extension.CodeLease

  @type result ::
          {:ok, %{modules: [module()], diagnostics: [map()], source: :cache | :compiled}}
          | {:error, String.t()}

  @doc """
  Ensures the extension's modules are loaded, compiling and caching on a miss.

  `root` is the extension directory; `files` are its sorted `.ex` paths.
  Returns the loaded modules plus any compile diagnostics (empty on a cache
  hit). The caller picks the module implementing the extension behaviour.
  """
  @spec load_or_compile(String.t(), [String.t()], keyword()) :: result()
  def load_or_compile(root, files, opts \\ [])

  def load_or_compile(_root, [], _opts), do: {:error, "no source files to compile"}

  def load_or_compile(root, files, opts) when is_binary(root) and is_list(files) do
    if Keyword.get(opts, :enabled, enabled?()) do
      load_cached(root, files, opts)
    else
      compile_in_memory(files)
    end
  end

  @spec load_cached(String.t(), [String.t()], keyword()) :: result()
  defp load_cached(root, files, opts) do
    with {:ok, key} <- content_key(root, files) do
      cache_root = Keyword.get(opts, :cache_dir, default_cache_dir())
      ext_dir = Path.join(cache_root, ext_id(root))
      dir = Path.join(ext_dir, key)
      source = Keyword.get(opts, :source)
      code_lease = Keyword.get(opts, :code_lease, CodeLease)

      case load_from_cache(dir, source, code_lease) do
        {:ok, modules} -> {:ok, %{modules: modules, diagnostics: [], source: :cache}}
        :miss -> compile_and_cache(files, ext_dir, dir, source, code_lease)
      end
    end
  end

  # ── Cache hit ─────────────────────────────────────────────────────────

  @spec load_from_cache(
          String.t(),
          Minga.Extension.ContributionCleanup.contribution_source() | nil,
          GenServer.server()
        ) :: {:ok, [module()]} | :miss
  defp load_from_cache(dir, source, code_lease) do
    beams = Path.wildcard(Path.join(dir, "*.beam"))

    case beams do
      [] ->
        :miss

      _ ->
        load_beams(beams, source, code_lease)
    end
  end

  @spec load_beams(
          [String.t()],
          Minga.Extension.ContributionCleanup.contribution_source() | nil,
          GenServer.server()
        ) :: {:ok, [module()]} | :miss
  defp load_beams(beams, source, code_lease) do
    Enum.reduce_while(beams, {:ok, []}, fn beam, {:ok, acc} ->
      # Purge any already-loaded version first so the on-disk beam becomes the
      # current code (matters for dev hot-reload, where an older version may
      # still be loaded). load_abs takes the path without the .beam extension.
      module = beam |> Path.basename() |> Path.rootname() |> String.to_atom()

      with :ok <- CodeLease.purge_module(source, module, server: code_lease),
           {:module, loaded} <- :code.load_abs(String.to_charlist(Path.rootname(beam))) do
        {:cont, {:ok, [loaded | acc]}}
      else
        _error -> {:halt, :miss}
      end
    end)
  end

  # ── Cache miss: compile and persist ─────────────────────────────────────

  @spec compile_and_cache(
          [String.t()],
          String.t(),
          String.t(),
          Minga.Extension.ContributionCleanup.contribution_source() | nil,
          GenServer.server()
        ) :: result()
  defp compile_and_cache(files, ext_dir, dir, source, code_lease) do
    File.mkdir_p!(dir)

    {outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        Kernel.ParallelCompiler.compile_to_path(files, dir, return_diagnostics: true)
      end)

    case outcome do
      {:ok, _modules, _diag} ->
        prune_stale_keys(ext_dir, dir)

        # Load from the freshly written beams so the on-disk version is the
        # one in memory. compile_to_path writes the beams but does not reload
        # a module that was already loaded (e.g. a prior dev-reload version).
        case load_from_cache(dir, source, code_lease) do
          {:ok, modules} ->
            {:ok, %{modules: modules, diagnostics: diagnostics, source: :compiled}}

          :miss ->
            File.rm_rf(dir)
            {:error, "compiled beams could not be loaded"}
        end

      {:error, _errors, _diag} ->
        File.rm_rf(dir)
        {:error, "extension compilation failed (see *Messages*)"}
    end
  rescue
    e in [SyntaxError, TokenMissingError, CompileError] ->
      File.rm_rf(dir)
      {:error, "compile error: #{Exception.message(e)}"}

    e ->
      File.rm_rf(dir)
      {:error, "error: #{Exception.message(e)}"}
  catch
    kind, reason ->
      File.rm_rf(dir)
      {:error, "error: #{inspect(kind)} #{inspect(reason)}"}
  end

  # Keep only the just-built key for this extension; remove older versions.
  @spec prune_stale_keys(String.t(), String.t()) :: :ok
  defp prune_stale_keys(ext_dir, keep_dir) do
    keep = Path.basename(keep_dir)

    case File.ls(ext_dir) do
      {:ok, entries} ->
        for entry <- entries, entry != keep do
          File.rm_rf(Path.join(ext_dir, entry))
        end

        :ok

      {:error, _} ->
        :ok
    end
  end

  # ── Caching disabled: previous in-memory behaviour ──────────────────────

  @spec compile_in_memory([String.t()]) :: result()
  defp compile_in_memory(files) do
    {outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        Kernel.ParallelCompiler.compile(files, return_diagnostics: true)
      end)

    case outcome do
      {:ok, modules, _diag} ->
        {:ok, %{modules: modules, diagnostics: diagnostics, source: :compiled}}

      {:error, _errors, _diag} ->
        {:error, "extension compilation failed (see *Messages*)"}
    end
  rescue
    e in [SyntaxError, TokenMissingError, CompileError] ->
      {:error, "compile error: #{Exception.message(e)}"}

    e ->
      {:error, "error: #{Exception.message(e)}"}
  catch
    kind, reason ->
      {:error, "error: #{inspect(kind)} #{inspect(reason)}"}
  end

  # ── Keys and paths ──────────────────────────────────────────────────────

  # Stable per-location id so we can prune an extension's old versions.
  @spec ext_id(String.t()) :: String.t()
  defp ext_id(root) do
    :sha256
    |> :crypto.hash(Path.expand(root))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  # Content + toolchain hash. Relative paths keep the key stable regardless of
  # where the extension dir lives on disk. Returns an error (rather than raising)
  # if a source file vanished between globbing and reading.
  @spec content_key(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  defp content_key(root, files) do
    expanded_root = Path.expand(root)

    payload =
      files
      |> Enum.sort()
      |> Enum.flat_map(fn file ->
        case File.read(file) do
          {:ok, content} -> [Path.relative_to(file, expanded_root), "\0", content, "\0"]
          {:error, reason} -> throw({:read_error, file, reason})
        end
      end)

    digest = :crypto.hash(:sha256, [version_tag(), "\0" | payload])
    {:ok, Base.url_encode64(digest, padding: false)}
  catch
    {:read_error, file, reason} ->
      {:error, "could not read extension source #{file}: #{inspect(reason)}"}
  end

  # Beams are tied to the toolchain *and* to minga itself: an extension compiles
  # against minga's modules, so a minga build that changes an extension-facing API
  # must invalidate cached extension beams even when the extension source is
  # unchanged. Releases bump :minga's version, which busts the cache here. (Dev
  # disables the cache entirely so in-progress minga edits always recompile.)
  @spec version_tag() :: String.t()
  defp version_tag do
    minga_vsn = to_string(Application.spec(:minga, :vsn) || "0")
    "minga-#{minga_vsn}-elixir-#{System.version()}-erts-#{:erlang.system_info(:version)}"
  end

  @spec enabled?() :: boolean()
  defp enabled?, do: Application.get_env(:minga, :extension_compile_cache, true)

  @spec default_cache_dir() :: String.t()
  defp default_cache_dir do
    Application.get_env(
      :minga,
      :extension_compile_cache_dir,
      Path.join(Path.expand("~/.local/share/minga"), "extension_cache")
    )
  end
end
