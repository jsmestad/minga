defmodule Minga.Extensions.RecipePacksTest do
  # Mutates the global recipe registry via pack register/unregister.
  use ExUnit.Case, async: false

  alias Minga.Tool.Recipe
  alias Minga.Tool.Recipe.Registry
  alias Minga.Extensions.RecipePacks

  setup do
    on_exit(fn ->
      for pack <- RecipePacks.packs() do
        RecipePacks.register_pack(pack)
      end
    end)

    :ok
  end

  describe "register_pack/1" do
    test "Elixir pack registers Expert, Erlang LS, and Gleam LSP" do
      assert %Recipe{name: :expert} = Registry.get(:expert)
      assert %Recipe{name: :erlang_ls} = Registry.get(:erlang_ls)
      assert %Recipe{name: :gleam_lsp} = Registry.get(:gleam_lsp)
    end

    test "Python pack registers Pyright and Black" do
      assert %Recipe{name: :pyright} = Registry.get(:pyright)
      assert %Recipe{name: :black} = Registry.get(:black)
    end

    test "Web pack registers TypeScript, Prettier, Intelephense, and Dart" do
      assert %Recipe{name: :typescript_language_server} =
               Registry.get(:typescript_language_server)

      assert %Recipe{name: :prettier} = Registry.get(:prettier)
      assert %Recipe{name: :intelephense} = Registry.get(:intelephense)
      assert %Recipe{name: :dart_language_server} = Registry.get(:dart_language_server)
    end

    test "Systems pack registers rust-analyzer, gopls, clangd, and ZLS" do
      assert %Recipe{name: :rust_analyzer} = Registry.get(:rust_analyzer)
      assert %Recipe{name: :gopls} = Registry.get(:gopls)
      assert %Recipe{name: :clangd} = Registry.get(:clangd)
      assert %Recipe{name: :zls} = Registry.get(:zls)
    end

    test "JVM pack registers JDTLS, Kotlin, and Metals" do
      assert %Recipe{name: :jdtls} = Registry.get(:jdtls)
      assert %Recipe{name: :kotlin_language_server} = Registry.get(:kotlin_language_server)
      assert %Recipe{name: :metals} = Registry.get(:metals)
    end

    test "Misc pack registers remaining language tools" do
      assert %Recipe{name: :lua_language_server} = Registry.get(:lua_language_server)
      assert %Recipe{name: :stylua} = Registry.get(:stylua)
      assert %Recipe{name: :omnisharp} = Registry.get(:omnisharp)
      assert %Recipe{name: :sourcekit_lsp} = Registry.get(:sourcekit_lsp)
      assert %Recipe{name: :haskell_language_server} = Registry.get(:haskell_language_server)
      assert %Recipe{name: :ocamllsp} = Registry.get(:ocamllsp)
      assert %Recipe{name: :nil_ls} = Registry.get(:nil_ls)
      assert %Recipe{name: :terraform_ls} = Registry.get(:terraform_ls)
    end

    test "recipes carry extension source tags" do
      source = RecipePacks.source_for(Minga.Extensions.RecipePacks.Elixir)
      assert {:extension, :elixir_recipe_pack} = source
    end

    test "command index resolves pack-provided recipes" do
      assert %Recipe{name: :expert} = Registry.for_command("expert")
      assert %Recipe{name: :pyright} = Registry.for_command("pyright-langserver")
      assert %Recipe{name: :gopls} = Registry.for_command("gopls")
      assert %Recipe{name: :prettier} = Registry.for_command("prettier")
    end
  end

  describe "unregister_pack/1" do
    test "removing Python pack removes only its recipes" do
      RecipePacks.unregister_pack(Minga.Extensions.RecipePacks.Python)

      assert Registry.get(:pyright) == nil
      assert Registry.get(:black) == nil
      assert Registry.for_command("pyright-langserver") == nil
      assert Registry.for_command("black") == nil

      assert %Recipe{name: :expert} = Registry.get(:expert)
      assert %Recipe{name: :gopls} = Registry.get(:gopls)
      assert %Recipe{name: :prettier} = Registry.get(:prettier)
    end

    test "removing all packs leaves the registry empty" do
      for pack <- RecipePacks.packs() do
        RecipePacks.unregister_pack(pack)
      end

      assert Registry.all() == []
    end
  end

  describe "reload_pack/1" do
    test "reloading does not leave duplicates" do
      before = Registry.all() |> Enum.map(& &1.name) |> Enum.sort()
      RecipePacks.reload_pack(Minga.Extensions.RecipePacks.Python)
      after_reload = Registry.all() |> Enum.map(& &1.name) |> Enum.sort()

      assert before == after_reload
    end
  end

  describe "source_for/1" do
    test "returns extension source tag for each pack" do
      assert {:extension, :elixir_recipe_pack} =
               RecipePacks.source_for(Minga.Extensions.RecipePacks.Elixir)

      assert {:extension, :python_recipe_pack} =
               RecipePacks.source_for(Minga.Extensions.RecipePacks.Python)

      assert {:extension, :web_recipe_pack} =
               RecipePacks.source_for(Minga.Extensions.RecipePacks.Web)

      assert {:extension, :systems_recipe_pack} =
               RecipePacks.source_for(Minga.Extensions.RecipePacks.Systems)

      assert {:extension, :jvm_recipe_pack} =
               RecipePacks.source_for(Minga.Extensions.RecipePacks.Jvm)

      assert {:extension, :misc_recipe_pack} =
               RecipePacks.source_for(Minga.Extensions.RecipePacks.Misc)
    end
  end

  describe "expert_asset?/2" do
    alias Minga.Extensions.RecipePacks.Elixir, as: ElixirPack

    test "matches macOS arm64 bare binary" do
      assert ElixirPack.expert_asset?("expert_darwin_arm64", "darwin_arm64")
    end

    test "matches macOS amd64 bare binary" do
      assert ElixirPack.expert_asset?("expert_darwin_amd64", "darwin_amd64")
    end

    test "matches Linux amd64 bare binary" do
      assert ElixirPack.expert_asset?("expert_linux_amd64", "linux_amd64")
    end

    test "rejects macOS asset when platform is linux" do
      refute ElixirPack.expert_asset?("expert_darwin_arm64", "linux_amd64")
    end

    test "rejects checksums file" do
      refute ElixirPack.expert_asset?("expert_checksums.txt", "darwin_arm64")
    end

    test "rejects unrelated assets" do
      refute ElixirPack.expert_asset?("some-other-tool", "darwin_arm64")
    end
  end

  describe "clangd_asset?/2" do
    alias Minga.Extensions.RecipePacks.Systems

    test "matches the macOS asset with darwin suffix" do
      assert Systems.clangd_asset?("clangd-mac-21.1.8.zip", "darwin_arm64")
    end

    test "matches the macOS asset with darwin amd64 suffix" do
      assert Systems.clangd_asset?("clangd-mac-21.1.8.zip", "darwin_amd64")
    end

    test "matches the Linux asset with linux suffix" do
      assert Systems.clangd_asset?("clangd-linux-21.1.8.zip", "linux_amd64")
    end

    test "rejects macOS asset when platform is linux" do
      refute Systems.clangd_asset?("clangd-mac-21.1.8.zip", "linux_amd64")
    end

    test "rejects indexing tools asset" do
      refute Systems.clangd_asset?("clangd_indexing_tools-mac-21.1.8.zip", "darwin_arm64")
    end

    test "matches the Windows asset with windows suffix" do
      assert Systems.clangd_asset?("clangd-windows-21.1.8.zip", "windows_amd64")
    end

    test "rejects debug symbols asset" do
      refute Systems.clangd_asset?("clangd-debug-symbols-windows-21.1.8.7z", "darwin_arm64")
    end
  end
end
