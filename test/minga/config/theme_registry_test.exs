defmodule Minga.Config.ThemeRegistryTest do
  @moduledoc "Tests for theme registry with fallback. async: false because persistent_term is global."
  use ExUnit.Case, async: false

  alias Minga.Config.ThemeRegistry
  alias Minga.Extension.ContributionCleanup
  alias Minga.Extensions.ThemePacks

  setup do
    on_exit(fn ->
      for pack <- ThemePacks.packs() do
        ThemePacks.register_pack(pack)
      end
    end)

    :ok
  end

  test "fallback present after disabling all packs" do
    for pack <- ThemePacks.packs() do
      ThemePacks.unregister_pack(pack)
    end

    available = ThemeRegistry.available()
    assert :minga_default in available
    assert :error = ThemeRegistry.get_theme(:minga_default)
  end

  test "seed_builtin preserves registered themes and available names" do
    themes = ThemeRegistry.stored_themes()
    names = ThemeRegistry.available()

    assert :ok = ThemeRegistry.seed_builtin()
    assert :minga_default in names
    assert ThemeRegistry.available() == names
    assert ThemeRegistry.stored_themes() == themes
  end

  test "available includes pack themes after registration" do
    available = ThemeRegistry.available()
    assert :doom_one in available
    assert :catppuccin_mocha in available
    assert :one_dark in available
    assert :minga_default in available
  end

  test "a rejected replacement keeps the existing batch and registers cleanup" do
    owner = {:extension, :theme_registry_owner_test}
    attempted = {:extension, :theme_registry_attempted_test}

    on_exit(fn ->
      ThemeRegistry.unregister_source(owner)
      ThemeRegistry.unregister_source(attempted)
    end)

    assert :ok = ThemeRegistry.register_themes(%{registry_conflict: nil}, owner)
    assert :ok = ThemeRegistry.register_themes(%{registry_retained: :original}, attempted)
    names = ThemeRegistry.available()
    :ok = ContributionCleanup.unregister(:themes)

    assert {:error, {:duplicate_name, :registry_conflict, ^owner, ^attempted}} =
             ThemeRegistry.register_themes(
               %{registry_conflict: :new, registry_unpublished: :new},
               attempted
             )

    assert ThemeRegistry.available() == names
    assert %{registry_conflict: nil, registry_retained: :original} = ThemeRegistry.stored_themes()

    assert %{registry_conflict: ^owner, registry_retained: ^attempted} =
             ThemeRegistry.stored_sources()

    assert :error = ThemeRegistry.get_theme(:registry_unpublished)
    assert :ok = ContributionCleanup.finalize_source(attempted, :themes)
    assert :error = ThemeRegistry.get_theme(:registry_retained)
    assert {:ok, nil} = ThemeRegistry.get_theme(:registry_conflict)
  end

  test "removing a config override does not restore the displaced extension theme" do
    extension = {:extension, :theme_registry_displaced_test}
    config_names = for {name, :config} <- ThemeRegistry.stored_sources(), do: name
    original_config = Map.take(ThemeRegistry.stored_themes(), config_names)

    on_exit(fn ->
      ThemeRegistry.unregister_source(extension)
      ThemeRegistry.register_themes(original_config, :config)
    end)

    assert :ok = ThemeRegistry.register_themes(%{registry_displaced: :extension_data}, extension)
    assert :ok = ThemeRegistry.register_themes(%{registry_displaced: :config_data}, :config)
    assert {:ok, :config_data} = ThemeRegistry.get_theme(:registry_displaced)
    assert %{registry_displaced: :config} = ThemeRegistry.stored_sources()

    names = ThemeRegistry.available()
    assert :registry_displaced in names
    assert names == Enum.sort(Enum.uniq(names))

    assert :ok = ThemeRegistry.register_themes(%{}, :config)
    assert :error = ThemeRegistry.get_theme(:registry_displaced)
    refute :registry_displaced in ThemeRegistry.available()
    refute Map.has_key?(ThemeRegistry.stored_sources(), :registry_displaced)
  end
end
