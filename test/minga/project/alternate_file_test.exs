defmodule Minga.Project.AlternateFileTest do
  use ExUnit.Case, async: true

  alias Minga.Project.AlternateFile

  @project "/project"

  # Returns candidates as relative paths for cleaner assertions
  defp candidates(rel_path, filetype) do
    abs = Path.join(@project, rel_path)

    AlternateFile.candidates(abs, filetype, @project)
    |> Enum.map(fn p -> Path.relative_to(p, @project) end)
  end

  # Creates a temp directory with files and finds the first existing candidate
  defp first_existing(rel_path, filetype, existing_files) do
    tmp = Path.join(System.tmp_dir!(), "minga_alt_test_#{System.unique_integer([:positive])}")

    try do
      for file <- existing_files do
        full = Path.join(tmp, file)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, "")
      end

      abs = Path.join(tmp, rel_path)

      AlternateFile.candidates(abs, filetype, tmp)
      |> Enum.find(&File.exists?/1)
      |> case do
        nil -> :none
        found -> Path.relative_to(found, tmp)
      end
    after
      File.rm_rf!(tmp)
    end
  end

  # ── Elixir ───────────────────────────────────────────────────────────────

  describe "Elixir" do
    test "lib → test" do
      assert candidates("lib/minga/buffer.ex", :elixir) == ["test/minga/buffer_test.exs"]
    end

    test "test → lib" do
      assert candidates("test/minga/buffer_test.exs", :elixir) == ["lib/minga/buffer.ex"]
    end

    test "nested lib → test" do
      assert candidates("lib/minga/editor/commands.ex", :elixir) == [
               "test/minga/editor/commands_test.exs"
             ]
    end

    test "nested test → lib" do
      assert candidates("test/minga/editor/commands_test.exs", :elixir) == [
               "lib/minga/editor/commands.ex"
             ]
    end

    test "non-test file in test/ returns empty" do
      assert candidates("test/support/helpers.exs", :elixir) == []
    end

    test "file outside lib/ and test/ returns empty" do
      assert candidates("config/config.exs", :elixir) == []
    end
  end

  # ── Ruby ─────────────────────────────────────────────────────────────────

  describe "Ruby" do
    test "app → spec" do
      assert candidates("app/models/user.rb", :ruby) == ["spec/models/user_spec.rb"]
    end

    test "spec → app or lib" do
      result = candidates("spec/models/user_spec.rb", :ruby)
      assert result == ["app/models/user.rb", "lib/models/user.rb"]
    end

    test "lib → spec returns both candidates" do
      result = candidates("lib/foo/bar.rb", :ruby)
      assert result == ["spec/lib/foo/bar_spec.rb", "spec/foo/bar_spec.rb"]
    end

    test "lib → spec (prefers spec/lib/ when it exists)" do
      assert first_existing("lib/foo/bar.rb", :ruby, ["spec/lib/foo/bar_spec.rb"]) ==
               "spec/lib/foo/bar_spec.rb"
    end

    test "lib → spec (falls back to spec/ when spec/lib/ doesn't exist)" do
      assert first_existing("lib/foo/bar.rb", :ruby, ["spec/foo/bar_spec.rb"]) ==
               "spec/foo/bar_spec.rb"
    end

    test "spec/lib/ → lib" do
      assert candidates("spec/lib/foo/bar_spec.rb", :ruby) == ["lib/foo/bar.rb"]
    end

    test "spec/ → lib (when not under spec/lib/)" do
      result = candidates("spec/foo/bar_spec.rb", :ruby)
      assert result == ["app/foo/bar.rb", "lib/foo/bar.rb"]
    end

    test "non-spec file returns empty" do
      assert candidates("spec/spec_helper.rb", :ruby) == []
    end
  end

  # ── TypeScript ───────────────────────────────────────────────────────────

  describe "TypeScript" do
    test "source → test candidates include .test and .spec" do
      result = candidates("src/utils/format.ts", :typescript)
      assert "src/utils/format.test.ts" in result
      assert "src/utils/format.spec.ts" in result
    end

    test "source → test (prefers .test.ts when it exists)" do
      assert first_existing("src/utils/format.ts", :typescript, ["src/utils/format.test.ts"]) ==
               "src/utils/format.test.ts"
    end

    test "source → spec (prefers .spec.ts when it exists)" do
      assert first_existing("src/utils/format.ts", :typescript, ["src/utils/format.spec.ts"]) ==
               "src/utils/format.spec.ts"
    end

    test ".test.ts → source" do
      assert candidates("src/utils/format.test.ts", :typescript) == ["src/utils/format.ts"]
    end

    test ".spec.ts → source" do
      assert candidates("src/utils/format.spec.ts", :typescript) == ["src/utils/format.ts"]
    end

    test "TSX source → test" do
      result = candidates("src/App.tsx", :typescript_react)
      assert hd(result) == "src/App.test.tsx"
    end

    test "TSX test → source" do
      assert candidates("src/App.test.tsx", :typescript_react) == ["src/App.tsx"]
    end

    test "JavaScript works the same way" do
      result = candidates("src/index.js", :javascript)
      assert hd(result) == "src/index.test.js"
      assert candidates("src/index.test.js", :javascript) == ["src/index.js"]
    end

    test "JSX works the same way" do
      result = candidates("src/App.jsx", :javascript_react)
      assert hd(result) == "src/App.test.jsx"
    end

    test "__tests__/ → src/" do
      assert candidates("__tests__/utils/format.test.ts", :typescript) == ["src/utils/format.ts"]
    end

    test "src/ source includes __tests__ candidate" do
      result = candidates("src/utils/format.ts", :typescript)
      assert "__tests__/utils/format.test.ts" in result
    end
  end

  # ── C ────────────────────────────────────────────────────────────────────

  describe "C" do
    test ".c → .h" do
      assert candidates("src/buffer.c", :c) == ["src/buffer.h"]
    end

    test ".h → .c" do
      assert candidates("src/buffer.h", :c) == ["src/buffer.c"]
    end

    test "non-C extension returns empty" do
      assert candidates("src/readme.txt", :c) == []
    end
  end

  # ── C++ ──────────────────────────────────────────────────────────────────

  describe "C++" do
    test ".cpp → .hpp and .h candidates" do
      result = candidates("src/engine.cpp", :cpp)
      assert result == ["src/engine.hpp", "src/engine.h"]
    end

    test ".cpp → .hpp (prefers .hpp when it exists)" do
      assert first_existing("src/engine.cpp", :cpp, ["src/engine.hpp"]) == "src/engine.hpp"
    end

    test ".cpp → .h (falls back to .h)" do
      assert first_existing("src/engine.cpp", :cpp, ["src/engine.h"]) == "src/engine.h"
    end

    test ".hpp → .cpp candidates" do
      result = candidates("src/engine.hpp", :cpp)
      assert "src/engine.cpp" in result
    end

    test ".h → .cpp candidates" do
      result = candidates("include/engine.h", :cpp)
      assert "include/engine.cpp" in result
    end

    test ".cc extension works" do
      result = candidates("src/engine.cc", :cpp)
      assert "src/engine.hpp" in result
    end

    test ".cxx extension works" do
      result = candidates("src/engine.cxx", :cpp)
      assert "src/engine.hpp" in result
    end
  end

  # ── Swift ────────────────────────────────────────────────────────────────

  describe "Swift" do
    test "Sources → Tests" do
      assert candidates("Sources/Minga/Buffer.swift", :swift) == ["Tests/Minga/BufferTests.swift"]
    end

    test "Tests → Sources" do
      assert candidates("Tests/Minga/BufferTests.swift", :swift) == ["Sources/Minga/Buffer.swift"]
    end

    test "non-Tests suffix returns empty" do
      assert candidates("Tests/Helpers/TestHelper.swift", :swift) == []
    end
  end

  # ── Unsupported ──────────────────────────────────────────────────────────

  describe "unsupported filetypes" do
    test "markdown returns empty" do
      assert candidates("docs/README.md", :markdown) == []
    end

    test "text returns empty" do
      assert candidates("notes.txt", :text) == []
    end

    test "yaml returns empty" do
      assert candidates("config.yml", :yaml) == []
    end
  end
end
