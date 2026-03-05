defmodule Minga.LSP.ServerRegistryTest do
  use ExUnit.Case, async: true

  alias Minga.LSP.ServerRegistry

  describe "servers_for/1" do
    test "returns server configs for Elixir" do
      configs = ServerRegistry.servers_for(:elixir)
      assert length(configs) == 1

      [config] = configs
      assert config.name == :lexical
      assert config.command == "lexical"
      assert is_list(config.args)
      assert "mix.exs" in config.root_markers
      assert is_map(config.init_options)
    end

    test "returns server configs for Go" do
      [config] = ServerRegistry.servers_for(:go)
      assert config.name == :gopls
      assert config.command == "gopls"
      assert "go.mod" in config.root_markers
    end

    test "returns server configs for Rust" do
      [config] = ServerRegistry.servers_for(:rust)
      assert config.name == :rust_analyzer
      assert config.command == "rust-analyzer"
      assert "Cargo.toml" in config.root_markers
    end

    test "returns server configs for C" do
      [config] = ServerRegistry.servers_for(:c)
      assert config.name == :clangd
      assert config.command == "clangd"
    end

    test "C and C++ share the same server" do
      [c_config] = ServerRegistry.servers_for(:c)
      [cpp_config] = ServerRegistry.servers_for(:cpp)
      assert c_config.name == cpp_config.name
      assert c_config.command == cpp_config.command
    end

    test "returns server configs for JavaScript" do
      [config] = ServerRegistry.servers_for(:javascript)
      assert config.name == :typescript_language_server
      assert config.command == "typescript-language-server"
      assert "--stdio" in config.args
      assert "package.json" in config.root_markers
    end

    test "returns server configs for TypeScript" do
      [config] = ServerRegistry.servers_for(:typescript)
      assert config.name == :typescript_language_server
      assert "tsconfig.json" in config.root_markers
    end

    test "returns server configs for Python" do
      [config] = ServerRegistry.servers_for(:python)
      assert config.name == :pyright
      assert "pyproject.toml" in config.root_markers
    end

    test "returns server configs for Ruby" do
      [config] = ServerRegistry.servers_for(:ruby)
      assert config.name == :solargraph
      assert "Gemfile" in config.root_markers
    end

    test "returns server configs for Zig" do
      [config] = ServerRegistry.servers_for(:zig)
      assert config.name == :zls
      assert "build.zig" in config.root_markers
    end

    test "returns server configs for Lua" do
      [config] = ServerRegistry.servers_for(:lua)
      assert config.name == :lua_ls
    end

    test "returns server configs for Bash" do
      [config] = ServerRegistry.servers_for(:bash)
      assert config.name == :bash_language_server
      assert config.command == "bash-language-server"
    end

    test "returns empty list for unknown filetype" do
      assert ServerRegistry.servers_for(:unknown_language) == []
    end

    test "returns empty list for nil-like atoms" do
      assert ServerRegistry.servers_for(:text) == []
    end

    test "all configs have required keys" do
      for filetype <- ServerRegistry.supported_filetypes(),
          config <- ServerRegistry.servers_for(filetype) do
        assert is_atom(config.name), "#{filetype}: name must be atom"
        assert is_binary(config.command), "#{filetype}: command must be string"
        assert is_list(config.args), "#{filetype}: args must be list"
        assert is_list(config.root_markers), "#{filetype}: root_markers must be list"
        assert is_map(config.init_options), "#{filetype}: init_options must be map"
      end
    end
  end

  describe "supported_filetypes/0" do
    test "returns a list of atoms" do
      filetypes = ServerRegistry.supported_filetypes()
      assert is_list(filetypes)
      assert filetypes != []
      assert Enum.all?(filetypes, &is_atom/1)
    end

    test "includes core languages" do
      filetypes = ServerRegistry.supported_filetypes()
      assert :elixir in filetypes
      assert :go in filetypes
      assert :rust in filetypes
      assert :javascript in filetypes
      assert :typescript in filetypes
      assert :python in filetypes
    end
  end

  describe "available?/1" do
    test "returns false for nonexistent binary" do
      config = %Minga.LSP.ServerConfig{
        name: :fake,
        command: "definitely_not_a_real_binary_#{System.unique_integer()}"
      }

      refute ServerRegistry.available?(config)
    end

    test "returns true for a binary on PATH" do
      # `elixir` should always be available in test env
      config = %Minga.LSP.ServerConfig{
        name: :test,
        command: "elixir"
      }

      assert ServerRegistry.available?(config)
    end
  end

  describe "available_servers_for/1" do
    test "filters out unavailable servers" do
      # Unknown filetype has no servers
      assert ServerRegistry.available_servers_for(:unknown_language) == []
    end

    test "returns only servers with binaries on PATH" do
      # We can't guarantee any LSP servers are installed, but we can
      # verify the function doesn't crash and returns a subset
      all = ServerRegistry.servers_for(:elixir)
      available = ServerRegistry.available_servers_for(:elixir)

      assert length(available) <= length(all)
      assert Enum.all?(available, &ServerRegistry.available?/1)
    end
  end
end
