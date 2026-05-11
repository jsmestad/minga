defmodule Minga.LSP.GlobMatcherTest do
  use ExUnit.Case, async: true

  alias Minga.LSP.GlobMatcher

  defp compile!(pattern) do
    {:ok, compiled} = GlobMatcher.compile(pattern)
    compiled
  end

  describe "compile/1" do
    test "returns {:ok, regex} for valid patterns" do
      assert {:ok, %Regex{}} = GlobMatcher.compile("*.ex")
    end

    test "compiles empty pattern" do
      assert {:ok, %Regex{}} = GlobMatcher.compile("")
    end

    test "returns {:error, :invalid_pattern} for nil" do
      assert {:error, :invalid_pattern} = GlobMatcher.compile(nil)
    end

    test "returns {:error, :invalid_pattern} for non-binary input" do
      assert {:error, :invalid_pattern} = GlobMatcher.compile(123)
      assert {:error, :invalid_pattern} = GlobMatcher.compile(%{"base" => "lib"})
    end
  end

  describe "matches?/2 with *" do
    test "matches any characters except path separator" do
      compiled = compile!("*.ex")
      assert GlobMatcher.matches?(compiled, "foo.ex")
      assert GlobMatcher.matches?(compiled, "bar.ex")
      refute GlobMatcher.matches?(compiled, "foo/bar.ex")
      refute GlobMatcher.matches?(compiled, "foo.exs")
    end

    test "matches at end of pattern" do
      compiled = compile!("lib/*")
      assert GlobMatcher.matches?(compiled, "lib/foo")
      assert GlobMatcher.matches?(compiled, "lib/bar.ex")
      refute GlobMatcher.matches?(compiled, "lib/sub/bar.ex")
    end

    test "matches in middle of pattern" do
      compiled = compile!("lib/*.ex")
      assert GlobMatcher.matches?(compiled, "lib/foo.ex")
      refute GlobMatcher.matches?(compiled, "lib/sub/foo.ex")
    end
  end

  describe "matches?/2 with **" do
    test "matches any characters including path separators" do
      compiled = compile!("**/*.ex")
      assert GlobMatcher.matches?(compiled, "foo.ex")
      assert GlobMatcher.matches?(compiled, "lib/foo.ex")
      assert GlobMatcher.matches?(compiled, "lib/minga/lsp/foo.ex")
    end

    test "matches at start of pattern" do
      compiled = compile!("**/mix.lock")
      assert GlobMatcher.matches?(compiled, "mix.lock")
      assert GlobMatcher.matches?(compiled, "deps/foo/mix.lock")
    end

    test "matches zero path segments" do
      compiled = compile!("**/foo.ex")
      assert GlobMatcher.matches?(compiled, "foo.ex")
    end

    test "matches multiple path segments" do
      compiled = compile!("**/foo.ex")
      assert GlobMatcher.matches?(compiled, "a/b/c/foo.ex")
    end

    test "double star alone matches everything" do
      compiled = compile!("**")
      assert GlobMatcher.matches?(compiled, "foo")
      assert GlobMatcher.matches?(compiled, "foo/bar")
      assert GlobMatcher.matches?(compiled, "foo/bar/baz.ex")
    end

    test "double star with trailing slash" do
      compiled = compile!("lib/**/test")
      assert GlobMatcher.matches?(compiled, "lib/test")
      assert GlobMatcher.matches?(compiled, "lib/a/test")
      assert GlobMatcher.matches?(compiled, "lib/a/b/test")
    end
  end

  describe "matches?/2 with ?" do
    test "matches single character except path separator" do
      compiled = compile!("?.ex")
      assert GlobMatcher.matches?(compiled, "a.ex")
      refute GlobMatcher.matches?(compiled, "ab.ex")
      refute GlobMatcher.matches?(compiled, ".ex")
    end

    test "does not match path separator" do
      compiled = compile!("?")
      assert GlobMatcher.matches?(compiled, "a")
      refute GlobMatcher.matches?(compiled, "/")
    end
  end

  describe "matches?/2 with {a,b}" do
    test "matches any alternative" do
      compiled = compile!("*.{ex,exs}")
      assert GlobMatcher.matches?(compiled, "foo.ex")
      assert GlobMatcher.matches?(compiled, "foo.exs")
      refute GlobMatcher.matches?(compiled, "foo.txt")
    end

    test "matches three alternatives" do
      compiled = compile!("*.{ex,exs,eex}")
      assert GlobMatcher.matches?(compiled, "foo.ex")
      assert GlobMatcher.matches?(compiled, "foo.exs")
      assert GlobMatcher.matches?(compiled, "foo.eex")
    end

    test "works with path components" do
      compiled = compile!("{lib,test}/**/*.ex")
      assert GlobMatcher.matches?(compiled, "lib/foo.ex")
      assert GlobMatcher.matches?(compiled, "test/foo.ex")
      refute GlobMatcher.matches?(compiled, "src/foo.ex")
    end
  end

  describe "matches?/2 with [abc]" do
    test "matches characters in set" do
      compiled = compile!("[abc].ex")
      assert GlobMatcher.matches?(compiled, "a.ex")
      assert GlobMatcher.matches?(compiled, "b.ex")
      assert GlobMatcher.matches?(compiled, "c.ex")
      refute GlobMatcher.matches?(compiled, "d.ex")
    end

    test "negated character class with !" do
      compiled = compile!("[!abc].ex")
      refute GlobMatcher.matches?(compiled, "a.ex")
      refute GlobMatcher.matches?(compiled, "b.ex")
      assert GlobMatcher.matches?(compiled, "d.ex")
      assert GlobMatcher.matches?(compiled, "z.ex")
    end
  end

  describe "matches?/2 with literal characters" do
    test "matches exact path" do
      compiled = compile!("mix.lock")
      assert GlobMatcher.matches?(compiled, "mix.lock")
      refute GlobMatcher.matches?(compiled, "mix.lockx")
      refute GlobMatcher.matches?(compiled, "xmix.lock")
    end

    test "escapes regex metacharacters" do
      compiled = compile!("file.txt")
      assert GlobMatcher.matches?(compiled, "file.txt")
      refute GlobMatcher.matches?(compiled, "filextxt")
    end
  end

  describe "matches?/2 real-world LSP patterns" do
    test "elixir-ls mix.lock pattern" do
      compiled = compile!("**/mix.lock")
      assert GlobMatcher.matches?(compiled, "mix.lock")
      assert GlobMatcher.matches?(compiled, "apps/my_app/mix.lock")
    end

    test "typescript tsconfig pattern" do
      compiled = compile!("**/tsconfig.json")
      assert GlobMatcher.matches?(compiled, "tsconfig.json")
      assert GlobMatcher.matches?(compiled, "packages/web/tsconfig.json")
    end

    test "rust-analyzer Cargo pattern" do
      compiled = compile!("**/{Cargo.toml,Cargo.lock}")
      assert GlobMatcher.matches?(compiled, "Cargo.toml")
      assert GlobMatcher.matches?(compiled, "Cargo.lock")
      assert GlobMatcher.matches?(compiled, "crates/foo/Cargo.toml")
    end

    test "config directory pattern" do
      compiled = compile!("config/**/*.exs")
      assert GlobMatcher.matches?(compiled, "config/config.exs")
      assert GlobMatcher.matches?(compiled, "config/dev.exs")
      assert GlobMatcher.matches?(compiled, "config/runtime/extra.exs")
      refute GlobMatcher.matches?(compiled, "lib/config.exs")
    end
  end

  describe "matches_kind?/2" do
    test "default kind 7 matches all change types" do
      assert GlobMatcher.matches_kind?(7, :created)
      assert GlobMatcher.matches_kind?(7, :changed)
      assert GlobMatcher.matches_kind?(7, :deleted)
    end

    test "kind 1 matches only created" do
      assert GlobMatcher.matches_kind?(1, :created)
      refute GlobMatcher.matches_kind?(1, :changed)
      refute GlobMatcher.matches_kind?(1, :deleted)
    end

    test "kind 2 matches only changed" do
      refute GlobMatcher.matches_kind?(2, :created)
      assert GlobMatcher.matches_kind?(2, :changed)
      refute GlobMatcher.matches_kind?(2, :deleted)
    end

    test "kind 4 matches only deleted" do
      refute GlobMatcher.matches_kind?(4, :created)
      refute GlobMatcher.matches_kind?(4, :changed)
      assert GlobMatcher.matches_kind?(4, :deleted)
    end

    test "kind 3 matches created and changed" do
      assert GlobMatcher.matches_kind?(3, :created)
      assert GlobMatcher.matches_kind?(3, :changed)
      refute GlobMatcher.matches_kind?(3, :deleted)
    end
  end
end
