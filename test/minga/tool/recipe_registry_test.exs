defmodule Minga.Tool.Recipe.RegistryTest do
  use ExUnit.Case, async: true

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

    test "returns recipe for all built-in tools" do
      for name <- [
            :expert,
            :pyright,
            :typescript_language_server,
            :rust_analyzer,
            :gopls,
            :prettier,
            :black,
            :elixir_ls,
            :lexical,
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
    test "returns all built-in recipes" do
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
      assert :elixir_ls in names
      assert :lexical in names
    end

    test "returns empty list for unknown language" do
      assert Registry.for_language(:brainfuck) == []
    end
  end
end
