defmodule Minga.Extensions.ThemePacks do
  @moduledoc """
  Bundled theme packs registered through extension-owned sources.

  Bundled packs use the same `Minga.Config.ThemeRegistry.register_themes/2` path as third-party theme packs. Each palette module provides a `theme/0` function returning a complete theme struct. Stopping or reloading a pack removes all its themes from the registry without affecting other packs' themes or user-loaded themes.

  Registration runs synchronously during supervision startup. No idle registrar process remains afterward.
  """

  alias Minga.Config.ThemeRegistry
  alias Minga.Extensions.PackLoader

  @typedoc "A module that implements the theme-pack extension callbacks."
  @type pack_module :: module()

  @packs [
    Minga.Extensions.ThemePacks.AstroNvim,
    Minga.Extensions.ThemePacks.Catppuccin,
    Minga.Extensions.ThemePacks.Doom,
    Minga.Extensions.ThemePacks.One
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

  @doc "Loads bundled theme packs synchronously and returns `:ignore` (no process remains)."
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    PackLoader.start_link(
      opts,
      @packs,
      :disabled_theme_packs,
      &register_pack/1,
      &unregister_pack/1,
      "Theme"
    )
  end

  @doc "Returns bundled theme pack modules in startup order."
  @spec packs() :: [pack_module()]
  def packs, do: @packs

  @doc "Registers all themes owned by a pack, replacing stale entries from an earlier load."
  @spec register_pack(pack_module()) :: :ok | {:error, term()}
  def register_pack(pack_module) when is_atom(pack_module) do
    source = PackLoader.source_for(pack_module)
    themes = collect_pack_themes(pack_module)
    ThemeRegistry.register_themes(themes, source)
  end

  @doc "Unregisters all themes owned by a pack."
  @spec unregister_pack(pack_module()) :: :ok
  def unregister_pack(pack_module) when is_atom(pack_module) do
    ThemeRegistry.unregister_source(PackLoader.source_for(pack_module))
  end

  @doc "Reloads a pack by removing its previous source-owned entries, then registering its current modules."
  @spec reload_pack(pack_module()) :: :ok | {:error, term()}
  def reload_pack(pack_module) when is_atom(pack_module), do: register_pack(pack_module)

  @doc "Returns the contribution source used for a pack."
  @spec source_for(pack_module()) :: {:extension, atom()}
  def source_for(pack_module) when is_atom(pack_module), do: PackLoader.source_for(pack_module)

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
