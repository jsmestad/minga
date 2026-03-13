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
      # At least 40 compile-time filetype entries (extensions may add more at runtime)
      assert map_size(supported) >= 40
      # At least 39 unique languages (javascript_react → javascript share one)
      assert supported |> Map.values() |> Enum.uniq() |> length() >= 39
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

  describe "injection_query_path/1" do
    test "returns path for markdown (has injection query in priv)" do
      path = Grammar.injection_query_path("markdown")
      assert path != nil
      assert String.ends_with?(path, "injections.scm")
    end

    test "returns nil for languages without injection queries" do
      assert Grammar.injection_query_path("json") == nil
    end

    test "returns nil for nonexistent languages" do
      assert Grammar.injection_query_path("nonexistent_lang_xyz") == nil
    end
  end

  describe "read_injection_query/1" do
    test "reads markdown injection query" do
      assert {:ok, content} = Grammar.read_injection_query("markdown")
      assert is_binary(content)
      assert content =~ "injection"
    end

    test "returns error for language without injection query" do
      assert {:error, :no_query} = Grammar.read_injection_query("json")
    end

    test "returns error for nonexistent language" do
      assert {:error, :no_query} = Grammar.read_injection_query("nonexistent_lang_xyz")
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
