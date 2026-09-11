defmodule Minga.Extensions.ThemePacks do
  @moduledoc """
  Starts bundled theme packs and registers their palettes through extension-owned sources.

  Bundled packs use the same `Minga.Config.ThemeRegistry.register_themes/2` path as third-party theme packs. Each palette module provides a `theme/0` function returning a complete theme struct. Stopping or reloading a pack removes all its themes from the registry without affecting other packs' themes or user-loaded themes.
  """

  use Agent

  alias Minga.Config.ThemeRegistry
  alias Minga.Extensions.PackLoader

  @typedoc "A module that implements the theme-pack extension callbacks."
  @type pack_module :: module()

  @typedoc "Runtime state for the bundled pack starter."
  @type state :: %{loaded: [atom()], failed: [{atom(), term()}]}

  @packs [
    Minga.Extensions.ThemePacks.AstroNvim,
    Minga.Extensions.ThemePacks.Catppuccin,
    Minga.Extensions.ThemePacks.Doom,
    Minga.Extensions.ThemePacks.One
  ]

  @doc "Starts the bundled theme pack loader."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    packs = Keyword.get(opts, :packs, @packs)
    disabled = Keyword.get(opts, :disabled, disabled_pack_names())

    Agent.start_link(fn -> load_packs(packs, disabled) end, name: name)
  end

  @doc "Returns bundled theme pack modules in startup order."
  @spec packs() :: [pack_module()]
  def packs, do: @packs

  @doc "Registers all themes owned by a pack, replacing stale entries from an earlier load."
  @spec register_pack(pack_module()) :: :ok | {:error, term()}
  def register_pack(pack_module) when is_atom(pack_module) do
    source = source_for(pack_module)
    themes = collect_pack_themes(pack_module)
    ThemeRegistry.register_themes(themes, source)
  end

  @doc "Unregisters all themes owned by a pack."
  @spec unregister_pack(pack_module()) :: :ok
  def unregister_pack(pack_module) when is_atom(pack_module) do
    ThemeRegistry.unregister_source(source_for(pack_module))
  end

  @doc "Reloads a pack by removing its previous source-owned entries, then registering its current modules."
  @spec reload_pack(pack_module()) :: :ok | {:error, term()}
  def reload_pack(pack_module) when is_atom(pack_module), do: register_pack(pack_module)

  @doc "Returns the contribution source used for a pack."
  @spec source_for(pack_module()) :: {:extension, atom()}
  def source_for(pack_module) when is_atom(pack_module), do: {:extension, pack_module.name()}

  @spec load_packs([pack_module()], [atom()]) :: state()
  defp load_packs(packs, disabled), do: PackLoader.load(packs, disabled, __MODULE__, "Theme")

  @spec disabled_pack_names() :: [atom()]
  defp disabled_pack_names do
    Application.get_env(:minga, :disabled_theme_packs, [])
  end

  @spec collect_pack_themes(pack_module()) :: %{atom() => term()}
  defp collect_pack_themes(pack_module) do
    pack_module.theme_modules()
    |> Enum.map(fn mod ->
      theme = mod.theme()
      {theme.name, theme}
    end)
    |> Map.new()
  end
end
