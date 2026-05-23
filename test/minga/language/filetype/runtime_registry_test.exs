defmodule Minga.Language.Filetype.RuntimeRegistryTest do
  @moduledoc "Tests for runtime filetype registration via Minga.Language.Filetype.Registry (global Agent)."
  use ExUnit.Case, async: false

  alias Minga.Language.Filetype

  setup do
    on_exit(fn ->
      # Runtime overrides are global, so remove test registrations after each case.
      Minga.Language.Filetype.Registry.register(".json", nil)
      Minga.Language.Filetype.Registry.register(".org", nil)
      Minga.Language.Filetype.Registry.register(".lock", nil)
      Minga.Language.Filetype.Registry.register("Justfile", nil)
      Minga.Language.Filetype.Registry.register("config.json", nil)
      Minga.Language.Filetype.Registry.register("Makefile", nil)
      Minga.Language.Filetype.Registry.register_shebang("python3", nil)
    end)

    :ok
  end

  describe "detect/1 — runtime registry integration" do
    test "detects filetypes registered at runtime via extension" do
      Minga.Language.Filetype.Registry.register(".org", :org)
      assert Filetype.detect("notes.org") == :org
    end

    test "detects filetypes registered at runtime via filename" do
      Minga.Language.Filetype.Registry.register("Justfile", :just)
      assert Filetype.detect("Justfile") == :just
    end

    test "bundled exact filename beats runtime extension overrides" do
      Minga.Language.Filetype.Registry.register(".lock", :lock_custom)

      assert Filetype.detect("mix.lock") == :elixir
    end

    test "runtime registry takes precedence over bundled language pack defaults" do
      assert Filetype.detect("data.json") == :json

      Minga.Language.Filetype.Registry.register(".json", :json_custom)
      assert Filetype.detect("data.json") == :json_custom
    end

    test "removing runtime overrides restores bundled filename, extension, and shebang fallbacks" do
      Minga.Language.Filetype.Registry.register(".json", :json_custom)
      Minga.Language.Filetype.Registry.register("Makefile", :make_custom)
      Minga.Language.Filetype.Registry.register_shebang("python3", :python_custom)

      assert Filetype.detect("data.json") == :json_custom
      assert Filetype.detect("Makefile") == :make_custom
      assert Filetype.detect_from_content("script", "#!/usr/bin/env python3") == :python_custom

      Minga.Language.Filetype.Registry.register(".json", nil)
      Minga.Language.Filetype.Registry.register("Makefile", nil)
      Minga.Language.Filetype.Registry.register_shebang("python3", nil)

      assert Filetype.detect("data.json") == :json
      assert Filetype.detect("Makefile") == :make
      assert Filetype.detect_from_content("script", "#!/usr/bin/env python3") == :python
    end
  end
end
