defmodule Mix.Tasks.Compile.LanguageAliasesGen do
  @moduledoc """
  Mix compiler that generates language alias artifacts before Elixir and Zig consumers compile.

  Runs the generator only when the fingerprint of `config/language_aliases.json`, the scanned `lib/minga/language/*.ex` sources, the generator source, or a generated artifact differs from the last successful run, or when `--force` is passed.
  """

  use Mix.Task.Compiler

  alias Minga.Mix.CompilerManifest
  alias Minga.Mix.LanguageAliasGenerator

  @manifest_name "language_aliases_gen"

  @impl true
  @spec run([String.t()]) :: {:ok, []} | {:noop, []} | {:error, []}
  def run(args) do
    manifest = CompilerManifest.path(@manifest_name)

    if CompilerManifest.stale?(manifest, LanguageAliasGenerator.tracked_paths(), args) do
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
    LanguageAliasGenerator.run([])
    CompilerManifest.record(manifest, LanguageAliasGenerator.tracked_paths())
    {:ok, []}
  rescue
    error in Mix.Error ->
      Mix.shell().error(Exception.message(error))
      {:error, []}
  end
end
