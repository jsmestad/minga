defmodule Minga.Extension.EntryTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Entry

  describe "from_path/2" do
    test "creates a path-sourced entry" do
      entry = Entry.from_path("/tmp/my_ext", greeting: "hello")

      assert %Entry{} = entry
      assert entry.source_type == :path
      assert entry.path == "/tmp/my_ext"
      assert entry.config == [greeting: "hello"]
      assert entry.status == :stopped
      assert entry.module == nil
      assert entry.pid == nil
      assert entry.git == nil
      assert entry.hex == nil
    end

    test "accepts empty config" do
      entry = Entry.from_path("/tmp/ext", [])
      assert entry.config == []
    end
  end

  describe "from_git/2" do
    test "creates a git-sourced entry with no branch or ref" do
      entry = Entry.from_git("https://github.com/user/repo", [])

      assert %Entry{} = entry
      assert entry.source_type == :git
      assert entry.git == %{url: "https://github.com/user/repo", branch: nil, ref: nil}
      assert entry.path == nil
      assert entry.hex == nil
      assert entry.config == []
    end

    test "extracts branch from opts" do
      entry = Entry.from_git("https://github.com/user/repo", branch: "develop")

      assert entry.git.branch == "develop"
      assert entry.git.ref == nil
    end

    test "extracts ref from opts" do
      entry = Entry.from_git("git@github.com:user/repo.git", ref: "abc123")

      assert entry.git.ref == "abc123"
      assert entry.git.branch == nil
    end

    test "separates branch/ref from extension config" do
      entry =
        Entry.from_git("https://github.com/user/repo",
          branch: "main",
          greeting: "hello",
          debug: true
        )

      assert entry.git.branch == "main"
      assert entry.config == [greeting: "hello", debug: true]
    end
  end

  describe "from_hex/2" do
    test "creates a hex-sourced entry with version constraint" do
      entry = Entry.from_hex("minga_snippets", version: "~> 0.3")

      assert %Entry{} = entry
      assert entry.source_type == :hex
      assert entry.hex == %{package: "minga_snippets", version: "~> 0.3"}
      assert entry.path == nil
      assert entry.git == nil
      assert entry.config == []
    end

    test "creates a hex-sourced entry without version" do
      entry = Entry.from_hex("minga_snippets", [])

      assert entry.hex.package == "minga_snippets"
      assert entry.hex.version == nil
    end

    test "separates version from extension config" do
      entry = Entry.from_hex("minga_snippets", version: "~> 1.0", greeting: "hello")

      assert entry.hex.version == "~> 1.0"
      assert entry.config == [greeting: "hello"]
    end
  end

  describe "struct enforcement" do
    test "source_type is required" do
      assert_raise ArgumentError, fn ->
        struct!(Entry, path: "/tmp/ext")
      end
    end
  end
end
