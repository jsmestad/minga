defmodule Mix.Tasks.Swift.Build do
  @moduledoc """
  Builds the macOS Swift frontend with `xcodebuild`.

  ## Usage

      mix swift.build

  Additional arguments are passed directly to `xcodebuild`, so use `mix swift.build -- -project macos/Minga.xcodeproj -scheme Minga test` when you need a custom action.
  """

  use Mix.Task

  @shortdoc "Build the macOS Swift frontend"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Mix.Task.run("protocol.gen", [])

    System.find_executable("xcodebuild")
    |> run_with_xcodebuild(args)
  end

  @spec run_with_xcodebuild(nil | String.t(), [String.t()]) :: :ok
  defp run_with_xcodebuild(nil, _args) do
    Mix.shell().info("xcodebuild not found; skipping Swift build")
    :ok
  end

  defp run_with_xcodebuild(xcodebuild, args) do
    xcodebuild
    |> System.cmd(xcodebuild_args(args), stderr_to_stdout: true)
    |> handle_xcodebuild_result()
  end

  @spec xcodebuild_args([String.t()]) :: [String.t()]
  defp xcodebuild_args([]), do: ["-project", "macos/Minga.xcodeproj", "-scheme", "Minga", "build"]
  defp xcodebuild_args(["--" | args]), do: args
  defp xcodebuild_args(args), do: args

  @spec handle_xcodebuild_result({String.t(), non_neg_integer()}) :: :ok
  defp handle_xcodebuild_result({_output, 0}) do
    Mix.shell().info("Swift frontend built successfully")
    :ok
  end

  defp handle_xcodebuild_result({output, code}) do
    Mix.raise("xcodebuild failed (exit #{code}):\n#{output}")
  end
end
