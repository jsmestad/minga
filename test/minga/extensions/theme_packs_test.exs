defmodule Minga.Extensions.ThemePacksTest do
  @moduledoc "Tests for bundled theme pack lifecycle. async: false because persistent_term is global."
  use ExUnit.Case, async: false

  alias MingaEditor.UI.Theme
  alias Minga.Extensions.ThemePacks

  setup do
    on_exit(fn ->
      for pack <- ThemePacks.packs() do
        ThemePacks.register_pack(pack)
      end
    end)

    :ok
  end

  describe "register_pack/1" do
    test "Catppuccin pack registers its four themes" do
      assert {:ok, _} = Theme.get(:catppuccin_frappe)
      assert {:ok, _} = Theme.get(:catppuccin_latte)
      assert {:ok, _} = Theme.get(:catppuccin_macchiato)
      assert {:ok, _} = Theme.get(:catppuccin_mocha)
    end

    test "Doom pack registers doom_one" do
      assert {:ok, _} = Theme.get(:doom_one)
    end

    test "One pack registers one_dark and one_light" do
      assert {:ok, _} = Theme.get(:one_dark)
      assert {:ok, _} = Theme.get(:one_light)
    end
  end

  describe "unregister_pack/1" do
    test "removing Catppuccin pack removes only its themes" do
      ThemePacks.unregister_pack(Minga.Extensions.ThemePacks.Catppuccin)

      assert :error = Theme.get(:catppuccin_frappe)
      assert :error = Theme.get(:catppuccin_latte)
      assert :error = Theme.get(:catppuccin_macchiato)
      assert :error = Theme.get(:catppuccin_mocha)

      assert {:ok, _} = Theme.get(:doom_one)
      assert {:ok, _} = Theme.get(:one_dark)
      assert {:ok, _} = Theme.get(:one_light)
    end

    test "removing all packs leaves only the fallback" do
      for pack <- ThemePacks.packs() do
        ThemePacks.unregister_pack(pack)
      end

      available = Theme.available()
      assert available == [:minga_default]
      assert {:ok, %Theme{name: :minga_default}} = Theme.get(:minga_default)
    end
  end

  describe "reload_pack/1" do
    test "reloading does not leave duplicates in available/0" do
      before = Theme.available()
      ThemePacks.reload_pack(Minga.Extensions.ThemePacks.Catppuccin)
      after_reload = Theme.available()

      assert before == after_reload
    end
  end

  describe "source_for/1" do
    test "returns extension source tag" do
      assert {:extension, :catppuccin_theme_pack} =
               ThemePacks.source_for(Minga.Extensions.ThemePacks.Catppuccin)

      assert {:extension, :doom_theme_pack} =
               ThemePacks.source_for(Minga.Extensions.ThemePacks.Doom)

      assert {:extension, :one_theme_pack} =
               ThemePacks.source_for(Minga.Extensions.ThemePacks.One)
    end
  end
end
