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

    test "missing grammar languages expose grammar names" do
      expected = %{
        sql: "sql",
        xml: "xml",
        ini: "ini",
        swift: "swift",
        vim: "vim",
        protobuf: "protobuf",
        fish: "fish",
        perl: "perl",
        gitconfig: "ini",
        editorconfig: "ini"
      }

      for {name, grammar} <- expected do
        assert %Language{name: ^name, grammar: ^grammar} = Registry.get(name)
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

    test "looks up Vim and INI-backed config filenames" do
      assert Registry.for_filename(".vimrc").name == :vim
      assert Registry.for_filename("_vimrc").name == :vim
      assert Registry.for_filename(".gvimrc").name == :vim
      assert Registry.for_filename(".gitconfig").grammar == "ini"
      assert Registry.for_filename(".editorconfig").grammar == "ini"
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

    test "same-source re-registration replaces stale language indexes" do
      source = {:extension, :language_registry_replace_test}

      old_lang = %Language{
        name: :replace_lang_xyz,
        label: "Replace Lang",
        comment_token: "// ",
        extensions: ["replace_old_ext"],
        filenames: ["ReplaceOld"],
        shebangs: ["replace_old_shebang"]
      }

      new_lang = %Language{
        name: :replace_lang_xyz,
        label: "Replace Lang New",
        comment_token: "# ",
        extensions: ["replace_new_ext"],
        filenames: ["ReplaceNew"],
        shebangs: ["replace_new_shebang"]
      }

      on_exit(fn -> Registry.unregister_source(source) end)

      assert :ok = Registry.register(old_lang, source)
      assert :ok = Registry.register(new_lang, source)

      assert Registry.for_extension("replace_old_ext") == nil
      assert Registry.for_filename("ReplaceOld") == nil
      assert Registry.for_shebang("replace_old_shebang") == nil

      assert %Language{name: :replace_lang_xyz, label: "Replace Lang New"} =
               Registry.get(:replace_lang_xyz)

      assert %Language{name: :replace_lang_xyz, label: "Replace Lang New"} =
               Registry.for_extension("replace_new_ext")

      assert %Language{name: :replace_lang_xyz, label: "Replace Lang New"} =
               Registry.for_shebang("replace_new_shebang")
    end

    test "unregister_source removes language names and indexes for only that source" do
      source = {:extension, :language_registry_test}
      other_source = {:extension, :language_registry_other}

      lang = %Language{
        name: :source_lang_xyz,
        label: "Source Lang",
        comment_token: "// ",
        extensions: ["source_xyz"],
        filenames: ["Sourcefile"],
        shebangs: ["sourcebang"]
      }

      other = %Language{
        name: :other_source_lang_xyz,
        label: "Other Source Lang",
        comment_token: "# ",
        extensions: ["other_source_xyz"]
      }

      assert :ok = Registry.register(lang, source)
      assert :ok = Registry.register(other, other_source)
      assert :ok = Registry.unregister_source(source)

      assert Registry.get(:source_lang_xyz) == nil
      assert Registry.for_extension("source_xyz") == nil
      assert Registry.for_filename("Sourcefile") == nil
      assert Registry.for_shebang("sourcebang") == nil
      assert %Language{name: :other_source_lang_xyz} = Registry.get(:other_source_lang_xyz)

      Registry.unregister_source(other_source)
    end

    test "runtime registration rejects duplicate bundled pack definitions from another source" do
      assert Registry.get(:elixir).label == "Elixir"

      override = %Language{
        name: :elixir,
        label: "Elixir Override",
        comment_token: "## ",
        extensions: ["ex", "exs"]
      }

      assert {:error,
              {:duplicate_key, {:name, :elixir}, {:extension, :minga_language_pack}, :config}} =
               Registry.register(override)

      assert Registry.get(:elixir).label == "Elixir"
    end
  end

  describe "source ownership" do
    test "bundled languages and filetype indexes are owned by the language pack extension" do
      source = {:extension, :minga_language_pack}

      assert Registry.source_for({:name, :elixir}) == source
      assert Registry.source_for({:ext, "ex"}) == source
      assert Registry.source_for({:filename, "Makefile"}) == source
      assert Registry.source_for({:shebang, "python3"}) == source
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
