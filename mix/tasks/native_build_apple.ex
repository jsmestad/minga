defmodule Mix.Tasks.Native.Build.Apple do
  @moduledoc "Builds the optional Apple Intelligence helper on Apple Silicon with the macOS 27 SDK."

  use Mix.Task

  alias Minga.Mix.CompilerManifest

  @shortdoc "Builds the on-device Apple Intelligence inference helper"
  @source "macos/AppleInference/AppleInference.swift"
  @output "priv/minga-apple-inference"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    case sdk() do
      {:ok, sdk_path, sdk_version} ->
        build_if_stale(sdk_path, sdk_version, args)

      :unsupported ->
        if "--require" in args do
          Mix.raise("Apple Intelligence inference requires Apple Silicon and a macOS 27 SDK")
        end
    end

    :ok
  end

  @spec sdk() :: {:ok, String.t(), String.t()} | :unsupported
  defp sdk do
    with {:unix, :darwin} <- :os.type(),
         true <-
           String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "aarch64-"),
         {version, 0} <-
           System.cmd("xcrun", ["--sdk", "macosx", "--show-sdk-version"], stderr_to_stdout: true),
         {major, _} when major >= 27 <- Integer.parse(String.trim(version)),
         {path, 0} <-
           System.cmd("xcrun", ["--sdk", "macosx", "--show-sdk-path"], stderr_to_stdout: true) do
      {:ok, String.trim(path), String.trim(version)}
    else
      _unsupported -> :unsupported
    end
  end

  @spec build_if_stale(String.t(), String.t(), [String.t()]) :: :ok
  defp build_if_stale(sdk_path, sdk_version, args) do
    manifest = CompilerManifest.path("minga_apple_#{sdk_version}")
    tracked = [@source, @output, __ENV__.file, Path.join(sdk_path, "SDKSettings.json")]

    if CompilerManifest.stale?(manifest, tracked, args) do
      Mix.shell().info("Building Apple Intelligence inference helper...")
      File.mkdir_p!(Path.dirname(@output))
      pending = "#{@output}.next-#{System.pid()}-#{System.unique_integer([:positive])}"

      try do
        options = [
          "--sdk",
          "macosx",
          "swiftc",
          "-swift-version",
          "6",
          "-parse-as-library",
          "-O",
          "-target",
          "arm64-apple-macos15.0",
          @source,
          "-o",
          pending
        ]

        case System.cmd("xcrun", options, stderr_to_stdout: true) do
          {_output, 0} ->
            File.rename!(pending, @output)
            CompilerManifest.record(manifest, tracked)

          {output, _status} ->
            Mix.raise("Apple Intelligence helper compilation failed:\n#{output}")
        end
      after
        File.rm(pending)
      end
    end

    :ok
  end
end
