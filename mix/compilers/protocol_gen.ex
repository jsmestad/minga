defmodule Mix.Tasks.Compile.ProtocolGen do
  @moduledoc """
  Mix compiler that generates protocol artifacts before Elixir and Zig consumers compile.

  Runs the generator only when the fingerprint of `docs/protocol_schema.toml`, `zig/src/protocol.zig`, the generator source, or any generated artifact differs from the last successful run, or when `--force` is passed.
  """

  use Mix.Task.Compiler

  alias Minga.Mix.CompilerManifest
  alias Minga.Mix.ProtocolGenerator

  @manifest_name "protocol_gen"

  @impl true
  @spec run([String.t()]) :: {:ok, []} | {:noop, []} | {:error, []}
  def run(args) do
    manifest = CompilerManifest.path(@manifest_name)

    if CompilerManifest.stale?(manifest, ProtocolGenerator.tracked_paths(), args) do
      generate(manifest)
    else
      {:noop, []}
    end
  end

  @impl true
  @spec manifests() :: [String.t()]
  def manifests, do: [CompilerManifest.path(@manifest_name)]

  @impl true
  @spec clean() :: :ok
  def clean, do: CompilerManifest.remove(CompilerManifest.path(@manifest_name))

  defp generate(manifest) do
    ProtocolGenerator.run([])
    CompilerManifest.record(manifest, ProtocolGenerator.tracked_paths())
    {:ok, []}
  rescue
    error in Mix.Error ->
      Mix.shell().error(Exception.message(error))
      {:error, []}
  end
end
