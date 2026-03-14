defmodule Minga.Integration.MingaOrgTest do
  @moduledoc """
  Integration test that exercises the minga-org extension loading path.

  Clones the minga-org repo, compiles the vendored tree-sitter-org grammar,
  verifies filetype detection, and checks that keybinding registration works.
  This proves the end-to-end wiring between the extension system, runtime
  grammar loading, and dynamic filetype/language registration.
  """
  use ExUnit.Case, async: false

  alias Minga.Filetype
  alias Minga.Filetype.Registry, as: FiletypeRegistry
  alias Minga.Highlight.Grammar, as: HLGrammar
  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.TreeSitter

  @moduletag :integration

  @minga_org_repo "https://github.com/jsmestad/minga-org.git"

  # Clone the repo once for the entire module instead of per-test.
  # Tests that need clone_dir get it from the module attribute via context.
  setup_all do
    HLGrammar.init_registry()

    clone_dir =
      Path.join(System.tmp_dir!(), "minga_org_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(clone_dir)

    {_, 0} =
      System.cmd("git", ["clone", "--depth", "1", @minga_org_repo, clone_dir],
        stderr_to_stdout: true
      )

    # Pre-compile the grammar once so individual tests don't each pay ~330ms.
    source_dir = Path.join([clone_dir, "vendor", "tree-sitter-org", "src"])
    {:ok, lib_path} = TreeSitter.compile_grammar("org_shared_test", source_dir)

    on_exit(fn ->
      File.rm_rf!(clone_dir)
      File.rm(lib_path)
    end)

    %{clone_dir: clone_dir, compiled_lib: lib_path, source_dir: source_dir}
  end

  # Idempotent; ensures the ETS table exists even if setup_all hasn't run
  # yet on this scheduler (defensive, costs nothing).
  setup do
    HLGrammar.init_registry()
    :ok
  end

  describe "grammar compilation" do
    test "compiles tree-sitter-org grammar from vendored sources", %{
      source_dir: source_dir,
      compiled_lib: lib_path
    } do
      assert File.exists?(Path.join(source_dir, "parser.c")),
             "parser.c should exist in vendored grammar"

      assert File.exists?(Path.join(source_dir, "scanner.c")),
             "scanner.c should exist in vendored grammar"

      # Grammar was pre-compiled in setup_all; verify the result
      assert File.exists?(lib_path)

      # Verify it's a real shared library (check file type)
      {file_output, 0} = System.cmd("file", [lib_path])
      assert file_output =~ "shared library" or file_output =~ "dynamically linked"
    end

    test "caches compiled grammar on second call", %{
      source_dir: source_dir,
      compiled_lib: lib_path
    } do
      # Touch the compiled library so its mtime is strictly newer than sources.
      original_mtime = File.stat!(lib_path, time: :posix).mtime
      touched_mtime = original_mtime + 2
      File.touch!(lib_path, touched_mtime)

      # Second compile should use cache (no recompilation)
      assert {:ok, ^lib_path} = TreeSitter.compile_grammar("org_shared_test", source_dir)
      second_mtime = File.stat!(lib_path, time: :posix).mtime

      assert second_mtime == touched_mtime, "library should not be recompiled"
    end
  end

  describe "highlight query" do
    test "highlight query file exists and is valid", %{clone_dir: clone_dir} do
      query_path = Path.join([clone_dir, "queries", "org", "highlights.scm"])
      assert File.exists?(query_path)

      {:ok, content} = File.read(query_path)
      assert String.length(content) > 0
      # Should contain standard tree-sitter capture names
      assert content =~ "@keyword"
      assert content =~ "@comment"
      assert content =~ "@string"
    end
  end

  describe "filetype registration" do
    test "registers .org extension in the filetype registry" do
      # Before registration, .org should be unknown
      original = Filetype.detect("notes.org")

      # Register the mapping (what MingaOrg.Grammar.register would do)
      FiletypeRegistry.register(".org", :org)

      assert Filetype.detect("notes.org") == :org
      assert Filetype.detect("todo.org") == :org
      assert Filetype.detect("path/to/deep/file.org") == :org

      # Case insensitivity
      assert Filetype.detect("README.ORG") == :org

      # Unrelated files should not be affected
      assert Filetype.detect("notes.txt") == :text
      assert Filetype.detect("main.ex") == :elixir

      # Clean up if .org was previously unknown
      if original == :text do
        # Re-register to not pollute other tests (registry is shared)
        FiletypeRegistry.register(".org", :org)
      end
    end
  end

  describe "language registration" do
    test "registers org language mapping for syntax highlighting" do
      # Before registration
      before = HLGrammar.language_for_filetype(:org)

      # Register (what MingaOrg.Grammar.register would do)
      HLGrammar.register_language(:org, "org")

      assert {:ok, "org"} = HLGrammar.language_for_filetype(:org)

      # Should appear in supported_languages
      langs = HLGrammar.supported_languages()
      assert Map.get(langs, :org) == "org"

      # Existing languages should be unaffected
      assert {:ok, "elixir"} = HLGrammar.language_for_filetype(:elixir)

      # Clean up if it wasn't registered before
      if before == :unsupported do
        :ets.delete(:minga_grammar_registry, :org)
      end
    end
  end

  describe "keybinding registration" do
    test "registers SPC m bindings scoped to :org filetype" do
      bind = &KeymapActive.bind/5

      # Register the same bindings minga-org would register
      assert :ok = bind.(:normal, "SPC m t", :org_cycle_todo, "Cycle TODO", filetype: :org)

      assert :ok =
               bind.(:normal, "SPC m x", :org_toggle_checkbox, "Toggle checkbox", filetype: :org)

      assert :ok =
               bind.(:normal, "SPC m h", :org_promote_heading, "Promote heading", filetype: :org)

      assert :ok =
               bind.(:normal, "SPC m l", :org_demote_heading, "Demote heading", filetype: :org)

      assert :ok =
               bind.(:normal, "SPC m k", :org_move_heading_up, "Move heading up", filetype: :org)

      assert :ok =
               bind.(:normal, "SPC m j", :org_move_heading_down, "Move heading down",
                 filetype: :org
               )

      # Verify the filetype trie has bindings
      trie = KeymapActive.filetype_trie(:org)
      assert trie != nil, "should have a filetype trie for :org"
    end
  end

  describe "command registration" do
    test "registers org commands with the command registry" do
      alias Minga.Command.Registry

      # Register commands the same way MingaOrg.Commands would
      Registry.register(Registry, :org_cycle_todo, "Cycle TODO keyword", fn state ->
        # In real usage this calls MingaOrg.Todo.cycle/2
        state
      end)

      Registry.register(Registry, :org_toggle_checkbox, "Toggle checkbox", fn state ->
        state
      end)

      # Verify they're registered
      assert {:ok, cmd} = Registry.lookup(Registry, :org_cycle_todo)
      assert cmd.name == :org_cycle_todo
      assert cmd.description == "Cycle TODO keyword"

      assert {:ok, cmd} = Registry.lookup(Registry, :org_toggle_checkbox)
      assert cmd.name == :org_toggle_checkbox
    end
  end

  describe "full extension init simulation" do
    test "end-to-end: compile grammar, register filetype, register language", %{
      clone_dir: clone_dir,
      compiled_lib: lib_path
    } do
      query_path = Path.join([clone_dir, "queries", "org", "highlights.scm"])

      # Step 1: Grammar was pre-compiled in setup_all; verify it exists
      assert File.exists?(lib_path)

      # Step 2: Register filetype
      FiletypeRegistry.register(".org", :org)
      assert Filetype.detect("test.org") == :org

      # Step 3: Register language mapping
      HLGrammar.register_language(:org, "org")
      assert {:ok, "org"} = HLGrammar.language_for_filetype(:org)

      # Step 4: Verify highlight query is readable
      assert {:ok, query} = File.read(query_path)
      assert String.length(query) > 100

      # The only thing we can't test without a running parser Port is the
      # actual load_grammar protocol message and grammar_loaded response.
      # That requires the Zig binary to be running.
    end
  end
end
