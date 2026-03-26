defmodule Mix.Tasks.Swift.Harness do
  @moduledoc """
  Builds the headless Swift test harness for GUI protocol integration testing.

  ## Usage

      mix swift.harness

  Compiles `macos/Sources/TestHarness/main.swift` along with the shared
  protocol files into `priv/minga-test-harness`. Required before running
  `test/minga/integration/gui_protocol_test.exs`.
  """

  use Mix.Task

  @shortdoc "Build the Swift GUI protocol test harness"

  @impl Mix.Task
  @spec run(list()) :: :ok
  def run(_args) do
    sources = [
      "macos/Sources/Protocol/ProtocolConstants.swift",
      "macos/Sources/Protocol/ProtocolDecoder.swift",
      "macos/Sources/Renderer/WindowContent.swift",
      "macos/Sources/Protocol/BoardTypes.swift",
      "macos/TestHarness/main.swift"
    ]

    priv_dir = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(priv_dir)
    output = Path.join(priv_dir, "minga-test-harness")

    args = sources ++ ["-o", output]

    Mix.shell().info("Building Swift test harness...")

    case System.cmd("swiftc", args, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.shell().info("Swift test harness built: #{output}")
        :ok

      {error_output, code} ->
        Mix.raise("swiftc failed (exit #{code}):\n#{error_output}")
    end
  end
end
