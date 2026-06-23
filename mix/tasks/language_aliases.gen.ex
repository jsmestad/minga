defmodule Mix.Tasks.LanguageAliases.Gen do
  @moduledoc """
  Generates language alias lookup tables from `config/language_aliases.json`.
  """

  use Mix.Task

  @shortdoc "Generates language alias lookup tables"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Minga.Mix.LanguageAliasGenerator.run(args)
  end
end
