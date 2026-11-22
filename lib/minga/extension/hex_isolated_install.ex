defmodule Minga.Extension.HexIsolatedInstall do
  @moduledoc """
  Installs Hex extensions in a disposable, Mix-project-free BEAM OS process.

  `Mix.install/2` refuses to run inside a Mix project, and the development launcher (`bin/minga`) runs Minga through `mix minga`. This module runs `Mix.install/2` in a standalone OS process instead, with a dedicated install directory, and then appends the resulting dependency `ebin` directories to the host code path. Extension admission then proceeds exactly as it does after an in-VM install: `Minga.Extension.Instance.Source` starts the declared application and adopts its modules through `Minga.Extension.ArtifactAdmission`.

  The child process boots with the host code path, so `use Minga.Extension` expands against the real host modules, and `minga_sdk` compiles no stub modules (its `mix.exs` detects the host). Protocol consolidation is disabled in the child because consolidated protocols would replace host modules.

  The host never lets an installed dependency shadow a host module:

    * A dependency application the host already provides is skipped; the host copy wins. A declared extension application that the host already provides is an error.
    * Any other dependency `ebin` that contains a module the host can already load is an error, and no path is added.
    * Accepted paths are appended, not prepended, so host code always wins code-path lookup.
    * An accepted `ebin` must be a real directory under the install directory, with no symbolic link anywhere on its path.

  The install directory must be private to the current user. The child process does not inherit Minga's provider secrets (`MingaAgent.Credentials` key variables, `MINGA_GATEWAY_TOKEN`, and `ANTHROPIC_*`), and URL credentials are redacted from the installer output Minga reports.

  Code admitted into this VM stays resident until the OS process exits. When a later install in the same VM resolves an application to a different version, the install fails and asks for a restart instead of loading a second copy.
  """

  import Bitwise

  alias Minga.Extension.DisposableBeam
  alias Minga.SecureFile

  @default_timeout 600_000
  @max_report_bytes 256 * 1024
  @max_message_chars 8_000
  @max_symlink_depth 40
  @output_tail_lines 30
  @outside_install_dir "isolated Hex installer reported a path outside its install directory"

  # Secrets Minga reads (MingaAgent.Credentials @env_vars and the Gateway token). Package
  # compile-time code runs in the child, so it must not see them.
  @secret_vars ~w(OPENAI_API_KEY GOOGLE_API_KEY OPENROUTER_API_KEY GROQ_API_KEY MISTRAL_API_KEY DEEPSEEK_API_KEY MINGA_GATEWAY_TOKEN)
  @secret_prefixes ["ANTHROPIC_"]

  @typedoc "A Mix dependency tuple whose source is `hex:` or `path:`."
  @type dep :: {atom(), String.t(), [{:hex | :path, String.t()}]}

  @typedoc "Install options."
  @type option ::
          {:install_dir, String.t()}
          | {:force, boolean()}
          | {:timeout, pos_integer()}
          | {:owner_uid, non_neg_integer()}

  @doc """
  Installs `deps` in a disposable OS process and appends their `ebin` directories to the host code path.

  `extension_apps` names the declared extension applications. Returns the appended `ebin` directories.
  """
  @spec install([dep()], [atom()], [option()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def install(deps, extension_apps, opts \\ []) when is_list(deps) and is_list(extension_apps) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, install_dir} <-
           make_install_dir(Keyword.get(opts, :install_dir, default_install_dir()), opts),
         {:ok, encoded_deps} <- encode_deps(deps),
         {:ok, ebins} <- run_child(encoded_deps, install_dir, opts, timeout),
         {:ok, accepted} <- admit_ebins(ebins, install_dir, extension_apps) do
      :ok = Code.append_paths(accepted, cache: false)
      {:ok, accepted}
    end
  end

  @doc """
  Returns the `Port.open/2` `:env` entries that remove Minga's provider secrets from the installer process.

  The installer runs package compile-time code, so it must not inherit `MingaAgent.Credentials` key variables, `ANTHROPIC_*`, or `MINGA_GATEWAY_TOKEN`. Everything else, including `HEX_*`, `MIX_HOME`, `HOME`, `PATH`, and proxy variables, is inherited.
  """
  @spec child_env() :: [{charlist(), false}]
  def child_env do
    for {name, _value} <- System.get_env(),
        name in @secret_vars or String.starts_with?(name, @secret_prefixes),
        do: {String.to_charlist(name), false}
  end

  @doc "Returns the default install directory used for isolated Hex installs."
  @spec default_install_dir() :: String.t()
  def default_install_dir, do: Path.join(Minga.UserPaths.data_dir(), "hex_extension_installs")

  # ── Host side ───────────────────────────────────────────────────────────────

  # Mix builds under the working directory it changes into, and the OS reports that directory
  # with symlinks resolved (for example `/var` -> `/private/var` on macOS). Resolve the install
  # directory up front so the child's paths and the host's containment checks agree.
  @spec make_install_dir(String.t(), [option()]) :: {:ok, String.t()} | {:error, String.t()}
  defp make_install_dir(install_dir, opts) do
    expanded = Path.expand(install_dir)

    with :ok <- create_dir(expanded),
         {:ok, real} <- resolve_real_path(expanded, @max_symlink_depth),
         {:ok, uid} <- owner_uid(opts),
         :ok <- ensure_private_dir(real, uid) do
      {:ok, real}
    end
  end

  @spec create_dir(String.t()) :: :ok | {:error, String.t()}
  defp create_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{path}: #{:file.format_error(reason)}"}
    end
  end

  @spec owner_uid([option()]) :: {:ok, non_neg_integer()} | {:error, String.t()}
  defp owner_uid(opts) do
    case Keyword.fetch(opts, :owner_uid) do
      {:ok, uid} -> {:ok, uid}
      :error -> current_uid()
    end
  end

  @spec current_uid() :: {:ok, non_neg_integer()} | {:error, String.t()}
  defp current_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {uid, 0} -> {:ok, uid |> String.trim() |> String.to_integer()}
      _other -> {:error, "cannot determine the current user for the Hex install directory"}
    end
  rescue
    _error -> {:error, "cannot determine the current user for the Hex install directory"}
  end

  # Other users must not be able to plant code the host will load.
  @spec ensure_private_dir(String.t(), non_neg_integer()) :: :ok | {:error, String.t()}
  defp ensure_private_dir(dir, uid) do
    _ = File.chmod(dir, 0o700)

    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} when (mode &&& 0o022) == 0 ->
        :ok

      {:ok, %File.Stat{type: :directory, uid: ^uid}} ->
        {:error, "Hex install directory #{dir} is group- or world-writable"}

      {:ok, %File.Stat{type: :directory}} ->
        {:error, "Hex install directory #{dir} is not owned by the current user"}

      _other ->
        {:error, "Hex install directory #{dir} is not a directory"}
    end
  end

  @spec resolve_real_path(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp resolve_real_path(path, 0), do: {:error, "too many symbolic links in #{path}"}

  defp resolve_real_path(path, depth) do
    path
    |> Path.split()
    |> Enum.reduce_while({:ok, "/"}, fn component, {:ok, resolved} ->
      resolve_component(resolved, component, depth)
    end)
  end

  @spec resolve_component(String.t(), String.t(), pos_integer()) ::
          {:cont, {:ok, String.t()}} | {:halt, {:error, String.t()}}
  defp resolve_component(resolved, component, depth) do
    candidate = Path.join(resolved, component)

    with {:ok, target} <- File.read_link(candidate),
         {:ok, real} <- resolve_real_path(Path.expand(target, resolved), depth - 1) do
      {:cont, {:ok, real}}
    else
      {:error, message} when is_binary(message) -> {:halt, {:error, message}}
      {:error, _not_a_link} -> {:cont, {:ok, candidate}}
    end
  end

  @spec encode_deps([dep()]) :: {:ok, [map()]} | {:error, String.t()}
  defp encode_deps(deps) do
    Enum.reduce_while(deps, {:ok, []}, fn dep, {:ok, acc} ->
      case encode_dep(dep) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      error -> error
    end
  end

  @spec encode_dep(term()) :: {:ok, map()} | {:error, String.t()}
  defp encode_dep({app, requirement, [{source, value}]})
       when is_atom(app) and is_binary(requirement) and source in [:hex, :path] and
              is_binary(value) do
    {:ok,
     %{
       "app" => Atom.to_string(app),
       "requirement" => requirement,
       "source" => Atom.to_string(source),
       "value" => value
     }}
  end

  defp encode_dep(dep), do: {:error, "unsupported Hex extension dependency: #{inspect(dep)}"}

  @spec run_child([map()], String.t(), [option()], pos_integer()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  defp run_child(encoded_deps, install_dir, opts, timeout) do
    report_path = Path.join(install_dir, ".hex-install-report-#{unique_suffix()}.json")

    request = %{
      "deps" => encoded_deps,
      "install_dir" => install_dir,
      "force" => Keyword.get(opts, :force, false),
      "report_path" => report_path
    }

    result =
      case DisposableBeam.run(:hex_installer, request, install_dir, timeout) do
        :ok ->
          read_report(report_path)

        {:error, :timeout} ->
          {:error, "isolated Hex installer timed out"}

        {:error, :output_limit_exceeded} ->
          {:error, "isolated Hex installer output exceeded limit"}

        {:error, :executable_unavailable} ->
          {:error, "isolated Hex installer could not find erl"}

        {:error, reason} ->
          {:error, "isolated Hex installer failed: #{inspect(reason)}"}
      end

    File.rm(report_path)
    result
  end

  @spec read_report(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  defp read_report(path) do
    with {:ok, binary} <- SecureFile.read(path, @max_report_bytes),
         {:ok, report} <- JSON.decode(binary) do
      decode_report(report)
    else
      _other -> {:error, "isolated Hex installer returned no readable report"}
    end
  end

  @spec decode_report(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  defp decode_report(%{"status" => "ok", "ebin_paths" => paths}) when is_list(paths) do
    if Enum.all?(paths, &is_binary/1),
      do: {:ok, paths},
      else: {:error, "isolated Hex installer returned an invalid report"}
  end

  defp decode_report(%{"status" => "error", "message" => message}) when is_binary(message),
    do: {:error, redact_url_credentials(message)}

  defp decode_report(_report), do: {:error, "isolated Hex installer returned an invalid report"}

  @spec admit_ebins([String.t()], String.t(), [atom()]) ::
          {:ok, [String.t()]} | {:error, String.t()}
  defp admit_ebins(ebins, install_dir, extension_apps) do
    declared = MapSet.new(extension_apps, &Atom.to_string/1)
    resident = MapSet.new(:code.get_path(), &List.to_string/1)

    ebins
    |> Enum.reduce_while({:ok, []}, fn ebin, {:ok, acc} ->
      case admit_ebin(ebin, install_dir, declared) do
        {:ok, :accept} -> {:cont, {:ok, [ebin | acc]}}
        {:ok, skipped} when skipped in [:host_provided, :already_resident] -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, accepted} ->
        {:ok,
         accepted |> Enum.reverse() |> Enum.uniq() |> Enum.reject(&MapSet.member?(resident, &1))}

      error ->
        error
    end
  end

  @spec admit_ebin(String.t(), String.t(), MapSet.t(String.t())) ::
          {:ok, :accept | :host_provided | :already_resident} | {:error, String.t()}
  defp admit_ebin(ebin, install_dir, declared) do
    with {:ok, app} <- ebin_application(ebin, install_dir),
         :ok <- real_directory(ebin) do
      case previous_install(app, ebin, install_dir) do
        nil -> classify_ebin(ebin, app, install_dir, MapSet.member?(declared, app))
        previous -> compare_resident_version(app, previous, ebin)
      end
    end
  end

  # An earlier isolated install in this VM already appended this application. Its modules may
  # be loaded and admitted, and admitted code stays resident, so removing the old path would
  # leave a mix of versions. The same version is already resident; another version needs a
  # fresh Minga process.
  @spec previous_install(String.t(), String.t(), String.t()) :: String.t() | nil
  defp previous_install(app, ebin, install_dir) do
    Enum.find_value(:code.get_path(), fn path ->
      path = List.to_string(path)

      if path != ebin and ebin_application(path, install_dir) == {:ok, app},
        do: path,
        else: nil
    end)
  end

  @spec compare_resident_version(String.t(), String.t(), String.t()) ::
          {:ok, :already_resident} | {:error, String.t()}
  defp compare_resident_version(app, previous, ebin) do
    case {app_version(previous, app), app_version(ebin, app)} do
      {same, same} when is_binary(same) ->
        {:ok, :already_resident}

      {old, new} ->
        {:error,
         "restart Minga to switch :#{app} from #{old || "an unknown version"} " <>
           "to #{new || "an unknown version"}"}
    end
  end

  @spec app_version(String.t(), String.t()) :: String.t() | nil
  defp app_version(ebin, app) do
    case :file.consult(String.to_charlist(Path.join(ebin, app <> ".app"))) do
      {:ok, [{:application, _name, properties}]} when is_list(properties) ->
        properties |> Keyword.get(:vsn) |> version_string()

      _other ->
        nil
    end
  end

  @spec version_string(term()) :: String.t() | nil
  defp version_string(vsn) when is_list(vsn), do: List.to_string(vsn)
  defp version_string(_vsn), do: nil

  # The host copy of a shared dependency wins. A declared extension must come from the install.
  @spec classify_ebin(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, :accept | :host_provided} | {:error, String.t()}
  defp classify_ebin(ebin, app, install_dir, declared?) do
    cond do
      not host_application?(app, install_dir) ->
        accept_without_host_modules(ebin, app, install_dir)

      declared? ->
        {:error, "Hex extension application :#{app} conflicts with a host application"}

      true ->
        {:ok, :host_provided}
    end
  end

  @spec accept_without_host_modules(String.t(), String.t(), String.t()) ::
          {:ok, :accept} | {:error, String.t()}
  defp accept_without_host_modules(ebin, app, install_dir) do
    with :ok <- no_host_modules(ebin, app, install_dir), do: {:ok, :accept}
  end

  @spec ebin_application(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp ebin_application(ebin, install_dir) do
    if Path.expand(ebin) == ebin and within?(ebin, install_dir) do
      ebin |> Path.relative_to(install_dir) |> Path.split() |> installed_application()
    else
      {:error, @outside_install_dir}
    end
  end

  @spec installed_application([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  defp installed_application([_version, _hash, "_build", _env, "lib", app, "ebin"]),
    do: {:ok, app}

  defp installed_application(_segments), do: {:error, @outside_install_dir}

  # A planted symbolic link at any level (`_build`, `lib`, `lib/<app>`, `ebin`) could point
  # outside the install directory, so the resolved path must equal the reported one.
  @spec real_directory(String.t()) :: :ok | {:error, String.t()}
  defp real_directory(ebin) do
    with {:ok, ^ebin} <- resolve_real_path(ebin, @max_symlink_depth),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(ebin) do
      :ok
    else
      _other ->
        {:error,
         "isolated Hex installer reported an ebin path that is not a real directory: #{ebin}"}
    end
  end

  # An application or module counts as host-provided when it resolves outside the isolated
  # install directory. Code appended by an earlier isolated install in this VM is not host code.
  @spec host_application?(String.t(), String.t()) :: boolean()
  defp host_application?(app, install_dir) do
    case existing_atom(app) do
      nil -> false
      atom -> host_lib_dir?(atom, :code.lib_dir(atom), install_dir)
    end
  end

  @spec host_lib_dir?(atom(), charlist() | {:error, term()}, String.t()) :: boolean()
  defp host_lib_dir?(_app, path, install_dir) when is_list(path),
    do: not within?(path, install_dir)

  defp host_lib_dir?(app, _not_found, _install_dir),
    do: List.keymember?(Application.loaded_applications(), app, 0)

  @spec no_host_modules(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  defp no_host_modules(ebin, app, install_dir) do
    conflict =
      ebin
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".beam"))
      |> Enum.find(&host_module?(&1, install_dir))

    case conflict do
      nil -> :ok
      module -> {:error, "Hex dependency :#{app} would shadow host module #{module}"}
    end
  end

  @spec host_module?(String.t(), String.t()) :: boolean()
  defp host_module?(name, install_dir) do
    case :code.where_is_file(String.to_charlist(name <> ".beam")) do
      :non_existing -> loaded_host_module?(existing_atom(name), install_dir)
      path -> not within?(path, install_dir)
    end
  end

  @spec loaded_host_module?(atom() | nil, String.t()) :: boolean()
  defp loaded_host_module?(nil, _install_dir), do: false

  defp loaded_host_module?(module, install_dir) do
    case :code.is_loaded(module) do
      false -> false
      {:file, path} when is_list(path) -> not within?(path, install_dir)
      {:file, _in_memory} -> true
    end
  end

  @spec within?(charlist() | String.t(), String.t()) :: boolean()
  defp within?(path, install_dir),
    do: String.starts_with?(Path.expand(to_string(path)), install_dir <> "/")

  @spec redact_url_credentials(String.t()) :: String.t()
  defp redact_url_credentials(text),
    do: Regex.replace(~r{([A-Za-z][A-Za-z0-9+.\-]*://)[^\s/@]+@}, text, "\\1[REDACTED]@")

  @spec existing_atom(String.t()) :: atom() | nil
  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  @spec unique_suffix() :: String.t()
  defp unique_suffix do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  # ── Child side ──────────────────────────────────────────────────────────────

  # Variables that would point the child's Mix at the developer's project or build.
  @project_env ~w(MIX_ENV MIX_TARGET MIX_EXS MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_INSTALL_FORCE MIX_INSTALL_RESTORE_PROJECT_DIR)

  @doc """
  Runs one install request inside the disposable installer process and writes its JSON report.

  `Minga.Extension.DisposableBeam` calls this in the child; the host never calls it.
  """
  @spec run_disposable(map()) :: :ok
  def run_disposable(%{
        "deps" => deps,
        "install_dir" => install_dir,
        "force" => force,
        "report_path" => report_path
      })
      when is_list(deps) and is_binary(install_dir) and is_boolean(force) and
             is_binary(report_path) do
    {:ok, capture} = StringIO.open("")
    capture_output(capture)

    report =
      try do
        install_in_child(deps, install_dir, force)
      rescue
        error -> {:error, Exception.message(error)}
      catch
        # Mix exits with {:shutdown, 1} after printing a dependency compile error.
        :exit, {:shutdown, _status} -> {:error, "Mix.install failed"}
        kind, reason -> {:error, Exception.format_banner(kind, reason)}
      end

    write_report(report_path, with_output_tail(report, capture))
  end

  def run_disposable(_request), do: :ok

  @spec install_in_child([map()], String.t(), boolean()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  defp install_in_child(deps, install_dir, force) do
    Enum.each(@project_env, &System.delete_env/1)
    System.put_env("MIX_INSTALL_DIR", install_dir)
    {:ok, _applications} = Application.ensure_all_started(:elixir)

    before = MapSet.new(:code.get_path(), &List.to_string/1)

    Mix.install(Enum.map(deps, &decode_dep/1),
      force: force,
      consolidate_protocols: false,
      start_applications: false
    )

    project_dir = Mix.install_project_dir()

    ebins =
      for path <- :code.get_path(),
          path = List.to_string(path),
          not MapSet.member?(before, path),
          String.starts_with?(path, project_dir <> "/"),
          Path.basename(Path.dirname(path)) != "mix_install",
          do: path

    {:ok, ebins}
  end

  # Mix and the compiler print errors to the group leader and to `:standard_error`. The child is
  # disposable, so it redirects both into a buffer and returns the tail with a failure.
  @spec capture_output(pid()) :: :ok
  defp capture_output(capture) do
    Process.group_leader(self(), capture)

    if Process.whereis(:standard_error) do
      Process.unregister(:standard_error)
    end

    Process.register(capture, :standard_error)
    :ok
  end

  @spec with_output_tail({:ok, [String.t()]} | {:error, String.t()}, pid()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  defp with_output_tail({:ok, _ebins} = report, _capture), do: report

  defp with_output_tail({:error, message}, capture) do
    {_input, output} = StringIO.contents(capture)

    case output |> String.split("\n", trim: true) |> Enum.take(-@output_tail_lines) do
      [] -> {:error, message}
      tail -> {:error, Enum.join([message, "Installer output:" | tail], "\n")}
    end
  end

  @spec decode_dep(map()) :: dep()
  defp decode_dep(%{
         "app" => app,
         "requirement" => requirement,
         "source" => source,
         "value" => value
       })
       when source in ["hex", "path"] do
    # The child is disposable, so creating atoms for dependency names is safe here.
    {String.to_atom(app), requirement, [{String.to_atom(source), value}]}
  end

  @spec write_report(String.t(), {:ok, [String.t()]} | {:error, String.t()}) :: :ok
  defp write_report(path, {:ok, ebins}),
    do: write_payload(path, %{"status" => "ok", "ebin_paths" => ebins})

  defp write_report(path, {:error, message}) do
    bounded =
      message |> String.replace_invalid() |> String.trim() |> String.slice(0, @max_message_chars)

    write_payload(path, %{"status" => "error", "message" => bounded})
  end

  @spec write_payload(String.t(), map()) :: :ok
  defp write_payload(path, payload) do
    temporary = path <> ".worker-tmp"

    with :ok <- File.write(temporary, JSON.encode!(payload), [:binary, :exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _reason} ->
        File.rm(temporary)
        :ok
    end
  end
end
