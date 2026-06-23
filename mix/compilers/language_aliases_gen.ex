defmodule Mix.Tasks.Compile.LanguageAliasesGen do
  @moduledoc """
  Mix compiler that generates language alias artifacts before Elixir and Zig consumers compile.
  """

  use Mix.Task.Compiler

  @impl true
  @spec run(keyword()) :: {:ok, []} | {:error, []}
  def run(_opts) do
    Minga.Mix.LanguageAliasGenerator.run([])
    {:ok, []}
  rescue
    error in Mix.Error ->
      Mix.shell().error(Exception.message(error))
      {:error, []}
  end

  @impl true
  @spec manifests() :: [String.t()]
  def manifests, do: []

  @impl true
  @spec clean() :: :ok
  def clean, do: :ok
end
