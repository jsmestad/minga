defmodule Minga.Language.Filetype.RuntimeRegistryTest do
  @moduledoc "Tests for runtime filetype overrides via Minga.Language.Registry."
  use ExUnit.Case, async: false

  alias Minga.Language.Filetype
  alias Minga.Language.Registry

  setup do
    on_exit(fn ->
      # Runtime overrides are global, so remove test registrations after each case.
      Registry.register_override(".json", nil)
      Registry.register_override(".org", nil)
      Registry.register_override(".lock", nil)
      Registry.register_override("Justfile", nil)
      Registry.register_override("config.json", nil)
      Registry.register_override("Makefile", nil)
      Registry.register_shebang_override("python3", nil)
    end)

    :ok
  end

  describe "detect/1 — runtime registry integration" do
    test "detects filetypes registered at runtime via extension" do
      Registry.register_override(".org", :org)
      assert Filetype.detect("notes.org") == :org
    end

    test "detects filetypes registered at runtime via filename" do
      Registry.register_override("Justfile", :just)
      assert Filetype.detect("Justfile") == :just
    end

    test "bundled exact filename beats runtime extension overrides" do
      Registry.register_override(".lock", :lock_custom)

      assert Filetype.detect("mix.lock") == :elixir
    end

    test "runtime registry takes precedence over bundled language pack defaults" do
      assert Filetype.detect("data.json") == :json

      Registry.register_override(".json", :json_custom)
      assert Filetype.detect("data.json") == :json_custom
    end

    test "removing runtime overrides restores bundled filename, extension, and shebang fallbacks" do
      Registry.register_override(".json", :json_custom)
      Registry.register_override("Makefile", :make_custom)
      Registry.register_shebang_override("python3", :python_custom)

      assert Filetype.detect("data.json") == :json_custom
      assert Filetype.detect("Makefile") == :make_custom
      assert Filetype.detect_from_content("script", "#!/usr/bin/env python3") == :python_custom

      Registry.register_override(".json", nil)
      Registry.register_override("Makefile", nil)
      Registry.register_shebang_override("python3", nil)

      assert Filetype.detect("data.json") == :json
      assert Filetype.detect("Makefile") == :make
      assert Filetype.detect_from_content("script", "#!/usr/bin/env python3") == :python
    end
  end

  describe "detect_all/1 — runtime registry integration" do
    test "applies runtime filename and extension overrides with detect/1 priority" do
      Registry.register_override(".org", :org)
      Registry.register_override("Justfile", :just)
      Registry.register_override(".lock", :lock_custom)
      Registry.register_override(".json", :json_custom)

      paths = ["notes.org", "/repo/Justfile", "mix.lock", "yarn.lock", "data.json", "a.ex"]

      assert Filetype.detect_all(paths) ==
               [:org, :just, :elixir, :lock_custom, :json_custom, :elixir]

      assert Filetype.detect_all(paths) == Enum.map(paths, &Filetype.detect/1)
    end

    test "reads overrides registered after an earlier call" do
      assert Filetype.detect_all(["notes.org"]) == [:text]

      Registry.register_override(".org", :org)

      assert Filetype.detect_all(["notes.org"]) == [:org]
    end
  end
end
