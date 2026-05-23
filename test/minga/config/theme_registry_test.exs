defmodule Minga.Config.ThemeRegistryTest do
  @moduledoc "Tests for theme registry with fallback. async: false because persistent_term is global."
  use ExUnit.Case, async: false

  alias Minga.Config.ThemeRegistry
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
  end

  test "seed_builtin preserves fallback in name list" do
    ThemeRegistry.seed_builtin()
    assert :minga_default in ThemeRegistry.available()
  end

  test "available includes pack themes after registration" do
    available = ThemeRegistry.available()
    assert :doom_one in available
    assert :catppuccin_mocha in available
    assert :one_dark in available
    assert :minga_default in available
  end
end
