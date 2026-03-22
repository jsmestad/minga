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

  ## CPU Architecture

  Apple Silicon (arm64) only. Minga does not target Intel Macs.
  All three components (Swift GUI, BEAM release, Zig parser) are
  compiled for arm64. The CI release pipeline runs on `macos-14`
  (Apple Silicon) runners.

  ## Prerequisites

  - Xcode command line tools installed (`xcode-select --install`)
  - XcodeGen installed (`brew install xcodegen`)
  - Zig toolchain available (for the tree-sitter parser)

  ## What it produces

      Minga.app/
        Contents/
          MacOS/
            Minga                    # Swift/Metal GUI executable
          Resources/
            release/                 # Self-contained BEAM release
              bin/minga_macos        # Release entry script
              lib/                   # BEAM modules (includes minga-parser in priv/)
              releases/              # Release metadata
              erts-*/                # Embedded Erlang runtime
            default.metallib         # Metal shaders (from Xcode)
            Fonts/                   # Bundled fonts (from Xcode)
            Assets.car               # App icon (from Xcode)
          Info.plist
  """

  use Mix.Task

  @app_name "Minga"

  @doc false
  @spec run([String.t()]) :: :ok
  def run(args) do
    no_build = "--no-build" in args

    # Step 1: Build the BEAM release (unless --no-build)
    release_path = build_beam_release(no_build)

    # Step 2: Build the Xcode project (unless --no-build)
    app_bundle_path = build_xcode_project(no_build)

    # Step 3: Embed the BEAM release into the app bundle
    embed_release(app_bundle_path, release_path)

    # Step 4: Strip TUI-only binaries from the embedded release
    strip_tui_binaries(app_bundle_path)

    # Step 5: Ad-hoc codesign the complete bundle
    codesign_bundle(app_bundle_path)

    # Step 6: Report bundle size
    report_size(app_bundle_path)

    Mix.shell().info("""

    ✅ #{@app_name}.app assembled successfully at:
       #{app_bundle_path}
    """)
  end

  @spec build_beam_release(boolean()) :: String.t()
  defp build_beam_release(true) do
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

  defp build_beam_release(false) do
    Mix.shell().info("Building BEAM release (minga_macos)...")
    Mix.Task.run("release", ["minga_macos", "--overwrite"])
    Path.join([Mix.Project.build_path(), "rel", "minga_macos"])
  end

  @spec build_xcode_project(boolean()) :: String.t()
  defp build_xcode_project(true) do
    app_path = find_xcode_app_bundle()

    unless app_path do
      Mix.raise("""
      Xcode build product not found. Run `xcodebuild` first, or drop --no-build.
      """)
    end

    Mix.shell().info("Using existing Xcode build at #{app_path}")
    app_path
  end

  defp build_xcode_project(false) do
    macos_dir = Path.join(File.cwd!(), "macos")
    project_path = Path.join(macos_dir, "#{@app_name}.xcodeproj")

    # Generate the Xcode project from project.yml if needed
    unless File.dir?(project_path) do
      Mix.shell().info("Generating Xcode project with XcodeGen...")

      case System.cmd("xcodegen", ["generate"], cd: macos_dir, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _} -> Mix.raise("XcodeGen failed:\n#{output}")
      end
    end

    Mix.shell().info("Building Xcode project (Release configuration)...")

    case System.cmd(
           "xcodebuild",
           [
             "-project",
             project_path,
             "-scheme",
             @app_name,
             "-configuration",
             "Release",
             "build"
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _} ->
        Mix.raise("Xcode build failed:\n#{output}")
    end

    app_path = find_xcode_app_bundle()

    unless app_path do
      Mix.raise("Xcode build succeeded but #{@app_name}.app not found in DerivedData")
    end

    app_path
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

    :ok
  end

  @spec strip_tui_binaries(String.t()) :: :ok
  defp strip_tui_binaries(app_bundle_path) do
    # Find and remove TUI-only binaries from the embedded release's priv/
    priv_glob =
      Path.join([
        app_bundle_path,
        "Contents",
        "Resources",
        "release",
        "lib",
        "minga-*",
        "priv"
      ])

    priv_dirs = Path.wildcard(priv_glob)

    tui_binaries = ["minga-renderer", "minga-renderer-gui"]

    for priv_dir <- priv_dirs, binary_name <- tui_binaries do
      path = Path.join(priv_dir, binary_name)

      if File.exists?(path) do
        File.rm!(path)
        Mix.shell().info("Stripped TUI binary: #{binary_name}")
      end
    end

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
      {output, _} -> Mix.shell().error("codesign warning: #{output}")
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

  @spec find_xcode_app_bundle() :: String.t() | nil
  defp find_xcode_app_bundle do
    project_path = Path.join([File.cwd!(), "macos", "#{@app_name}.xcodeproj"])

    with {output, 0} <- xcodebuild_show_settings(project_path),
         {:ok, path} <- resolve_app_path(output) do
      path
    else
      _ -> nil
    end
  end

  @spec xcodebuild_show_settings(String.t()) :: {String.t(), non_neg_integer()}
  defp xcodebuild_show_settings(project_path) do
    System.cmd(
      "xcodebuild",
      [
        "-project",
        project_path,
        "-scheme",
        @app_name,
        "-configuration",
        "Release",
        "-showBuildSettings"
      ],
      stderr_to_stdout: true
    )
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
