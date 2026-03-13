defmodule Minga.TreeSitterTest do
  use ExUnit.Case, async: false

  alias Minga.Highlight.Grammar, as: HLGrammar
  alias Minga.TreeSitter

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
        {:win32, _} -> assert String.ends_with?(path, ".dll")
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
      first_mtime = File.stat!(lib_path).mtime

      # Small delay to ensure mtime would differ if recompiled
      Process.sleep(1100)

      assert {:ok, ^lib_path} = TreeSitter.compile_grammar("test_cache", source_dir)
      second_mtime = File.stat!(lib_path).mtime

      assert first_mtime == second_mtime
    after
      File.rm(TreeSitter.grammar_lib_path("test_cache"))
    end

    test "returns error for missing parser.c", %{tmp_dir: tmp_dir} do
      source_dir = Path.join(tmp_dir, "empty")
      File.mkdir_p!(source_dir)

      assert {:error, msg} = TreeSitter.compile_grammar("missing", source_dir)
      assert msg =~ "parser.c not found"
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

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @spec shared_lib_ext() :: String.t()
  defp shared_lib_ext do
    case :os.type() do
      {:unix, :darwin} -> "dylib"
      {:unix, _} -> "so"
      {:win32, _} -> "dll"
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
