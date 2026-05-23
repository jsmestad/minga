defmodule Minga.Tool.Recipe.RegistryTest do
  # Mutates the global recipe registry in source-cleanup tests.
  use ExUnit.Case, async: false

  alias Minga.Tool.Recipe
  alias Minga.Tool.Recipe.Registry

  describe "get/1" do
    test "returns recipe for known tool" do
      recipe = Registry.get(:pyright)
      assert %Recipe{name: :pyright, label: "Pyright"} = recipe
      assert recipe.method == :npm
      assert "pyright-langserver" in recipe.provides
    end

    test "returns nil for unknown tool" do
      assert Registry.get(:nonexistent_tool) == nil
    end

    test "returns recipe for all bundled tools" do
      for name <- [
            :expert,
            :pyright,
            :typescript_language_server,
            :rust_analyzer,
            :gopls,
            :prettier,
            :black,
            :lua_language_server,
            :stylua,
            :zls,
            :clangd
          ] do
        assert %Recipe{name: ^name} = Registry.get(name)
      end
    end
  end

  describe "for_command/1" do
    test "finds recipe by provided command" do
      recipe = Registry.for_command("pyright-langserver")
      assert %Recipe{name: :pyright} = recipe
    end

    test "finds recipe by alternative provided command" do
      recipe = Registry.for_command("pyright")
      assert %Recipe{name: :pyright} = recipe
    end

    test "returns nil for unknown command" do
      assert Registry.for_command("unknown-binary") == nil
    end

    test "finds expert by command" do
      recipe = Registry.for_command("expert")
      assert %Recipe{name: :expert, method: :github_release} = recipe
    end

    test "finds gopls by command" do
      recipe = Registry.for_command("gopls")
      assert %Recipe{name: :gopls, method: :go_install} = recipe
    end

    test "finds prettier by command" do
      recipe = Registry.for_command("prettier")
      assert %Recipe{name: :prettier, category: :formatter} = recipe
    end
  end

  describe "all/0" do
    test "returns all bundled recipes" do
      recipes = Registry.all()
      assert length(recipes) >= 13
      names = Enum.map(recipes, & &1.name)
      assert :pyright in names
      assert :gopls in names
      assert :prettier in names
    end
  end

  describe "by_category/1" do
    test "filters to LSP servers" do
      servers = Registry.by_category(:lsp_server)
      assert length(servers) >= 7
      assert Enum.all?(servers, fn r -> r.category == :lsp_server end)
    end

    test "filters to formatters" do
      formatters = Registry.by_category(:formatter)
      assert length(formatters) >= 2
      names = Enum.map(formatters, & &1.name)
      assert :prettier in names
      assert :black in names
    end
  end

  describe "source ownership" do
    test "rejects duplicate pack-provided recipes from another source" do
      recipe = %Recipe{
        name: :pyright,
        label: "Custom Pyright",
        description: "Duplicate recipe",
        provides: ["pyright-custom"],
        method: :npm,
        package: "pyright-custom",
        homepage: "https://example.invalid/pyright",
        category: :lsp_server,
        languages: [:python]
      }

      assert {:error,
              {:duplicate_recipe, :pyright, {:extension, :python_recipe_pack},
               {:extension, :recipe_collision}}} =
               Registry.register(recipe, {:extension, :recipe_collision})
    end

    test "same-source re-registration replaces stale recipe indexes" do
      source = {:extension, :recipe_registry_replace_test}

      old_recipe = %Recipe{
        name: :replace_recipe_test,
        label: "Replace Recipe",
        description: "Old recipe",
        provides: ["replace-recipe-old"],
        method: :npm,
        package: "replace-recipe-old",
        homepage: "https://example.invalid/old",
        category: :formatter,
        languages: [:elixir]
      }

      new_recipe = %Recipe{
        name: :replace_recipe_test,
        label: "Replace Recipe New",
        description: "New recipe",
        provides: ["replace-recipe-new"],
        method: :npm,
        package: "replace-recipe-new",
        homepage: "https://example.invalid/new",
        category: :formatter,
        languages: [:elixir]
      }

      on_exit(fn -> Registry.unregister_source(source) end)

      assert :ok = Registry.register(old_recipe, source)
      assert :ok = Registry.register(new_recipe, source)

      assert Registry.for_command("replace-recipe-old") == nil

      assert %Recipe{name: :replace_recipe_test, label: "Replace Recipe New"} =
               Registry.get(:replace_recipe_test)

      assert %Recipe{name: :replace_recipe_test, label: "Replace Recipe New"} =
               Registry.for_command("replace-recipe-new")
    end

    test "unregister_source removes recipes and command indexes for only that source" do
      source = {:extension, :recipe_registry_test}
      other_source = {:extension, :recipe_registry_other}

      recipe = %Recipe{
        name: :source_recipe_test,
        label: "Source Recipe",
        description: "Test recipe",
        provides: ["source-recipe-test"],
        method: :npm,
        package: "source-recipe-test",
        homepage: "https://example.invalid/source",
        category: :formatter,
        languages: [:elixir]
      }

      other = %Recipe{
        name: :other_source_recipe_test,
        label: "Other Source Recipe",
        description: "Other test recipe",
        provides: ["other-source-recipe-test"],
        method: :npm,
        package: "other-source-recipe-test",
        homepage: "https://example.invalid/other",
        category: :formatter,
        languages: [:elixir]
      }

      assert :ok = Registry.register(recipe, source)
      assert :ok = Registry.register(other, other_source)
      assert :ok = Registry.unregister_source(source)

      assert Registry.get(:source_recipe_test) == nil
      assert Registry.for_command("source-recipe-test") == nil
      assert %Recipe{name: :other_source_recipe_test} = Registry.get(:other_source_recipe_test)

      Registry.unregister_source(other_source)
    end

    test "unregister_source exits when the registry name is unavailable" do
      pid = Process.whereis(Registry)
      assert true = Process.unregister(Registry)

      try do
        assert catch_exit(Registry.unregister_source(:config))
      after
        if Process.whereis(Registry) == nil do
          assert true = Process.register(pid, Registry)
        end
      end
    end
  end

  describe "for_language/1" do
    test "finds tools for Python" do
      tools = Registry.for_language(:python)
      names = Enum.map(tools, & &1.name)
      assert :pyright in names
      assert :black in names
    end

    test "finds tools for Elixir" do
      tools = Registry.for_language(:elixir)
      names = Enum.map(tools, & &1.name)
      assert :expert in names
    end

    test "returns empty list for unknown language" do
      assert Registry.for_language(:brainfuck) == []
    end
  end
end
