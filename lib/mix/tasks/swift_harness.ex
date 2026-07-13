defmodule Mix.Tasks.Swift.Harness do
  @moduledoc """
  Builds the headless Swift test harness for GUI protocol integration testing.

  ## Usage

      mix swift.harness
      mix swift.harness --release

  Compiles `macos/Sources/TestHarness/main.swift` along with the shared
  protocol files into `priv/minga-test-harness`. Required before running
  `test/minga_editor/integration/gui_protocol_test.exs`.
  """

  use Mix.Task

  @shortdoc "Build the Swift GUI protocol test harness"

  # Sources that live in the `MingaProtocol` framework target in the Xcode
  # build. The harness compiles everything as ONE flat module, so we include
  # these directly and strip their cross-module `import MingaProtocol` lines
  # below (see @cross_module_import). Keep in sync with the MingaProtocol
  # target's `sources` in macos/project.yml.
  @protocol_module_sources [
    "macos/Sources/Protocol/ProtocolTypes.swift",
    "macos/Sources/Protocol/StatusBarUpdate.swift",
    "macos/Sources/Protocol/GUIColorSlots.swift",
    "macos/Sources/Protocol/FrameResourcePolicy.swift",
    "macos/Sources/Renderer/WindowContent.swift",
    "macos/Sources/Renderer/ResidentRowStore.swift",
    "macos/Sources/Protocol/AgentSurfaceTypes.swift",
    "macos/Sources/Protocol/LatencyRecorder.swift",
    "macos/Sources/Protocol/RenderPerformanceGate.swift",
    "macos/Sources/Protocol/FrontendExtensionRuntimeMessage.swift"
  ]

  # Generated + app-target Protocol sources the harness needs on top of the
  # MingaProtocol module sources above.
  @harness_app_sources [
    "macos/.generated/protocol/ProtocolOpcodes.generated.swift",
    "macos/.generated/protocol/ProtocolCommandSize.generated.swift",
    "macos/.generated/protocol/ProtocolSemanticDecode.generated.swift",
    "macos/Sources/Protocol/ProtocolConstants.swift",
    "macos/Sources/Protocol/ByteCursor.swift",
    "macos/Sources/Protocol/DecodedFrame.swift",
    "macos/Sources/Protocol/ProtocolEventHandoff.swift",
    "macos/Sources/Protocol/ProtocolDecoder.swift",
    "macos/TestHarness/main.swift"
  ]

  # `import MingaProtocol` / `import MingaUI` only resolve across the real
  # framework module boundary. The single-module harness compiles those types
  # in-line, so these imports must be removed before swiftc sees the file.
  @cross_module_import ~r/^import (?:MingaProtocol|MingaUI)\R/m

  @impl Mix.Task
  @spec run(list()) :: :ok
  def run(args) do
    Mix.Task.run("protocol.gen", [])

    priv_dir = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(priv_dir)
    output = Path.join(priv_dir, "minga-test-harness")

    # Preprocess every source into a temp dir with cross-module imports
    # stripped, then flat-compile the copies into a single binary. The temp
    # dir lives under the (gitignored) build path, not priv/, which is a
    # symlink back into the repo working tree.
    src_dir = Path.join(Mix.Project.build_path(), "minga-harness-src")
    File.rm_rf!(src_dir)
    File.mkdir_p!(src_dir)

    compile_sources =
      (@protocol_module_sources ++ @harness_app_sources)
      |> Enum.map(&preprocess_source(&1, src_dir))

    compiler_args = compile_sources ++ optimization_args(args) ++ ["-o", output]

    System.find_executable("swiftc")
    |> run_with_swiftc(compiler_args, output)
  end

  @spec optimization_args([String.t()]) :: [String.t()]
  defp optimization_args(args) do
    if "--release" in args, do: ["-O"], else: []
  end

  @spec preprocess_source(String.t(), String.t()) :: String.t()
  defp preprocess_source(source, src_dir) do
    stripped = source |> File.read!() |> String.replace(@cross_module_import, "")
    dest = Path.join(src_dir, Path.basename(source))
    File.write!(dest, stripped)
    dest
  end

  @spec run_with_swiftc(nil | String.t(), [String.t()], String.t()) :: :ok
  defp run_with_swiftc(nil, _args, _output) do
    Mix.shell().info("swiftc not found; skipping Swift test harness build")
    :ok
  end

  defp run_with_swiftc(swiftc, args, output) do
    Mix.shell().info("Building Swift test harness...")

    swiftc
    |> System.cmd(args, stderr_to_stdout: true)
    |> handle_swiftc_result(output)
  end

  @spec handle_swiftc_result({String.t(), non_neg_integer()}, String.t()) :: :ok
  defp handle_swiftc_result({_output, 0}, output) do
    Mix.shell().info("Swift test harness built: #{output}")
    :ok
  end

  defp handle_swiftc_result({error_output, code}, _output) do
    Mix.raise("swiftc failed (exit #{code}):\n#{error_output}")
  end
end
