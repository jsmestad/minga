defmodule Minga.Test.ProjectSearchStub do
  @moduledoc """
  Test stand-in for `Minga.Project.ProjectSearch`, configured in `config/test.exs`.

  A root registered with `set_results/2` answers from memory, so a storyboard session never spawns ripgrep while tests run concurrently. Any other root runs the real search, so the search's own tests keep their behaviour.
  """

  @table __MODULE__

  @doc "Creates the ETS table. Call once from test_helper.exs."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc "Answers every search under `root` with `matches`."
  @spec set_results(String.t(), [Minga.Project.ProjectSearch.match()]) :: :ok
  def set_results(root, matches) when is_binary(root) and is_list(matches) do
    :ets.insert(@table, {Path.expand(root), matches})
    :ok
  end

  @doc "Searches like `Minga.Project.ProjectSearch.search/2`, from memory for a registered root."
  @spec search(String.t(), String.t()) :: Minga.Project.ProjectSearch.result()
  def search(query, root) do
    case :ets.lookup(@table, Path.expand(root)) do
      [{_root, matches}] ->
        if query == "", do: {:error, "Empty search query"}, else: {:ok, matches, false}

      [] ->
        Minga.Project.ProjectSearch.search(query, root)
    end
  end
end
