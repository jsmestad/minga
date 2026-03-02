defmodule Minga.Highlight.GrammarTest do
  use ExUnit.Case, async: true

  alias Minga.Highlight.Grammar

  describe "language_for_filetype/1" do
    test "maps elixir" do
      assert {:ok, "elixir"} = Grammar.language_for_filetype(:elixir)
    end

    test "maps typescript_react to tsx" do
      assert {:ok, "tsx"} = Grammar.language_for_filetype(:typescript_react)
    end

    test "maps javascript_react to javascript" do
      assert {:ok, "javascript"} = Grammar.language_for_filetype(:javascript_react)
    end

    test "returns unsupported for text" do
      assert :unsupported = Grammar.language_for_filetype(:text)
    end

    test "returns unsupported for unknown filetypes" do
      assert :unsupported = Grammar.language_for_filetype(:nonexistent)
    end

    test "maps all expected filetypes" do
      supported = Grammar.supported_languages()
      # 24 filetype entries, 23 unique languages (javascript_react → javascript)
      assert map_size(supported) == 24
      assert supported |> Map.values() |> Enum.uniq() |> length() == 23
    end
  end

  describe "query_path/1" do
    test "returns priv path for elixir" do
      path = Grammar.query_path("elixir")
      assert path != nil
      assert String.ends_with?(path, "queries/elixir/highlights.scm")
      assert File.exists?(path)
    end

    test "returns nil for nonexistent language" do
      assert Grammar.query_path("nonexistent_lang_xyz") == nil
    end
  end

  describe "read_query/1" do
    test "reads elixir highlights query" do
      assert {:ok, content} = Grammar.read_query("elixir")
      assert is_binary(content)
      assert byte_size(content) > 100
      assert content =~ "keyword"
    end

    test "returns error for nonexistent language" do
      assert {:error, :no_query} = Grammar.read_query("nonexistent_lang_xyz")
    end
  end

  describe "dynamic_grammar_path/1" do
    test "returns path with correct extension" do
      path = Grammar.dynamic_grammar_path("custom")
      assert String.contains?(path, ".config/minga/grammars/custom.")
      assert String.ends_with?(path, ".dylib") or String.ends_with?(path, ".so")
    end
  end
end
