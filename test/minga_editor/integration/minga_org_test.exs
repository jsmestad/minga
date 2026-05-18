defmodule Minga.Integration.MingaOrgTest do
  @moduledoc """
  Thin integration smoke for the extension-style grammar loading path.

  The old version cloned the public minga-org repository and then asserted several lower-level registries independently. This local fixture keeps the important contract, an extension-shaped tree can provide grammar sources, highlight queries, filetype mappings, and dynamic language registration, without network access or duplicated registry coverage.
  """
  # Serial because grammar compilation shells out to cc and writes shared grammar cache files.
  use ExUnit.Case, async: false

  alias Minga.Language.Filetype
  alias Minga.Language.Filetype.Registry, as: FiletypeRegistry
  alias Minga.Language.TreeSitter
  alias MingaEditor.UI.Highlight.Grammar, as: HLGrammar

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 10_000

  setup %{tmp_dir: tmp_dir} do
    HLGrammar.init_registry()

    original_org_filetype = FiletypeRegistry.lookup_extension("org")
    original_org_language = :ets.lookup(:minga_grammar_registry, :org)

    extension_dir = build_extension_fixture(tmp_dir)
    grammar_name = "org_fixture_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      FiletypeRegistry.register(".org", original_org_filetype)
      restore_org_language(original_org_language)
      File.rm(TreeSitter.grammar_lib_path(grammar_name))
    end)

    %{
      extension_dir: extension_dir,
      grammar_name: grammar_name,
      source_dir: Path.join([extension_dir, "vendor", "tree-sitter-org", "src"]),
      query_path: Path.join([extension_dir, "queries", "org", "highlights.scm"])
    }
  end

  test "extension fixture provides compilable grammar sources and highlight query", %{
    grammar_name: grammar_name,
    source_dir: source_dir,
    query_path: query_path
  } do
    assert File.exists?(Path.join(source_dir, "parser.c"))

    assert {:ok, lib_path} = TreeSitter.compile_grammar(grammar_name, source_dir)
    assert File.exists?(lib_path)
    assert String.ends_with?(lib_path, ".#{shared_lib_ext()}")

    assert {:ok, query} = File.read(query_path)
    assert query =~ "@keyword"
    assert query =~ "@string"
  end

  test "extension-style registration maps org files to dynamic highlighting language" do
    FiletypeRegistry.register(".org", :org)
    HLGrammar.register_language(:org, "org")

    assert Filetype.detect("notes.org") == :org
    assert Filetype.detect("README.ORG") == :org
    assert {:ok, "org"} = HLGrammar.language_for_filetype(:org)
    assert Filetype.detect("main.ex") == :elixir
  end

  defp build_extension_fixture(tmp_dir) do
    extension_dir = Path.join(tmp_dir, "minga_org_fixture")
    source_dir = Path.join([extension_dir, "vendor", "tree-sitter-org", "src"])
    query_dir = Path.join([extension_dir, "queries", "org"])

    File.mkdir_p!(Path.dirname(source_dir))
    File.cp_r!(Path.join([File.cwd!(), "zig", "vendor", "grammars", "json", "src"]), source_dir)
    File.mkdir_p!(query_dir)

    File.write!(Path.join(query_dir, "highlights.scm"), """
    (document) @keyword
    (string) @string
    """)

    extension_dir
  end

  defp restore_org_language([]), do: :ets.delete(:minga_grammar_registry, :org)

  defp restore_org_language([{:org, language}]),
    do: :ets.insert(:minga_grammar_registry, {:org, language})

  defp shared_lib_ext do
    case :os.type() do
      {:unix, :darwin} -> "dylib"
      {:unix, _} -> "so"
    end
  end
end
