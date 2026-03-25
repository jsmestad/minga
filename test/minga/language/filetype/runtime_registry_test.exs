defmodule Minga.Language.Filetype.RuntimeRegistryTest do
  @moduledoc "Tests for runtime filetype registration via Minga.Language.Filetype.Registry (global Agent)."
  use ExUnit.Case, async: false

  alias Minga.Language.Filetype

  setup do
    on_exit(fn ->
      # Restore .json to its compile-time default in case a test overrode it.
      # .org and Justfile are test-only registrations that don't exist in the
      # compile-time map, so re-registering them to nil cleans them up.
      Minga.Language.Filetype.Registry.register(".json", :json)
      Minga.Language.Filetype.Registry.register(".org", nil)
      Minga.Language.Filetype.Registry.register("Justfile", nil)
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

    test "runtime registry takes precedence over compile-time map" do
      # .json is normally :json in the compile-time map
      assert Filetype.detect("data.json") == :json

      # Override it at runtime
      Minga.Language.Filetype.Registry.register(".json", :json_custom)
      assert Filetype.detect("data.json") == :json_custom
    end
  end
end
