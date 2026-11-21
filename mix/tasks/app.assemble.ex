defmodule Mix.Tasks.App.Assemble do
  @moduledoc """
  Assembles a complete `Minga.app` macOS application bundle.

  Takes the Xcode-built `.app` bundle (with the Swift/Metal GUI, Metal shaders,
  fonts, and Info.plist) and embeds the BEAM release (from `mix release minga_macos`)
  inside it at `Contents/Resources/release/`.

  The result is a self-contained application: double-clicking `Minga.app` will
  eventually launch the editor with no external Erlang/Elixir dependency (#952).

  ## Usage

      # Build everything from scratch:
      MIX_ENV=prod mix app.assemble

      # Skip the Xcode/release builds if you already ran them:
      MIX_ENV=prod mix app.assemble --no-build

      # Write the absolute successful product path for automation:
      MIX_ENV=prod mix app.assemble --output-path-file /tmp/minga-app-path

  ## CPU Architecture

  Apple Silicon (arm64) only. All native components are built for arm64. The candidate pipeline uses `macos-15` (Apple Silicon) runners and verifies the actual packaged architecture.

  ## Prerequisites

  - Xcode command line tools installed (`xcode-select --install`)
  - Repository-pinned XcodeGen installed (`scripts/install_xcodegen <dir>`)
  - Zig toolchain available (for the tree-sitter parser)

  ## What it produces

      Minga.app/
        Contents/
          MacOS/
            Minga                    # Swift/Metal GUI executable
          Resources/
            bin/
              minga                  # Launch Services-aware primary CLI
              minga-tui              # Explicit standalone/TUI wrapper
              minga-ipc              # Authenticated AF_UNIX CLI helper
            release/                 # Self-contained BEAM release
              bin/minga_macos        # Release entry script
              lib/                   # BEAM modules and native support/TUI binaries
              releases/              # Release metadata
              erts-*/                # Embedded Erlang runtime
            default.metallib         # Metal shaders (from Xcode)
            Fonts/                   # Bundled fonts (from Xcode)
            Assets.car               # App icon (from Xcode)
          Info.plist
  """

  use Mix.Task

  @app_name "Minga"
  @xcodegen_version_file ".xcodegen-version"

  @doc false
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, positional} =
      OptionParser.parse!(args, strict: [no_build: :boolean, output_path_file: :string])

    if positional != [], do: Mix.raise("Unexpected arguments: #{Enum.join(positional, " ")}")
    no_build = Keyword.get(opts, :no_build, false)
    output_path_file = opts[:output_path_file]

    # A failed rerun must not leave a previous successful handoff available.
    if output_path_file do
      case File.rm(output_path_file) do
        :ok ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          Mix.raise("Cannot clear output path file: #{:file.format_error(reason)}")
      end
    end

    {release_path, app_bundle_path} = build_inputs(no_build)

    timed("Final assembly", fn ->
      embed_release(app_bundle_path, release_path)
      install_cli_launchers(app_bundle_path)

      codesign_bundle(app_bundle_path)
      verify_bundle_linkage!(app_bundle_path)

      report_size(app_bundle_path)
    end)

    if output_path_file do
      File.write!(output_path_file, Path.expand(app_bundle_path) <> "\n")
    end

    Mix.shell().info("""

    ✅ #{@app_name}.app assembled successfully at:
       #{app_bundle_path}
    """)
  end

  @spec build_inputs(boolean()) :: {String.t(), String.t()}
  defp build_inputs(true), do: {existing_beam_release!(), existing_xcode_app!()}

  defp build_inputs(false) do
    # The native tasks also request protocol.gen. Mix runs the alias once, here,
    # before either branch starts reading its Swift, Elixir, Go or Zig outputs.
    timed("Protocol generation", fn -> Mix.Task.run("protocol.gen", []) end)

    xcode = Task.async(fn -> build_branch("Xcode", &build_xcode_project/0) end)
    beam = build_branch("BEAM/native", &build_beam_release/0)
    app = Task.await(xcode, :infinity)

    {branch_result!(beam), branch_result!(app)}
  end

  # Join both branches even when a build fails, so a failed Mix command cannot
  # leave xcodebuild running against the DerivedData used by a later rerun.
  @typep branch_result(value) ::
           {:ok, value} | {:error, Exception.kind(), term(), Exception.stacktrace()}
  @spec build_branch(String.t(), (-> String.t())) :: branch_result(String.t())
  defp build_branch(label, build) do
    {:ok, timed(label, build)}
  catch
    kind, reason -> {:error, kind, reason, __STACKTRACE__}
  end

  @spec branch_result!(branch_result(String.t())) :: String.t()
  defp branch_result!({:ok, path}), do: path

  defp branch_result!({:error, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  @spec timed(String.t(), (-> value)) :: value when value: var
  defp timed(label, operation) do
    {elapsed, result} = :timer.tc(operation, :millisecond)
    Mix.shell().info("#{label} took #{elapsed} ms")
    result
  end

  @spec existing_beam_release!() :: String.t()
  defp existing_beam_release! do
    release_path = Path.join([Mix.Project.build_path(), "rel", "minga_macos"])

    unless File.dir?(release_path) do
      Mix.raise("""
      BEAM release not found at #{release_path}.
      Run `MIX_ENV=prod mix release minga_macos` first, or drop --no-build.
      """)
    end

    Mix.shell().info("Using existing BEAM release at #{release_path}")
    release_path
  end

  @spec build_beam_release() :: String.t()
  defp build_beam_release do
    Mix.shell().info("Building native support and TUI binaries for the macOS release...")
    Mix.Task.run("native.build.tui", [])
    Mix.shell().info("Building BEAM release (minga_macos)...")
    Mix.Task.run("release", ["minga_macos", "--overwrite"])
    Path.join([Mix.Project.build_path(), "rel", "minga_macos"])
  end

  @spec verify_xcodegen_version!() :: :ok
  defp verify_xcodegen_version! do
    expected = @xcodegen_version_file |> File.read!() |> String.trim()

    case System.cmd("xcodegen", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) == "Version: #{expected}" or String.trim(output) == expected do
          :ok
        else
          Mix.raise("Expected XcodeGen #{expected}, got #{String.trim(output)}")
        end

      {_output, _status} ->
        Mix.raise("XcodeGen #{expected} is required; run scripts/install_xcodegen <dir>")
    end
  rescue
    ErlangError ->
      Mix.raise("XcodeGen is required; run scripts/install_xcodegen <dir>")
  end

  @spec existing_xcode_app!() :: String.t()
  defp existing_xcode_app! do
    app_path =
      find_xcode_app_bundle(xcode_build_args()) ||
        find_xcode_app_bundle(assembly_xcode_build_args())

    unless app_path do
      Mix.raise("""
      Xcode build product not found. Run `xcodebuild` first, or drop --no-build.
      """)
    end

    Mix.shell().info("Using existing Xcode build at #{app_path}")
    app_path
  end

  @spec build_xcode_project() :: String.t()
  defp build_xcode_project do
    macos_dir = Path.expand("macos")

    # Always regenerate from project.yml with the repository-pinned generator.
    # Reusing a checked-out project can silently omit newly declared targets.
    verify_xcodegen_version!()
    Mix.shell().info("Generating Xcode project with pinned XcodeGen...")

    case System.cmd("xcodegen", ["generate"], cd: macos_dir, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _} -> Mix.raise("XcodeGen failed:\n#{output}")
    end

    # The app pre-build phase only consumes the validated Swift outputs in this
    # mode. A second Mix invocation would also share MIX_BUILD_PATH and its
    # dependency compilation with the BEAM branch.
    build_args = assembly_xcode_build_args() ++ ["MINGA_APP_PROTOCOL_PREGENERATED=1"]
    settings = verified_release_build_settings!(build_args)

    Mix.shell().info("Building Xcode project (Release configuration)...")

    case System.cmd("xcodebuild", build_args ++ ["build"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _} ->
        Mix.raise("Xcode build failed:\n#{output}")
    end

    case resolve_app_path(settings) do
      {:ok, app_path} -> app_path
      :error -> Mix.raise("Xcode build succeeded but #{@app_name}.app not found in DerivedData")
    end
  end

  @spec verified_release_build_settings!([String.t()]) :: String.t()
  defp verified_release_build_settings!(build_args) do
    script = Path.join([File.cwd!(), "scripts", "check_macos_release_optimization"])

    case System.cmd(script, ["--print-build-settings" | build_args], stderr_to_stdout: true) do
      {settings, 0} -> settings
      {output, _code} -> Mix.raise("Release optimization verification failed:\n#{output}")
    end
  end

  @spec embed_release(String.t(), String.t()) :: :ok
  defp embed_release(app_bundle_path, release_path) do
    resources_dir = Path.join([app_bundle_path, "Contents", "Resources"])
    target_dir = Path.join(resources_dir, "release")

    # Remove any previous embedded release
    if File.dir?(target_dir) do
      File.rm_rf!(target_dir)
    end

    Mix.shell().info("Embedding BEAM release into #{@app_name}.app...")
    File.mkdir_p!(target_dir)

    # Copy the entire release directory tree
    case System.cmd("cp", ["-a", release_path <> "/.", target_dir], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _} -> Mix.raise("Failed to copy release: #{output}")
    end

    # Keep launch mode identifiable even if the installed release is missing.
    info_plist = Path.join([app_bundle_path, "Contents", "Info.plist"])

    case System.cmd(
           "plutil",
           ["-replace", "MingaEmbeddedCore", "-bool", "YES", info_plist],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _} -> Mix.raise("Failed to record the embedded release in Info.plist: #{output}")
    end

    :ok
  end

  @spec install_cli_launchers(String.t()) :: :ok
  defp install_cli_launchers(app_bundle_path) do
    source_dir = Path.join([File.cwd!(), "macos", "Resources", "bin"])
    target_dir = Path.join([app_bundle_path, "Contents", "Resources", "bin"])
    File.mkdir_p!(target_dir)

    Enum.each(["minga", "minga-tui"], fn launcher ->
      source = Path.join(source_dir, launcher)
      target = Path.join(target_dir, launcher)
      File.cp!(source, target)
      File.chmod!(target, 0o755)
    end)

    Mix.shell().info("Installed GUI and standalone CLI launchers")
    :ok
  end

  @spec codesign_bundle(String.t()) :: :ok
  defp codesign_bundle(app_bundle_path) do
    Mix.shell().info("Ad-hoc code signing #{@app_name}.app...")

    case System.cmd(
           "codesign",
           ["--force", "--deep", "--sign", "-", app_bundle_path],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _} -> Mix.raise("Ad-hoc codesign failed:\n#{output}")
    end

    :ok
  end

  @spec verify_bundle_linkage!(String.t()) :: :ok
  defp verify_bundle_linkage!(app_bundle_path) do
    script = Path.join([File.cwd!(), "scripts", "check_macos_bundle_linkage"])

    case System.cmd(script, [app_bundle_path], stderr_to_stdout: true) do
      {output, 0} -> Mix.shell().info(String.trim(output))
      {output, _code} -> Mix.raise("Bundle linkage verification failed:\n#{output}")
    end

    :ok
  end

  @spec report_size(String.t()) :: :ok
  defp report_size(app_bundle_path) do
    {output, 0} = System.cmd("du", ["-sh", app_bundle_path])
    total_size = output |> String.split("\t") |> hd() |> String.trim()

    release_dir = Path.join([app_bundle_path, "Contents", "Resources", "release"])
    {rel_output, 0} = System.cmd("du", ["-sh", release_dir])
    release_size = rel_output |> String.split("\t") |> hd() |> String.trim()

    gui_binary = Path.join([app_bundle_path, "Contents", "MacOS", @app_name])
    {gui_stat, 0} = System.cmd("du", ["-sh", gui_binary])
    gui_size = gui_stat |> String.split("\t") |> hd() |> String.trim()

    Mix.shell().info("""

    Bundle size breakdown:
      Total:        #{total_size}
      BEAM release: #{release_size}
      GUI binary:   #{gui_size}
    """)
  end

  @spec find_xcode_app_bundle([String.t()]) :: String.t() | nil
  defp find_xcode_app_bundle(build_args) do
    with {output, 0} <-
           System.cmd("xcodebuild", build_args ++ ["-showBuildSettings"], stderr_to_stdout: true),
         {:ok, path} <- resolve_app_path(output) do
      path
    else
      _ -> nil
    end
  end

  @spec xcode_build_args() :: [String.t()]
  defp xcode_build_args do
    [
      "-project",
      Path.expand("macos/#{@app_name}.xcodeproj"),
      "-scheme",
      @app_name,
      "-configuration",
      "Release"
    ]
  end

  @spec assembly_xcode_build_args() :: [String.t()]
  defp assembly_xcode_build_args do
    xcode_build_args() ++ ["-derivedDataPath", Path.expand("macos/.build/app-assembly")]
  end

  @spec resolve_app_path(String.t()) :: {:ok, String.t()} | :error
  defp resolve_app_path(build_settings_output) do
    built_dir = parse_build_setting(build_settings_output, "BUILT_PRODUCTS_DIR")
    full_product = parse_build_setting(build_settings_output, "FULL_PRODUCT_NAME")

    case {built_dir, full_product} do
      {dir, product} when is_binary(dir) and is_binary(product) ->
        path = Path.join(dir, product)
        if File.dir?(path), do: {:ok, path}, else: :error

      _ ->
        :error
    end
  end

  @spec parse_build_setting(String.t(), String.t()) :: String.t() | nil
  defp parse_build_setting(output, key) do
    case Regex.run(~r/\s+#{Regex.escape(key)} = (.+)/, output) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end
end
