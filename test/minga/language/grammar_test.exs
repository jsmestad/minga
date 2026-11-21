defmodule Minga.Language.GrammarTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Grammar

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
      assert supported |> Map.values() |> Enum.uniq() |> Enum.count() >= 39
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

    test "prefers user queries under XDG config" do
      language = "profile_test"
      dir = Path.join([System.fetch_env!("XDG_CONFIG_HOME"), "minga", "queries", language])
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      highlights = Path.join(dir, "highlights.scm")
      injections = Path.join(dir, "injections.scm")
      File.write!(highlights, "(identifier) @variable")
      File.write!(injections, "(comment) @injection.content")

      assert Grammar.query_path(language) == highlights
      assert Grammar.injection_query_path(language) == injections
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

    test "does not fall back to a bundled injection query when the override cannot be read" do
      language = "protobuf"
      assert {:ok, _} = Grammar.read_injection_query(language)

      dir = Path.join([System.fetch_env!("XDG_CONFIG_HOME"), "minga", "queries", language])
      override = Path.join(dir, "injections.scm")
      File.mkdir_p!(override)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert Grammar.injection_query_path(language) == override
      assert {:error, :eisdir} = Grammar.read_injection_query(language)
    end

    test "returns error for language without injection query" do
      assert {:error, :no_query} = Grammar.read_injection_query("json")
    end

    test "returns error for nonexistent language" do
      assert {:error, :no_query} = Grammar.read_injection_query("nonexistent_lang_xyz")
    end
  end

  describe "dynamic_grammar_path/1" do
    test "returns the XDG config path with the platform extension" do
      config_home = System.fetch_env!("XDG_CONFIG_HOME")
      extension = if :os.type() == {:unix, :darwin}, do: "dylib", else: "so"

      assert Grammar.dynamic_grammar_path("custom") ==
               Path.join([config_home, "minga", "grammars", "custom.#{extension}"])
    end
  end
end
