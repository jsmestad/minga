defmodule Minga.Extension.Hex do
  @moduledoc """
  Resolves hex-sourced extensions via Mix.install/2.

  All hex extensions are installed in a single `Mix.install/2` call at
  startup. This handles dependency resolution, downloading, and
  compilation. Results are cached by Mix (keyed on the dep list hash),
  so subsequent boots with the same extensions skip all network and
  compilation work.

  ## Limitations

  `Mix.install/2` can only be called once per VM (or again with
  `force: true`). On config reload, if the hex dep list changed, we
  call `Mix.install/2` with `force: true` to reinstall everything.
  """

  alias Minga.Extension.Entry
  alias Minga.Extension.Registry, as: ExtRegistry

  @typedoc "A Mix dep tuple ready for Mix.install/2."
  @type mix_dep :: {atom(), String.t()} | {atom(), String.t(), keyword()}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Installs all hex-sourced extensions from the registry via Mix.install/2.

  Collects every extension with `source_type: :hex`, builds a dep list,
  and calls `Mix.install/2` once. Returns `:ok` if successful or if
  there are no hex extensions. Returns `{:error, reason}` if Mix.install
  fails (network error, resolution failure, compile error).

  After a successful install, extension modules are on the code path
  and can be loaded with `Code.ensure_loaded?/1`.
  """
  @spec install_all() :: :ok | {:error, String.t()}
  @spec install_all(GenServer.server()) :: :ok | {:error, String.t()}
  def install_all, do: install_all(ExtRegistry)

  def install_all(registry) do
    deps = collect_hex_deps(registry)

    case deps do
      [] ->
        :ok

      deps ->
        do_install(deps)
    end
  end

  @doc """
  Reinstalls all hex extensions with `force: true`.

  Used during config reload when the hex dep list has changed. Forces
  Mix.install/2 to re-resolve, re-download, and re-compile everything.
  """
  @spec reinstall_all() :: :ok | {:error, String.t()}
  @spec reinstall_all(GenServer.server()) :: :ok | {:error, String.t()}
  def reinstall_all, do: reinstall_all(ExtRegistry)

  def reinstall_all(registry) do
    deps = collect_hex_deps(registry)

    case deps do
      [] ->
        :ok

      deps ->
        do_install(deps, force: true)
    end
  end

  @doc """
  Collects hex deps from the registry as Mix.install-compatible tuples.

  Returns a list like `[{:minga_snippets, "~> 0.3"}, {:other_ext, ">= 0.0.0"}]`.
  Extensions without a version constraint default to `">= 0.0.0"` (latest).
  """
  @spec collect_hex_deps(GenServer.server()) :: [mix_dep()]
  def collect_hex_deps(registry) do
    registry
    |> ExtRegistry.all()
    |> Enum.filter(fn {_name, entry} -> entry.source_type == :hex end)
    |> Enum.map(fn {_name, %Entry{hex: hex}} -> to_mix_dep(hex) end)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec do_install([mix_dep()], keyword()) :: :ok | {:error, String.t()}
  defp do_install(deps, opts \\ []) do
    Minga.Log.info(:config, "Installing #{length(deps)} hex extension(s)...")

    Mix.install(deps, opts)
    :ok
  rescue
    e in [Mix.Error] ->
      msg = "Mix.install failed: #{Exception.message(e)}"
      Minga.Log.warning(:config, msg)
      {:error, msg}

    e ->
      msg = "Hex extension install error: #{Exception.message(e)}"
      Minga.Log.warning(:config, msg)
      {:error, msg}
  end

  @spec to_mix_dep(%{package: String.t(), version: String.t() | nil}) :: mix_dep()
  defp to_mix_dep(%{package: package, version: nil}) do
    {String.to_atom(package), ">= 0.0.0"}
  end

  defp to_mix_dep(%{package: package, version: version}) do
    {String.to_atom(package), version}
  end
end
