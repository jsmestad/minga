defmodule Minga.Extensions.RecipePacks do
  @moduledoc """
  Starts bundled recipe packs and registers their tool recipes through extension-owned sources.

  Bundled packs use the same `Minga.Tool.Recipe.Registry.register/2` path as third-party recipe packs. Each pack module provides a `recipes/0` function returning a list of `%Recipe{}` structs. Stopping or reloading a pack removes all its recipes (and their command-index entries) from the registry without affecting other packs' recipes or user-supplied recipes.
  """

  use Agent

  alias Minga.Tool.Recipe
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry

  @typedoc "A module that implements the recipe-pack extension callbacks."
  @type pack_module :: module()

  @typedoc "Runtime state for the bundled pack starter."
  @type state :: %{loaded: [atom()], failed: [{atom(), term()}]}

  @packs [
    Minga.Extensions.RecipePacks.Elixir,
    Minga.Extensions.RecipePacks.Python,
    Minga.Extensions.RecipePacks.Web,
    Minga.Extensions.RecipePacks.Systems,
    Minga.Extensions.RecipePacks.Jvm,
    Minga.Extensions.RecipePacks.Misc
  ]

  @doc "Starts the bundled recipe pack loader."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    packs = Keyword.get(opts, :packs, @packs)
    disabled = Keyword.get(opts, :disabled, disabled_pack_names())

    Agent.start_link(fn -> load_packs(packs, disabled) end, name: name)
  end

  @doc "Returns bundled recipe pack modules in startup order."
  @spec packs() :: [pack_module()]
  def packs, do: @packs

  @doc "Registers all recipes owned by a pack, replacing stale entries from an earlier load."
  @spec register_pack(pack_module()) :: :ok | {:error, term()}
  def register_pack(pack_module) when is_atom(pack_module) do
    source = source_for(pack_module)
    RecipeRegistry.unregister_source(source)

    pack_module.recipes()
    |> Enum.reduce_while(:ok, fn %Recipe{} = recipe, :ok ->
      case RecipeRegistry.register(recipe, source) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> cleanup_failed_register(source)
  end

  @doc "Unregisters all recipes owned by a pack."
  @spec unregister_pack(pack_module()) :: :ok
  def unregister_pack(pack_module) when is_atom(pack_module) do
    RecipeRegistry.unregister_source(source_for(pack_module))
  end

  @doc "Reloads a pack by removing its previous source-owned entries, then registering its current recipes."
  @spec reload_pack(pack_module()) :: :ok | {:error, term()}
  def reload_pack(pack_module) when is_atom(pack_module), do: register_pack(pack_module)

  @doc "Returns the contribution source used for a pack."
  @spec source_for(pack_module()) :: {:extension, atom()}
  def source_for(pack_module) when is_atom(pack_module), do: {:extension, pack_module.name()}

  @spec load_packs([pack_module()], [atom()]) :: state()
  defp load_packs(packs, disabled) do
    Enum.reduce(packs, %{loaded: [], failed: []}, fn pack, state ->
      load_pack(pack, disabled, state)
    end)
  end

  @spec load_pack(pack_module(), [atom()], state()) :: state()
  defp load_pack(pack, disabled, state) do
    name = pack.name()

    if name in disabled do
      unregister_pack(pack)
      state
    else
      case register_pack(pack) do
        :ok -> %{state | loaded: state.loaded ++ [name]}
        {:error, reason} -> record_failed_pack(state, name, reason)
      end
    end
  end

  @spec record_failed_pack(state(), atom(), term()) :: state()
  defp record_failed_pack(state, name, reason) do
    Minga.Log.warning(:config, "Recipe pack #{name} failed to load: #{inspect(reason)}")
    %{state | failed: state.failed ++ [{name, reason}]}
  end

  @spec disabled_pack_names() :: [atom()]
  defp disabled_pack_names do
    Application.get_env(:minga, :disabled_recipe_packs, [])
  end

  @spec cleanup_failed_register(:ok | {:error, term()}, RecipeRegistry.contribution_source()) ::
          :ok | {:error, term()}
  defp cleanup_failed_register(:ok, _source), do: :ok

  defp cleanup_failed_register({:error, reason}, source) do
    RecipeRegistry.unregister_source(source)
    {:error, reason}
  end
end
