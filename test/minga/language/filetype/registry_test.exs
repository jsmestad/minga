defmodule Minga.Language.Filetype.RegistryTest do
  @moduledoc "Tests for the Language.Registry runtime override API on a private registry table."
  use ExUnit.Case, async: true

  alias Minga.Language
  alias Minga.Language.Registry
  alias Minga.Test.PrivateLanguageRegistry

  setup do
    %{table: PrivateLanguageRegistry.start!()}
  end

  describe "private registry tables" do
    test "entries in a private table are invisible through the application table", %{table: t} do
      Registry.register_override(".private_only_ext", :custom_lang, :runtime, t)

      assert Registry.lookup_override_extension("private_only_ext", t) == :custom_lang
      assert Registry.lookup_override_extension("private_only_ext") == nil
    end

    test "a private table starts without bundled languages", %{table: t} do
      assert Registry.all(t) == []
      assert Registry.for_extension("ex", t) == nil
      assert %Language{name: :elixir} = Registry.for_extension("ex")
    end
  end

  describe "register_override/4 for extensions" do
    test "registers a new extension override", %{table: t} do
      assert Registry.lookup_override_extension("test_ext_a", t) == nil
      Registry.register_override(".test_ext_a", :custom_lang, :runtime, t)
      assert Registry.lookup_override_extension("test_ext_a", t) == :custom_lang
    end

    test "stores extensions case-insensitively", %{table: t} do
      Registry.register_override(".Test_Ext_A", :custom_lang, :runtime, t)
      assert Registry.lookup_override_extension("test_ext_a", t) == :custom_lang
    end

    test "replaces an existing extension override", %{table: t} do
      Registry.register_override(".test_ext_a", :lang_one, :runtime, t)
      Registry.register_override(".test_ext_a", :lang_two, :runtime, t)
      assert Registry.lookup_override_extension("test_ext_a", t) == :lang_two
    end

    test "nil removes an extension override", %{table: t} do
      Registry.register_override(".test_ext_a", :custom_lang, :runtime, t)
      Registry.register_override(".test_ext_a", nil, :runtime, t)
      assert Registry.lookup_override_extension("test_ext_a", t) == nil
    end
  end

  describe "register_override/4 for filenames" do
    test "registers a new filename override", %{table: t} do
      assert Registry.lookup_override_filename("TestFile", t) == nil
      Registry.register_override("TestFile", :custom_lang, :runtime, t)
      assert Registry.lookup_override_filename("TestFile", t) == :custom_lang
    end

    test "filename overrides are case-sensitive", %{table: t} do
      Registry.register_override("TestFile", :custom_lang, :runtime, t)
      assert Registry.lookup_override_filename("testfile", t) == nil
    end

    test "nil removes a filename override", %{table: t} do
      Registry.register_override("TestFile", :custom_lang, :runtime, t)
      Registry.register_override("TestFile", nil, :runtime, t)
      assert Registry.lookup_override_filename("TestFile", t) == nil
    end
  end

  describe "register_shebang_override/4" do
    test "registers a new shebang interpreter override", %{table: t} do
      assert Registry.lookup_override_shebang("test_interp", t) == nil
      Registry.register_shebang_override("test_interp", :custom_lang, :runtime, t)
      assert Registry.lookup_override_shebang("test_interp", t) == :custom_lang
    end

    test "nil removes a shebang override", %{table: t} do
      Registry.register_shebang_override("test_interp", :custom_lang, :runtime, t)
      Registry.register_shebang_override("test_interp", nil, :runtime, t)
      assert Registry.lookup_override_shebang("test_interp", t) == nil
    end
  end

  describe "override_path_entries/1" do
    test "returns all extension and filename overrides in one read", %{table: t} do
      Registry.register_override(".test_ext_a", :lang_a, :runtime, t)
      Registry.register_override(".test_ext_b", :lang_b, :runtime, t)
      Registry.register_override("TestFile", :lang_c, :runtime, t)
      Registry.register_shebang_override("test_interp", :lang_d, :runtime, t)

      assert Registry.override_path_entries(t) == %{
               extensions: %{"test_ext_a" => :lang_a, "test_ext_b" => :lang_b},
               filenames: %{"TestFile" => :lang_c}
             }
    end
  end

  describe "source ownership" do
    test "overrides are tagged with their source", %{table: t} do
      source = {:extension, :test_override_source}
      Registry.register_override(".test_ext_a", :custom_lang, source, t)
      assert Registry.source_for({:override_ext, "test_ext_a"}, t) == source
    end

    test "unregister_source removes every override from that source", %{table: t} do
      source = {:extension, :test_override_unregister}

      Registry.register_override(".test_ext_a", :custom_lang, source, t)
      Registry.register_override("TestFile", :custom_lang, source, t)
      Registry.register_shebang_override("test_interp", :custom_lang, source, t)

      Registry.unregister_source(source, t)

      assert Registry.lookup_override_extension("test_ext_a", t) == nil
      assert Registry.lookup_override_filename("TestFile", t) == nil
      assert Registry.lookup_override_shebang("test_interp", t) == nil
    end

    test "unregister_source leaves overrides from other sources", %{table: t} do
      Registry.register_override(".test_ext_a", :lang_a, {:extension, :a}, t)
      Registry.register_override(".test_ext_b", :lang_b, {:extension, :b}, t)

      Registry.unregister_source({:extension, :a}, t)

      assert Registry.lookup_override_extension("test_ext_a", t) == nil
      assert Registry.lookup_override_extension("test_ext_b", t) == :lang_b
    end

    test "language-pack unload leaves runtime overrides and other packs", %{table: t} do
      pack = %Language{name: :pack_lang, label: "Pack", comment_token: "#", extensions: ["pk"]}
      other = %Language{name: :other_lang, label: "Other", comment_token: "#", extensions: ["ot"]}

      :ok = Registry.register(pack, {:extension, :pack}, t)
      :ok = Registry.register(other, {:extension, :other}, t)
      Registry.register_override(".test_ext_a", :custom_lang, :runtime, t)

      Registry.unregister_source({:extension, :pack}, t)

      assert Registry.get(:pack_lang, t) == nil
      assert Registry.for_extension("pk", t) == nil
      assert %Language{name: :other_lang} = Registry.for_extension("ot", t)
      assert Registry.lookup_override_extension("test_ext_a", t) == :custom_lang
    end
  end
end
