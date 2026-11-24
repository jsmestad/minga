defmodule Minga.Language.Filetype.RegistryTest do
  @moduledoc "Tests for Language.Registry runtime override API — extension, filename, and shebang overrides."
  # Mutates global Language.Registry ETS for override entries.
  use ExUnit.Case, async: false

  alias Minga.Language.Registry

  setup do
    on_exit(fn ->
      Registry.register_override(".test_ext_a", nil)
      Registry.register_override(".test_ext_b", nil)
      Registry.register_override("TestFile", nil)
      Registry.register_override("TestFile2", nil)
      Registry.register_shebang_override("test_interp", nil)
    end)

    :ok
  end

  describe "register_override/2 — extensions" do
    test "registers a new extension override" do
      assert Registry.lookup_override_extension("test_ext_a") == nil
      Registry.register_override(".test_ext_a", :custom_lang)
      assert Registry.lookup_override_extension("test_ext_a") == :custom_lang
    end

    test "is case-insensitive for extension storage" do
      Registry.register_override(".Test_Ext_A", :custom_lang)
      assert Registry.lookup_override_extension("test_ext_a") == :custom_lang
    end

    test "updates an existing extension override" do
      Registry.register_override(".test_ext_a", :lang_one)
      assert Registry.lookup_override_extension("test_ext_a") == :lang_one

      Registry.register_override(".test_ext_a", :lang_two)
      assert Registry.lookup_override_extension("test_ext_a") == :lang_two
    end

    test "removes an extension override with nil" do
      Registry.register_override(".test_ext_a", :custom_lang)
      assert Registry.lookup_override_extension("test_ext_a") == :custom_lang

      Registry.register_override(".test_ext_a", nil)
      assert Registry.lookup_override_extension("test_ext_a") == nil
    end
  end

  describe "register_override/2 — filenames" do
    test "registers a new filename override" do
      assert Registry.lookup_override_filename("TestFile") == nil
      Registry.register_override("TestFile", :custom_lang)
      assert Registry.lookup_override_filename("TestFile") == :custom_lang
    end

    test "removes a filename override with nil" do
      Registry.register_override("TestFile", :custom_lang)
      Registry.register_override("TestFile", nil)
      assert Registry.lookup_override_filename("TestFile") == nil
    end
  end

  describe "register_shebang_override/2" do
    test "registers a new shebang interpreter override" do
      assert Registry.lookup_override_shebang("test_interp") == nil
      Registry.register_shebang_override("test_interp", :custom_lang)
      assert Registry.lookup_override_shebang("test_interp") == :custom_lang
    end

    test "removes a shebang override with nil" do
      Registry.register_shebang_override("test_interp", :custom_lang)
      Registry.register_shebang_override("test_interp", nil)
      assert Registry.lookup_override_shebang("test_interp") == nil
    end
  end

  describe "override_path_entries/0" do
    test "returns all extension and filename overrides in one read" do
      Registry.register_override(".test_ext_a", :lang_a)
      Registry.register_override(".test_ext_b", :lang_b)
      Registry.register_override("TestFile", :lang_c)

      entries = Registry.override_path_entries()
      assert entries.extensions["test_ext_a"] == :lang_a
      assert entries.extensions["test_ext_b"] == :lang_b
      assert entries.filenames["TestFile"] == :lang_c
    end
  end

  describe "source-tagged overrides" do
    test "overrides are tagged with the given source" do
      source = {:extension, :test_override_source}
      Registry.register_override(".test_ext_a", :custom_lang, source)
      assert Registry.source_for({:override_ext, "test_ext_a"}) == source
    end

    test "unregister_source removes overrides from that source" do
      source = {:extension, :test_override_unregister}

      Registry.register_override(".test_ext_a", :custom_lang, source)
      Registry.register_override("TestFile", :custom_lang, source)
      Registry.register_shebang_override("test_interp", :custom_lang, source)

      assert Registry.lookup_override_extension("test_ext_a") == :custom_lang

      Registry.unregister_source(source)

      assert Registry.lookup_override_extension("test_ext_a") == nil
      assert Registry.lookup_override_filename("TestFile") == nil
      assert Registry.lookup_override_shebang("test_interp") == nil
    end

    test "unregister_source does not disturb overrides from other sources" do
      source_a = {:extension, :test_override_a}
      source_b = {:extension, :test_override_b}

      Registry.register_override(".test_ext_a", :lang_a, source_a)
      Registry.register_override(".test_ext_b", :lang_b, source_b)

      Registry.unregister_source(source_a)

      assert Registry.lookup_override_extension("test_ext_a") == nil
      assert Registry.lookup_override_extension("test_ext_b") == :lang_b

      # Cleanup
      Registry.unregister_source(source_b)
    end

    test "language-pack unload does not disturb runtime overrides" do
      Registry.register_override(".test_ext_a", :custom_lang, :runtime)

      # Simulate a language-pack unload: unregister_source for a pack
      # should leave :runtime overrides alone.
      Registry.unregister_source({:extension, :nonexistent_pack})

      assert Registry.lookup_override_extension("test_ext_a") == :custom_lang
    end
  end
end
