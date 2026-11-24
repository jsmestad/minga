defmodule Minga.Extension.EntryTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Entry

  describe "from_path/2" do
    test "creates a path-sourced entry" do
      entry = Entry.from_path("/tmp/my_ext", greeting: "hello")

      assert %Entry{} = entry
      assert entry.source == {:path, "/tmp/my_ext"}
      assert entry.config == [greeting: "hello"]
      assert entry.status == :stopped
      assert entry.module == nil
      assert entry.pid == nil
    end

    test "accepts empty config" do
      entry = Entry.from_path("/tmp/ext", [])
      assert entry.config == []
    end
  end

  describe "from_module/2" do
    test "creates a module-sourced entry with runtime module set" do
      entry = Entry.from_module(SomeModule, greeting: "hi")

      assert entry.source == {:module, SomeModule}
      assert entry.module == SomeModule
      assert entry.config == [greeting: "hi"]
    end
  end

  describe "from_git/2" do
    test "creates a git-sourced entry with no branch or ref" do
      entry = Entry.from_git("https://github.com/user/repo", [])

      assert %Entry{} = entry
      assert {:git, git_opts} = entry.source
      assert git_opts.url == "https://github.com/user/repo"
      assert git_opts.branch == nil
      assert git_opts.ref == nil
      assert git_opts.path == nil
      assert entry.module == nil
      assert entry.config == []
    end

    test "extracts branch from opts" do
      entry = Entry.from_git("https://github.com/user/repo", branch: "develop")

      assert {:git, git_opts} = entry.source
      assert git_opts.branch == "develop"
      assert git_opts.ref == nil
    end

    test "extracts ref from opts" do
      entry = Entry.from_git("git@github.com:user/repo.git", ref: "abc123")

      assert {:git, git_opts} = entry.source
      assert git_opts.ref == "abc123"
      assert git_opts.branch == nil
    end

    test "separates branch/ref from extension config" do
      entry =
        Entry.from_git("https://github.com/user/repo",
          branch: "main",
          greeting: "hello",
          debug: true
        )

      assert {:git, git_opts} = entry.source
      assert git_opts.branch == "main"
      assert entry.config == [greeting: "hello", debug: true]
    end
  end

  describe "from_hex/3" do
    test "creates a hex-sourced entry with version constraint" do
      entry = Entry.from_hex("minga_snippets", :minga_snippets, version: "~> 0.3")

      assert %Entry{} = entry
      assert {:hex, hex_opts} = entry.source
      assert hex_opts == %{package: "minga_snippets", version: "~> 0.3", app: :minga_snippets}
      assert entry.module == nil
      assert entry.config == []
    end

    test "creates a hex-sourced entry without version" do
      entry = Entry.from_hex("minga_snippets", :minga_snippets, [])

      assert {:hex, hex_opts} = entry.source
      assert hex_opts.package == "minga_snippets"
      assert hex_opts.version == nil
    end

    test "separates version from extension config" do
      entry =
        Entry.from_hex("minga_snippets", :minga_snippets, version: "~> 1.0", greeting: "hello")

      assert {:hex, hex_opts} = entry.source
      assert hex_opts.version == "~> 1.0"
      assert hex_opts.app == :minga_snippets
      assert entry.config == [greeting: "hello"]
    end
  end

  describe "struct enforcement" do
    test "source is required" do
      assert_raise ArgumentError, fn ->
        struct!(Entry, module: SomeModule)
      end
    end
  end

  describe "source_type/1" do
    test "returns :path for path entries" do
      assert Entry.source_type(Entry.from_path("/tmp/ext", [])) == :path
    end

    test "returns :git for git entries" do
      assert Entry.source_type(Entry.from_git("https://example.com/repo", [])) == :git
    end

    test "returns :hex for hex entries" do
      assert Entry.source_type(Entry.from_hex("pkg", :pkg, [])) == :hex
    end

    test "returns :module for module entries" do
      assert Entry.source_type(Entry.from_module(SomeModule, [])) == :module
    end
  end

  describe "source_path/1" do
    test "returns path for path entries" do
      assert Entry.source_path(Entry.from_path("/tmp/ext", [])) == "/tmp/ext"
    end

    test "returns nil for unresolved git entries" do
      assert Entry.source_path(Entry.from_git("https://example.com/repo", [])) == nil
    end

    test "returns resolved path for git entries" do
      entry =
        Entry.from_git("https://example.com/repo", [])
        |> Entry.resolve_git_path("/tmp/checkout")

      assert Entry.source_path(entry) == "/tmp/checkout"
    end

    test "returns nil for hex entries" do
      assert Entry.source_path(Entry.from_hex("pkg", :pkg, [])) == nil
    end

    test "returns nil for module entries" do
      assert Entry.source_path(Entry.from_module(SomeModule, [])) == nil
    end
  end

  describe "git_opts/1" do
    test "returns git options for git entries" do
      entry = Entry.from_git("https://example.com/repo", branch: "main")
      opts = Entry.git_opts(entry)
      assert opts.url == "https://example.com/repo"
      assert opts.branch == "main"
    end

    test "returns nil for non-git entries" do
      assert Entry.git_opts(Entry.from_path("/tmp/ext", [])) == nil
    end
  end

  describe "hex_opts/1" do
    test "returns hex options for hex entries" do
      entry = Entry.from_hex("minga_snippets", :minga_snippets, version: "~> 0.3")
      opts = Entry.hex_opts(entry)
      assert opts.package == "minga_snippets"
      assert opts.version == "~> 0.3"
    end

    test "returns nil for non-hex entries" do
      assert Entry.hex_opts(Entry.from_path("/tmp/ext", [])) == nil
    end
  end

  describe "source_module/1" do
    test "returns module for module entries" do
      assert Entry.source_module(Entry.from_module(SomeModule, [])) == SomeModule
    end

    test "returns nil for non-module entries" do
      assert Entry.source_module(Entry.from_path("/tmp/ext", [])) == nil
    end
  end

  describe "resolve_git_path/2" do
    test "sets the resolved checkout path on a git entry" do
      entry = Entry.from_git("https://example.com/repo", branch: "main")
      resolved = Entry.resolve_git_path(entry, "/tmp/checkout")

      assert {:git, opts} = resolved.source
      assert opts.path == "/tmp/checkout"
      assert opts.url == "https://example.com/repo"
      assert opts.branch == "main"
    end
  end

  describe "invalid source combinations are unrepresentable" do
    test "path source always carries a path" do
      entry = Entry.from_path("/tmp/ext", [])
      assert {:path, path} = entry.source
      assert is_binary(path)
    end

    test "git source always carries url" do
      entry = Entry.from_git("https://example.com/repo", [])
      assert {:git, %{url: url}} = entry.source
      assert is_binary(url)
    end

    test "hex source always carries package and app" do
      entry = Entry.from_hex("pkg", :pkg, [])
      assert {:hex, %{package: pkg, app: app}} = entry.source
      assert is_binary(pkg)
      assert is_atom(app)
    end

    test "module source always carries a module" do
      entry = Entry.from_module(SomeModule, [])
      assert {:module, mod} = entry.source
      assert is_atom(mod)
    end
  end
end
