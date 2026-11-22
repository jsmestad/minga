defmodule Minga.Extension.Hex do
  @moduledoc """
  Resolves hex-sourced extensions via Mix.install/2.

  All hex extensions are installed in a single `Mix.install/2` call at
  startup. This handles dependency resolution, downloading, and
  compilation. Results are cached by Mix (keyed on the dep list hash),
  so subsequent boots with the same extensions skip all network and
  compilation work.

  ## Development launcher

  `Mix.install/2` cannot run inside a Mix project, and `bin/minga` runs Minga through
  `mix minga`. In that case the install runs in a disposable OS process through
  `Minga.Extension.HexIsolatedInstall`, which builds into Minga's data directory and appends
  the resulting `ebin` directories to the code path without letting them shadow host modules.
  Admission is the same in both cases.

  ## Limitations

  `Mix.install/2` can only be called once per VM (or again with
  `force: true`). On config reload, if the hex dep list changed, we
  call `Mix.install/2` with `force: true` to reinstall everything.
  """

  alias Minga.Extension.Entry
  alias Minga.Extension.HexIsolatedInstall
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Log
  alias Minga.Telemetry.StartupProgress

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
  and can be loaded with `Code.ensure_loaded?/1`. Source admission starts each application.
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

  Returns a list like `[{:minga_snippets, "~> 0.3", hex: "minga_snippets"}, {:other_ext, ">= 0.0.0", hex: "other_ext"}]`.
  Extensions without a version constraint default to `">= 0.0.0"` (latest).
  """
  @spec collect_hex_deps(GenServer.server()) :: [mix_dep()]
  def collect_hex_deps(registry) do
    registry
    |> ExtRegistry.all()
    |> Enum.filter(fn {_name, entry} -> entry.source_type == :hex end)
    |> Enum.map(fn {name, %Entry{hex: hex}} -> to_mix_dep(name, hex) end)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec do_install([mix_dep()], keyword()) :: :ok | {:error, String.t()}
  defp do_install(deps, opts \\ []) do
    Log.info(:config, "Installing #{Enum.count(deps)} hex extension(s)...")
    applications = Enum.map(deps, &elem(&1, 0))

    StartupProgress.during_hex_install(applications, fn ->
      if inside_mix_project?(),
        do: install_isolated(deps, applications, opts),
        else: install_in_vm(deps, opts)
    end)
  end

  # `Mix.install/2` refuses to run inside a Mix project, which is how the development
  # launcher (`bin/minga` -> `mix minga`) runs Minga. Release builds have no Mix project.
  @spec inside_mix_project?() :: boolean()
  defp inside_mix_project? do
    Code.ensure_loaded?(Mix.ProjectStack) and is_pid(Process.whereis(Mix.ProjectStack)) and
      Mix.Project.get() != nil
  end

  @spec install_isolated([mix_dep()], [atom()], keyword()) :: :ok | {:error, String.t()}
  defp install_isolated(deps, applications, opts) do
    Log.info(
      :config,
      "Installing hex extensions in an isolated build (running inside a Mix project)"
    )

    case HexIsolatedInstall.install(deps, applications, force: Keyword.get(opts, :force, false)) do
      {:ok, _ebins} ->
        :ok

      {:error, reason} ->
        msg =
          "Hex extension install failed. Load the extension from a local checkout with " <>
            "`path:` to skip Hex.\n#{reason}"

        Log.warning(:config, msg)
        {:error, msg}
    end
  end

  @spec install_in_vm([mix_dep()], keyword()) :: :ok | {:error, String.t()}
  defp install_in_vm(deps, opts) do
    # Source admission starts OTP applications after the compiler status has cleared.
    Mix.install(deps, Keyword.put(opts, :start_applications, false))
    :ok
  rescue
    e in [Mix.Error] ->
      msg = "Mix.install failed: #{Exception.message(e)}"
      Log.warning(:config, msg)
      {:error, msg}

    e ->
      msg = "Hex extension install error: #{Exception.message(e)}"
      Log.warning(:config, msg)
      {:error, msg}
  end

  @spec to_mix_dep(atom(), %{package: String.t(), version: String.t() | nil, app: atom()}) ::
          mix_dep()
  defp to_mix_dep(_name, %{app: app, package: package, version: nil}) do
    {app, ">= 0.0.0", hex: package}
  end

  defp to_mix_dep(_name, %{app: app, package: package, version: version}) do
    {app, version, hex: package}
  end
end
