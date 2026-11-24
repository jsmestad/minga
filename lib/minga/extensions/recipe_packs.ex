defmodule Minga.Extensions.RecipePacks do
  @moduledoc """
  Bundled recipe packs registered through extension-owned sources.

  Bundled packs use the same `Minga.Tool.Recipe.Registry.register/2` path as third-party recipe packs. Each pack module provides a `recipes/0` function returning a list of `%Recipe{}` structs. Stopping or reloading a pack removes all its recipes (and their command-index entries) from the registry without affecting other packs' recipes or user-supplied recipes.

  Registration runs synchronously during supervision startup. No idle registrar process remains afterward.
  """

  alias Minga.Extensions.PackLoader
  alias Minga.Tool.Recipe
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry

  @typedoc "A module that implements the recipe-pack extension callbacks."
  @type pack_module :: module()

  @packs [
    Minga.Extensions.RecipePacks.Elixir,
    Minga.Extensions.RecipePacks.Python,
    Minga.Extensions.RecipePacks.Web,
    Minga.Extensions.RecipePacks.Systems,
    Minga.Extensions.RecipePacks.Jvm,
    Minga.Extensions.RecipePacks.Misc
  ]

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc "Loads bundled recipe packs synchronously and returns `:ignore` (no process remains)."
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    PackLoader.start_link(
      opts,
      @packs,
      :disabled_recipe_packs,
      &register_pack/1,
      &unregister_pack/1,
      "Recipe"
    )
  end

  @doc "Returns bundled recipe pack modules in startup order."
  @spec packs() :: [pack_module()]
  def packs, do: @packs

  @doc "Registers all recipes owned by a pack, replacing stale entries from an earlier load."
  @spec register_pack(pack_module()) :: :ok | {:error, term()}
  def register_pack(pack_module) when is_atom(pack_module) do
    source = PackLoader.source_for(pack_module)
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
    RecipeRegistry.unregister_source(PackLoader.source_for(pack_module))
  end

  @doc "Reloads a pack by removing its previous source-owned entries, then registering its current recipes."
  @spec reload_pack(pack_module()) :: :ok | {:error, term()}
  def reload_pack(pack_module) when is_atom(pack_module), do: register_pack(pack_module)

  @doc "Returns the contribution source used for a pack."
  @spec source_for(pack_module()) :: {:extension, atom()}
  def source_for(pack_module) when is_atom(pack_module), do: PackLoader.source_for(pack_module)

  @spec cleanup_failed_register(:ok | {:error, term()}, RecipeRegistry.contribution_source()) ::
          :ok | {:error, term()}
  defp cleanup_failed_register(:ok, _source), do: :ok

  defp cleanup_failed_register({:error, reason}, source) do
    RecipeRegistry.unregister_source(source)
    {:error, reason}
  end
end
