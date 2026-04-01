defmodule Minga.Language.TreeSitterTest do
  use ExUnit.Case, async: false

  alias Minga.Language.TreeSitter
  alias Minga.Language.Grammar, as: HLGrammar

  @moduletag :tmp_dir

  describe "find_compiler/0" do
    test "finds a C compiler on the system" do
      # CI and dev machines should have cc or clang
      assert {:ok, path} = TreeSitter.find_compiler()
      assert is_binary(path)
      assert String.length(path) > 0
    end
  end

  describe "include_path/0" do
    test "returns a path containing tree_sitter/api.h" do
      path = TreeSitter.include_path()
      assert File.exists?(Path.join(path, "tree_sitter/api.h"))
    end
  end

  describe "grammar_lib_path/1" do
    test "returns platform-appropriate path" do
      path = TreeSitter.grammar_lib_path("test_lang")
      assert String.contains?(path, "minga/grammars/test_lang")

      case :os.type() do
        {:unix, :darwin} -> assert String.ends_with?(path, ".dylib")
        {:unix, _} -> assert String.ends_with?(path, ".so")
      end
    end
  end

  describe "compile_grammar/2" do
    test "compiles a grammar from parser.c using the JSON grammar fixture", %{tmp_dir: tmp_dir} do
      source_dir = copy_json_grammar(tmp_dir)

      assert {:ok, lib_path} = TreeSitter.compile_grammar("test_json_copy", source_dir)
      assert File.exists?(lib_path)
      assert String.ends_with?(lib_path, ".#{shared_lib_ext()}")
    after
      File.rm(TreeSitter.grammar_lib_path("test_json_copy"))
    end

    test "uses cached library on second compile", %{tmp_dir: tmp_dir} do
      source_dir = copy_json_grammar(tmp_dir)

      assert {:ok, lib_path} = TreeSitter.compile_grammar("test_cache", source_dir)

      # Record the library's mtime, then backdate source files so the cache
      # looks newer than the sources (avoids Process.sleep for mtime gap).
      {:ok, lib_stat} = File.stat(lib_path, time: :posix)

      for src <- Path.wildcard(Path.join(source_dir, "*.c")) do
        File.touch!(src, lib_stat.mtime - 2)
      end

      first_mtime = lib_stat.mtime

      assert {:ok, ^lib_path} = TreeSitter.compile_grammar("test_cache", source_dir)
      {:ok, second_stat} = File.stat(lib_path, time: :posix)

      assert first_mtime == second_stat.mtime
    after
      File.rm(TreeSitter.grammar_lib_path("test_cache"))
    end

    test "returns error for missing parser.c", %{tmp_dir: tmp_dir} do
      source_dir = Path.join(tmp_dir, "empty")
      File.mkdir_p!(source_dir)

      assert {:error, msg} = TreeSitter.compile_grammar("missing", source_dir)
      assert msg =~ "parser.c not found"
    end

    test "returns error when no C compiler is available", %{tmp_dir: tmp_dir} do
      source_dir = copy_json_grammar(tmp_dir)

      assert {:error, "no C compiler found"} =
               TreeSitter.compile_grammar("no_compiler_test", source_dir,
                 compiler: {:error, "no C compiler found"}
               )
    end
  end

  describe "register_grammar/3" do
    setup do
      # Ensure the ETS table exists for tests
      HLGrammar.init_registry()
      :ok
    end

    test "registers a filetype-to-language mapping" do
      HLGrammar.register_language(:test_lang, "test_lang")
      assert {:ok, "test_lang"} = HLGrammar.language_for_filetype(:test_lang)
    end

    test "dynamic registration takes precedence over static" do
      # :elixir is in the static map as "elixir"
      assert {:ok, "elixir"} = HLGrammar.language_for_filetype(:elixir)

      # Override it dynamically
      HLGrammar.register_language(:elixir, "elixir_custom")
      assert {:ok, "elixir_custom"} = HLGrammar.language_for_filetype(:elixir)

      # Clean up: restore original
      :ets.delete(:minga_grammar_registry, :elixir)
      assert {:ok, "elixir"} = HLGrammar.language_for_filetype(:elixir)
    end

    test "unsupported filetype still returns :unsupported" do
      assert :unsupported = HLGrammar.language_for_filetype(:nonexistent_lang_xyz)
    end
  end

  describe "resolve_query_inherits/2" do
    test "returns query unchanged when no inherits directive" do
      query = "(identifier) @variable\n(string) @string\n"
      assert TreeSitter.resolve_query_inherits(query, :highlights) == query
    end

    test "resolves single parent inheritance" do
      # TypeScript inherits from ecma. The ecma highlights should be prepended.
      query = "; inherits: ecma\n(type_identifier) @type\n"
      resolved = TreeSitter.resolve_query_inherits(query, :highlights)

      # Should contain ecma content
      assert String.contains?(resolved, "arrow_function")
      # Should contain the child's own content
      assert String.contains?(resolved, "type_identifier")
      # Should NOT contain the inherits directive
      refute String.starts_with?(resolved, "; inherits:")
    end

    test "resolves multiple parents" do
      query = "; inherits: ecma,jsx\n; child content\n(my_node) @custom\n"
      resolved = TreeSitter.resolve_query_inherits(query, :highlights)

      # ecma content
      assert String.contains?(resolved, "arrow_function")
      # jsx content
      assert String.contains?(resolved, "jsx_element")
      # Own content
      assert String.contains?(resolved, "my_node")
    end

    test "handles missing parent gracefully" do
      query = "; inherits: nonexistent_language\n(foo) @bar\n"
      resolved = TreeSitter.resolve_query_inherits(query, :highlights)

      # Should still contain the child content
      assert String.contains?(resolved, "(foo) @bar")
    end

    test "handles missing query type for parent" do
      # bash has highlights but no folds
      query = "; inherits: bash\n(foo) @fold\n"
      resolved = TreeSitter.resolve_query_inherits(query, :folds)

      assert String.contains?(resolved, "(foo) @fold")
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @spec shared_lib_ext() :: String.t()
  defp shared_lib_ext do
    case :os.type() do
      {:unix, :darwin} -> "dylib"
      {:unix, _} -> "so"
    end
  end

  @spec copy_json_grammar(String.t()) :: String.t()
  defp copy_json_grammar(tmp_dir) do
    # Copy the vendored JSON grammar's src/ directory as a test fixture.
    # It's small, has no scanner, and is known to compile.
    json_src = Path.join([File.cwd!(), "zig", "vendor", "grammars", "json", "src"])
    dest = Path.join(tmp_dir, "src")
    File.cp_r!(json_src, dest)
    dest
  end
end
