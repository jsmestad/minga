defmodule Minga.Extensions.LanguagePacksTest do
  @moduledoc "Tests for bundled language pack lifecycle registration."
  # Mutates the global language registry to verify source-owned unload and reload behavior.
  use ExUnit.Case, async: false

  alias Minga.Extensions.LanguagePacks
  alias Minga.Extensions.LanguagePacks.Bundled
  alias Minga.Language
  alias Minga.Language.Devicon
  alias Minga.Language.Registry

  setup do
    on_exit(fn ->
      Minga.Language.Filetype.Registry.register("config.json", nil)
      Registry.unregister_source({:extension, :language_pack_cleanup_existing})
      LanguagePacks.reload_pack(Bundled)
    end)

    :ok
  end

  test "bundled pack owns the default language catalog" do
    source = LanguagePacks.source_for(Bundled)

    assert source == {:extension, :minga_language_pack}
    assert %Language{name: :elixir} = Registry.get(:elixir)
    assert Registry.source_for({:name, :elixir}) == source
    assert Registry.source_for({:ext, "ex"}) == source
    assert Registry.source_for({:filename, "Makefile"}) == source
    assert Registry.source_for({:shebang, "python3"}) == source
  end

  test "unregistering the bundled pack removes language, filetype, shebang, and devicon data" do
    assert :ok = LanguagePacks.unregister_pack(Bundled)

    assert Registry.get(:elixir) == nil
    assert Registry.for_extension("ex") == nil
    assert Registry.for_filename("Makefile") == nil
    assert Registry.for_shebang("python3") == nil
    assert Language.detect_filetype("lib/example.ex") == :text
    assert Language.detect_filetype(".env") == :text
    assert Language.detect_filetype(".envrc") == :text
    assert Language.detect_filetype_from_content("script", "#!/usr/bin/env python3") == :text
    assert Devicon.icon_and_color(:elixir) == {"\u{E612}", 0x6D8086}
  end

  test "duplicate extension inside one pack is rejected before mutating the registry" do
    pack = Minga.Test.Fixtures.LanguagePacks.DuplicateExtensionPack

    assert {:error,
            {:duplicate_pack_key, {:ext, "language_pack_duplicate_extension"},
             Minga.Test.Fixtures.LanguagePacks.DuplicateExtensionPack.FirstLanguage,
             Minga.Test.Fixtures.LanguagePacks.DuplicateExtensionPack.DuplicateLanguage}} =
             LanguagePacks.register_pack(pack)

    assert Registry.get(:language_pack_duplicate_extension_ok) == nil
    assert Registry.for_extension("language_pack_duplicate_extension") == nil
    assert %Language{name: :elixir} = Registry.get(:elixir)
    assert Registry.for_extension("ex").name == :elixir
  end

  test "cleanup_failed_register/2 removes partial inserts and preserves external collision source" do
    source = {:extension, :language_pack_cleanup_existing}

    existing = %Language{
      name: :language_pack_cleanup_existing,
      label: "Language Pack Cleanup Existing",
      comment_token: "# ",
      extensions: ["language_pack_cleanup_collision"]
    }

    assert :ok = Registry.register(existing, source)

    assert {:error,
            {:duplicate_key, {:ext, "language_pack_cleanup_collision"}, ^source,
             {:extension, :language_pack_cleanup_failure_test}}} =
             LanguagePacks.register_pack(Minga.Test.Fixtures.LanguagePacks.CleanupFailurePack)

    assert Registry.get(:language_pack_cleanup_ok) == nil
    assert Registry.for_extension("language_pack_cleanup_ok") == nil

    assert %Language{name: :language_pack_cleanup_existing} =
             Registry.get(:language_pack_cleanup_existing)

    assert Registry.source_for({:ext, "language_pack_cleanup_collision"}) == source
  end

  test "runtime filename override takes precedence over bundled extension lookup" do
    Minga.Language.Filetype.Registry.register("config.json", :json_custom)

    assert Language.detect_filetype("config.json") == :json_custom
    assert Language.detect_filetype("data.json") == :json
  end

  test "reloading the bundled pack removes stale entries from the same source before re-registering" do
    source = LanguagePacks.source_for(Bundled)

    stale = %Language{
      name: :stale_pack_language,
      label: "Stale Pack Language",
      comment_token: "// ",
      extensions: ["stale_pack_ext"],
      filenames: ["Stalefile"],
      shebangs: ["stale-pack"]
    }

    assert :ok = Registry.register(stale, source)
    assert %Language{name: :stale_pack_language} = Registry.for_extension("stale_pack_ext")

    assert :ok = LanguagePacks.reload_pack(Bundled)

    assert Registry.get(:stale_pack_language) == nil
    assert Registry.for_extension("stale_pack_ext") == nil
    assert Registry.for_filename("Stalefile") == nil
    assert Registry.for_shebang("stale-pack") == nil
    assert %Language{name: :elixir} = Registry.for_extension("ex")
  end

  test "disabled bundled packs remove any previously loaded entries and leave safe text fallbacks" do
    assert %Language{name: :elixir} = Registry.get(:elixir)

    name = :language_packs_disabled_test
    start_supervised!({LanguagePacks, name: name, disabled: [:minga_language_pack]})

    assert Registry.get(:elixir) == nil
    assert Registry.for_extension("ex") == nil
    assert Language.detect_filetype("lib/example.ex") == :text
    assert Language.detect_filetype(".env") == :text
    assert Devicon.icon_and_color(:elixir) == {"\u{E612}", 0x6D8086}
  end
end
