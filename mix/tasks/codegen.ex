defmodule Mix.Tasks.Codegen do
  @moduledoc "Refreshes protocol, language-alias and design token sources and checks the Elixir output directory."
  @shortdoc "Refreshes generated sources from their schemas"

  use Mix.Task

  alias Minga.Mix.DesignTokenGenerator
  alias Minga.Mix.LanguageAliasGenerator
  alias Minga.Mix.ProtocolGenerator

  @elixir_dir "generated/elixir"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([]) do
    ProtocolGenerator.run([])
    LanguageAliasGenerator.run([])
    DesignTokenGenerator.run([])
    check_elixir_inventory!()
  end

  def run(_args), do: Mix.raise("Usage: mix codegen")

  defp check_elixir_inventory! do
    expected =
      (ProtocolGenerator.generated_paths() ++
         LanguageAliasGenerator.generated_paths() ++ DesignTokenGenerator.generated_paths())
      |> Enum.filter(&(Path.dirname(&1) == @elixir_dir))
      |> Enum.map(&Path.basename/1)

    case Enum.sort(File.ls!(@elixir_dir) -- expected) do
      [] ->
        :ok

      obsolete ->
        Mix.raise("Remove obsolete files from #{@elixir_dir}: #{Enum.join(obsolete, ", ")}")
    end
  end
end
