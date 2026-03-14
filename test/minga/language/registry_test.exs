defmodule Minga.Language.RegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Language
  alias Minga.Language.Registry

  describe "get/1" do
    test "returns language definition by name" do
      lang = Registry.get(:elixir)
      assert %Language{} = lang
      assert lang.name == :elixir
      assert lang.label == "Elixir"
      assert lang.comment_token == "# "
      assert lang.grammar == "elixir"
    end

    test "returns nil for unknown language" do
      assert Registry.get(:nonexistent_language_xyz) == nil
    end

    test "all priority languages are registered" do
      for name <- [:elixir, :ruby, :typescript, :c, :cpp, :swift] do
        assert %Language{name: ^name} = Registry.get(name)
      end
    end
  end

  describe "for_extension/1" do
    test "looks up language by extension" do
      lang = Registry.for_extension("ex")
      assert lang.name == :elixir
    end

    test "case-insensitive extension lookup" do
      lang = Registry.for_extension("EX")
      assert lang.name == :elixir
    end

    test "returns nil for unknown extension" do
      assert Registry.for_extension("zzzzz") == nil
    end

    test "multiple extensions map to the same language" do
      assert Registry.for_extension("ts").name == :typescript
      assert Registry.for_extension("mts").name == :typescript
      assert Registry.for_extension("cts").name == :typescript
    end
  end

  describe "for_filename/1" do
    test "looks up language by exact filename" do
      lang = Registry.for_filename("Makefile")
      assert lang.name == :make
    end

    test "returns nil for unknown filename" do
      assert Registry.for_filename("nonexistent_file_xyz") == nil
    end

    test "filename match is case-sensitive" do
      assert Registry.for_filename("Makefile") != nil
      assert Registry.for_filename("makefile") == nil
    end
  end

  describe "for_shebang/1" do
    test "looks up language by shebang interpreter" do
      lang = Registry.for_shebang("python3")
      assert lang.name == :python
    end

    test "returns nil for unknown interpreter" do
      assert Registry.for_shebang("nonexistent_interp") == nil
    end
  end

  describe "all/0" do
    test "returns all registered languages" do
      langs = Registry.all()
      assert is_list(langs)
      assert length(langs) > 40
      names = Enum.map(langs, & &1.name)
      assert :elixir in names
      assert :ruby in names
      assert :typescript in names
    end
  end

  describe "supported_names/0" do
    test "returns all registered language names" do
      names = Registry.supported_names()
      assert :elixir in names
      assert :text in names
      assert :go in names
    end
  end

  describe "register/1" do
    test "registers a new language at runtime" do
      lang = %Language{
        name: :test_lang_xyz,
        label: "Test Lang",
        comment_token: "// ",
        extensions: ["xyz_test_ext"]
      }

      assert :ok = Registry.register(lang)
      assert Registry.get(:test_lang_xyz).label == "Test Lang"
      assert Registry.for_extension("xyz_test_ext").name == :test_lang_xyz
    end

    test "runtime registration overrides existing definition" do
      original = Registry.get(:elixir)
      assert original.label == "Elixir"

      override = %Language{
        name: :elixir,
        label: "Elixir Override",
        comment_token: "## ",
        extensions: ["ex", "exs"]
      }

      Registry.register(override)
      assert Registry.get(:elixir).label == "Elixir Override"

      # Restore original
      Registry.register(original)
      assert Registry.get(:elixir).label == "Elixir"
    end
  end

  describe "language data completeness" do
    test "all languages with LSP servers have valid ServerConfig structs" do
      for lang <- Registry.all(), server <- lang.language_servers do
        assert is_atom(server.name), "#{lang.name}: server name should be atom"
        assert is_binary(server.command), "#{lang.name}: server command should be string"
      end
    end

    test "all languages have non-empty comment tokens" do
      for lang <- Registry.all() do
        assert is_binary(lang.comment_token), "#{lang.name}: comment_token should be string"
        assert lang.comment_token != "", "#{lang.name}: comment_token should not be empty"
      end
    end

    test "languages with grammars have string grammar names" do
      for lang <- Registry.all(), lang.grammar != nil do
        assert is_binary(lang.grammar), "#{lang.name}: grammar should be string"
      end
    end

    test "languages with icons have both icon and icon_color" do
      for lang <- Registry.all(), lang.icon != nil do
        assert is_binary(lang.icon), "#{lang.name}: icon should be string"
        assert is_integer(lang.icon_color), "#{lang.name}: icon_color should be integer"
      end
    end
  end
end
