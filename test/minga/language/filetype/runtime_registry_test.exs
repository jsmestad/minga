defmodule Minga.Language.Filetype.RuntimeRegistryTest do
  @moduledoc """
  The complete filetype detection precedence matrix, run against private registry tables.

  Levels, highest first: runtime filename override, language-pack filename, runtime extension override, language-pack extension, `.env*` pattern (only while `:bash` is registered), shebang (runtime override, then language-pack), and `:text`.
  """
  use ExUnit.Case, async: true

  alias Minga.Language
  alias Minga.Language.Filetype
  alias Minga.Language.Registry
  alias Minga.Test.PrivateLanguageRegistry

  @packs [
    %Language{
      name: :alpha,
      label: "Alpha",
      comment_token: "#",
      extensions: ["alp"],
      filenames: ["Alphafile"],
      shebangs: ["alphai"]
    },
    %Language{
      name: :lockfile_lang,
      label: "Lockfile",
      comment_token: "#",
      filenames: ["pack.lock"]
    },
    %Language{name: :lock_lang, label: "Lock", comment_token: "#", extensions: ["lock"]},
    %Language{
      name: :bash,
      label: "Bash",
      comment_token: "#",
      extensions: ["sh"],
      shebangs: ["bash"]
    }
  ]

  # {description, registrations, path, first_line, expected}
  # Registrations: {:override, pattern, filetype}, {:shebang, interpreter, filetype}, or :unload_bash.
  @matrix [
    # Level 1: runtime filename override
    {"filename override beats pack filename", [{:override, "pack.lock", :ovr_file}], "pack.lock",
     nil, :ovr_file},
    {"filename override beats extension override",
     [{:override, "Data.cfg", :ovr_file}, {:override, ".cfg", :ovr_ext}], "dir/Data.cfg", nil,
     :ovr_file},
    {"filename override beats pack extension", [{:override, "yarn.lock", :ovr_file}], "yarn.lock",
     nil, :ovr_file},
    {"filename override beats shebang", [{:override, "runme", :ovr_file}], "runme",
     "#!/usr/bin/env alphai", :ovr_file},

    # Level 2: language-pack filename
    {"pack filename beats extension override", [{:override, ".lock", :ovr_ext}], "pack.lock", nil,
     :lockfile_lang},
    {"pack filename beats pack extension", [], "pack.lock", nil, :lockfile_lang},
    {"pack filename beats shebang", [], "Alphafile", "#!/bin/bash", :alpha},
    {"pack filename match is case-sensitive", [], "alphafile", nil, :text},

    # Level 3: runtime extension override
    {"extension override beats pack extension", [{:override, ".lock", :ovr_ext}], "yarn.lock",
     nil, :ovr_ext},
    {"extension override matches case-insensitively", [{:override, ".lock", :ovr_ext}],
     "YARN.LOCK", nil, :ovr_ext},
    {"extension override beats the .env pattern", [{:override, ".local", :ovr_ext}], ".env.local",
     nil, :ovr_ext},
    {"extension override beats shebang", [{:override, ".xyz", :ovr_ext}], "a.xyz",
     "#!/usr/bin/env alphai", :ovr_ext},

    # Level 4: language-pack extension
    {"pack extension matches", [], "src/main.alp", nil, :alpha},
    {"pack extension matches case-insensitively", [], "MAIN.ALP", nil, :alpha},
    {"pack extension beats the .env pattern", [], ".env.lock", nil, :lock_lang},
    {"pack extension beats shebang", [], "a.alp", "#!/bin/bash", :alpha},

    # Level 5: .env* pattern
    {".env is bash while bash is registered", [], ".env", nil, :bash},
    {".envrc is bash while bash is registered", [], ".envrc", nil, :bash},
    {".env with an unknown suffix is bash", [], ".env.production", nil, :bash},
    {".env pattern beats shebang", [], ".env", "#!/usr/bin/env alphai", :bash},
    {".env is text once bash is unloaded", [:unload_bash], ".env", nil, :text},

    # Level 6: shebang
    {"shebang override beats pack shebang", [{:shebang, "alphai", :ovr_sh}], "script",
     "#!/usr/bin/env alphai", :ovr_sh},
    {"pack shebang through env", [], "script", "#!/usr/bin/env alphai", :alpha},
    {"pack shebang through an absolute path", [], "script", "#!/bin/bash", :bash},
    {"unknown shebang is text", [], "script", "#!/usr/bin/env nothing", :text},
    {"shebang overrides do not affect path-only detection", [{:shebang, "alphai", :ovr_sh}],
     "script", nil, :text},

    # Level 7: fallback
    {"no match is text", [], "README", "plain text", :text},
    {"nil path is text", [], nil, nil, :text}
  ]

  setup do
    table = PrivateLanguageRegistry.start!()
    for lang <- @packs, do: :ok = Registry.register(lang, :builtin, table)
    %{table: table}
  end

  describe "precedence matrix" do
    for {description, registrations, path, nil, expected} <- @matrix do
      test description, %{table: table} do
        apply_registrations(table, unquote(Macro.escape(registrations)))
        path = unquote(path)
        expected = unquote(expected)

        assert Filetype.detect(path, table) == expected
        assert Filetype.detect_all([path], table) == [expected]
        assert Filetype.detect_from_content(path, nil, table) == expected
      end
    end

    for {description, registrations, path, first_line, expected} <- @matrix,
        is_binary(first_line) do
      test description, %{table: table} do
        apply_registrations(table, unquote(Macro.escape(registrations)))

        assert Filetype.detect_from_content(unquote(path), unquote(first_line), table) ==
                 unquote(expected)
      end
    end
  end

  describe "override removal" do
    test "removing overrides restores pack filename, extension, and shebang fallbacks", %{
      table: table
    } do
      Registry.register_override(".alp", :ovr_ext, :runtime, table)
      Registry.register_override("Alphafile", :ovr_file, :runtime, table)
      Registry.register_shebang_override("alphai", :ovr_sh, :runtime, table)

      assert Filetype.detect("main.alp", table) == :ovr_ext
      assert Filetype.detect("Alphafile", table) == :ovr_file
      assert Filetype.detect_from_content("script", "#!/usr/bin/env alphai", table) == :ovr_sh

      Registry.register_override(".alp", nil, :runtime, table)
      Registry.register_override("Alphafile", nil, :runtime, table)
      Registry.register_shebang_override("alphai", nil, :runtime, table)

      assert Filetype.detect("main.alp", table) == :alpha
      assert Filetype.detect("Alphafile", table) == :alpha
      assert Filetype.detect_from_content("script", "#!/usr/bin/env alphai", table) == :alpha
    end

    test "unloading an override source restores pack entries", %{table: table} do
      source = {:extension, :override_pack}
      Registry.register_override(".alp", :ovr_ext, source, table)
      Registry.register_override(".lock", :ovr_lock, :runtime, table)

      Registry.unregister_source(source, table)

      assert Filetype.detect("main.alp", table) == :alpha
      assert Filetype.detect("yarn.lock", table) == :ovr_lock
    end
  end

  describe "detect_all/2" do
    test "a batch over every path-only row agrees with detect/2", %{table: table} do
      Registry.register_override(".lock", :ovr_ext, :runtime, table)
      Registry.register_override("Data.cfg", :ovr_file, :runtime, table)

      paths = ["pack.lock", "yarn.lock", "Data.cfg", "a.alp", ".env", ".env.lock", "README", nil]

      assert Filetype.detect_all(paths, table) ==
               [:lockfile_lang, :ovr_ext, :ovr_file, :alpha, :bash, :ovr_ext, :text, :text]

      assert Filetype.detect_all(paths, table) == Enum.map(paths, &Filetype.detect(&1, table))
    end

    test "reads overrides registered after an earlier call", %{table: table} do
      assert Filetype.detect_all(["notes.org"], table) == [:text]

      Registry.register_override(".org", :org, :runtime, table)

      assert Filetype.detect_all(["notes.org"], table) == [:org]
    end
  end

  describe "private table isolation" do
    test "private registrations do not change detection through the application table", %{
      table: table
    } do
      Registry.register_override(".private_matrix_ext", :ovr_ext, :runtime, table)

      assert Filetype.detect("a.private_matrix_ext", table) == :ovr_ext
      assert Filetype.detect("a.private_matrix_ext") == :text
      assert Filetype.detect("Alphafile") == :text
    end
  end

  @spec apply_registrations(Registry.table(), list()) :: :ok
  defp apply_registrations(table, registrations) do
    Enum.each(registrations, fn
      {:override, pattern, filetype} ->
        Registry.register_override(pattern, filetype, :runtime, table)

      {:shebang, interpreter, filetype} ->
        Registry.register_shebang_override(interpreter, filetype, :runtime, table)

      :unload_bash ->
        Registry.unregister_source(:builtin, table)
        for lang <- @packs, lang.name != :bash, do: :ok = Registry.register(lang, :builtin, table)
    end)
  end
end
