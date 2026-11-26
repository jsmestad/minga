defmodule Minga.Test.ProjectSearchStub do
  @moduledoc """
  Test stand-in for `Minga.Project.ProjectSearch`, configured in `config/test.exs`.

  A root registered with `set_results/2` answers from memory, so a storyboard session never spawns ripgrep while tests run concurrently. Any other root runs the real search, so the search's own tests keep their behaviour.
  """

  alias Minga.Project.ProjectSearch
  alias Minga.Project.Root

  @table __MODULE__

  @doc "Creates the ETS table. Call once from test_helper.exs."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc "Answers every search under `root` from memory with the given matches and file coverage."
  @spec set_results(
          String.t(),
          [Minga.Project.ProjectSearch.match()],
          Minga.Project.ProjectSearch.coverage()
        ) ::
          :ok
  def set_results(root, matches, coverage \\ :visible)
      when is_binary(root) and is_list(matches) do
    {:ok, path} = Root.canonical_path(root)
    :ets.insert(@table, {path, matches, coverage})
    :ok
  end

  @doc "Searches like `Minga.Project.ProjectSearch.search/2`, from memory for a registered root."
  @spec search(String.t(), Root.t()) :: ProjectSearch.result()
  def search(query, %Root{path: path} = root) do
    case :ets.lookup(@table, path) do
      [{_root, matches, coverage}] ->
        if query == "", do: {:error, "Empty search query"}, else: {:ok, matches, false, coverage}

      [] ->
        ProjectSearch.search(query, root)
    end
  end
end
