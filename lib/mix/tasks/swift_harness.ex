defmodule Mix.Tasks.Swift.Harness do
  @moduledoc """
  Builds the headless Swift test harness for GUI protocol integration testing.

  ## Usage

      mix swift.harness

  Compiles `macos/Sources/TestHarness/main.swift` along with the shared
  protocol files into `priv/minga-test-harness`. Required before running
  `test/minga_editor/integration/gui_protocol_test.exs`.
  """

  use Mix.Task

  @shortdoc "Build the Swift GUI protocol test harness"

  @impl Mix.Task
  @spec run(list()) :: :ok
  def run(_args) do
    Mix.Task.run("protocol.gen", [])

    sources = [
      "macos/.generated/protocol/ProtocolOpcodes.generated.swift",
      "macos/Sources/Protocol/ProtocolConstants.swift",
      "macos/Sources/Protocol/ProtocolTypes.swift",
      "macos/Sources/Protocol/ProtocolDecoder.swift",
      "macos/Sources/Renderer/WindowContent.swift",
      "macos/Sources/Protocol/BoardTypes.swift",
      "macos/TestHarness/main.swift"
    ]

    priv_dir = Path.join(Mix.Project.app_path(), "priv")
    File.mkdir_p!(priv_dir)
    output = Path.join(priv_dir, "minga-test-harness")

    args = sources ++ ["-o", output]

    System.find_executable("swiftc")
    |> run_with_swiftc(args, output)
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
