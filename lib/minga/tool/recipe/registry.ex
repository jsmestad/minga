defmodule Minga.Tool.Recipe.Registry do
  @moduledoc """
  ETS-backed registry of tool installation recipes.

  Holds all known recipes for installable tools (LSP servers, formatters,
  linters). Recipes are contributed at runtime by bundled recipe packs
  (via `Minga.Extensions.RecipePacks`) or user config. Provides fast
  lookups by tool name, command string, and category.

  Follows the same pattern as `Minga.Language.Registry`.

  ## Lookups

  - `get/1` - look up a recipe by name atom
  - `for_command/1` - find the recipe that provides a given command string
  - `all/0` - list all recipes
  - `by_category/1` - filter recipes by category
  """

  use GenServer

  alias Minga.Tool.Recipe

  @table __MODULE__
  @command_index :"#{__MODULE__}.Commands"
  @source_table :"#{__MODULE__}.Sources"

  @type name :: atom()
  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :config | {:extension, atom()}
  @type register_error ::
          {:duplicate_recipe, atom(), contribution_source(), contribution_source()}

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Returns the recipe for a given tool name, or nil."
  @spec get(name()) :: Recipe.t() | nil
  def get(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, recipe}] -> recipe
      [] -> nil
    end
  end

  @doc "Returns the recipe whose `provides` list includes the given command string."
  @spec for_command(String.t()) :: Recipe.t() | nil
  def for_command(command) when is_binary(command) do
    case :ets.lookup(@command_index, command) do
      [{^command, name}] -> get(name)
      [] -> nil
    end
  end

  @doc "Returns all registered recipes."
  @spec all() :: [Recipe.t()]
  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_name, recipe} -> recipe end)
  end

  @doc "Returns recipes filtered by category."
  @spec by_category(Recipe.category()) :: [Recipe.t()]
  def by_category(category) when is_atom(category) do
    all() |> Enum.filter(fn r -> r.category == category end)
  end

  @doc "Returns all recipes that serve a given language."
  @spec for_language(atom()) :: [Recipe.t()]
  def for_language(language) when is_atom(language) do
    all() |> Enum.filter(fn r -> language in r.languages end)
  end

  @doc "Registers a config-owned recipe."
  @spec register(Recipe.t()) :: :ok | {:error, register_error()}
  def register(%Recipe{} = recipe), do: register(recipe, :config)

  @doc "Registers a recipe with explicit source ownership."
  @spec register(Recipe.t(), contribution_source()) :: :ok | {:error, register_error()}
  def register(%Recipe{} = recipe, source) do
    GenServer.call(__MODULE__, {:register, recipe, source})
  end

  @doc "Removes every recipe contributed by a source."
  @spec unregister_source(contribution_source()) :: :ok
  def unregister_source(source) do
    GenServer.call(__MODULE__, {:unregister_source, source})
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) ::
          {:ok, %{table: :ets.table(), command_index: :ets.table(), source_table: :ets.table()}}
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    cmd_table = :ets.new(@command_index, [:named_table, :set, :protected, read_concurrency: true])

    source_table =
      :ets.new(@source_table, [:named_table, :set, :protected, read_concurrency: true])

    {:ok, %{table: table, command_index: cmd_table, source_table: source_table}}
  end

  @impl true
  def handle_call({:register, %Recipe{} = recipe, source}, _from, state) do
    reply =
      with :ok <- validate_recipe_source(state.command_index, state.source_table, recipe, source) do
        insert_recipe(state.table, state.command_index, state.source_table, recipe, source)
      end

    {:reply, reply, state}
  end

  def handle_call({:unregister_source, source}, _from, state) do
    unregister_source_recipes(state.table, state.command_index, state.source_table, source)
    {:reply, :ok, state}
  end

  @spec validate_recipe_source(:ets.table(), :ets.table(), Recipe.t(), contribution_source()) ::
          :ok | {:error, register_error()}
  defp validate_recipe_source(cmd_table, source_table, %Recipe{} = recipe, source) do
    with :ok <- validate_recipe_name_source(source_table, recipe.name, source) do
      Enum.reduce_while(recipe.provides, :ok, fn command, :ok ->
        validate_command_source(cmd_table, source_table, command, source)
      end)
    end
  end

  @spec validate_recipe_name_source(:ets.table(), atom(), contribution_source()) ::
          :ok | {:error, register_error()}
  defp validate_recipe_name_source(source_table, name, source) do
    case :ets.lookup(source_table, name) do
      [{^name, ^source}] -> :ok
      [{^name, existing_source}] -> {:error, {:duplicate_recipe, name, existing_source, source}}
      [] -> :ok
    end
  end

  @spec validate_command_source(:ets.table(), :ets.table(), String.t(), contribution_source()) ::
          {:cont, :ok} | {:halt, {:error, register_error()}}
  defp validate_command_source(cmd_table, source_table, command, source) do
    case :ets.lookup(cmd_table, command) do
      [{^command, name}] -> validate_command_recipe_source(source_table, name, source)
      [] -> {:cont, :ok}
    end
  end

  @spec validate_command_recipe_source(:ets.table(), atom(), contribution_source()) ::
          {:cont, :ok} | {:halt, {:error, register_error()}}
  defp validate_command_recipe_source(source_table, name, source) do
    case validate_recipe_name_source(source_table, name, source) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec insert_recipe(:ets.table(), :ets.table(), :ets.table(), Recipe.t(), contribution_source()) ::
          :ok
  defp insert_recipe(table, cmd_table, source_table, %Recipe{} = recipe, source) do
    remove_recipe_indexes(table, cmd_table, recipe.name)
    :ets.insert(table, {recipe.name, recipe})
    :ets.insert(source_table, {recipe.name, source})

    for command <- recipe.provides do
      :ets.insert(cmd_table, {command, recipe.name})
    end

    :ok
  end

  @spec remove_recipe_indexes(:ets.table(), :ets.table(), atom()) :: :ok
  defp remove_recipe_indexes(table, cmd_table, name) do
    case :ets.lookup(table, name) do
      [{^name, %Recipe{} = old_recipe}] ->
        for command <- old_recipe.provides, do: :ets.delete(cmd_table, command)

      [] ->
        :ok
    end

    :ok
  end

  @spec unregister_source_recipes(:ets.table(), :ets.table(), :ets.table(), contribution_source()) ::
          :ok
  defp unregister_source_recipes(table, cmd_table, source_table, source) do
    source_table
    |> :ets.tab2list()
    |> Enum.each(fn
      {name, ^source} ->
        remove_recipe_indexes(table, cmd_table, name)
        :ets.delete(table, name)
        :ets.delete(source_table, name)

      _entry ->
        :ok
    end)

    :ok
  end
end
