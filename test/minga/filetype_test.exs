defmodule Minga.FiletypeTest do
  @moduledoc "Tests for Minga.Filetype — file language detection."
  use ExUnit.Case, async: true

  alias Minga.Filetype

  describe "detect/1 — extension matching" do
    test "detects Elixir files" do
      assert Filetype.detect("lib/minga.ex") == :elixir
      assert Filetype.detect("test/foo_test.exs") == :elixir
    end

    test "detects Erlang files" do
      assert Filetype.detect("src/app.erl") == :erlang
      assert Filetype.detect("include/defs.hrl") == :erlang
    end

    test "detects HEEx templates" do
      assert Filetype.detect("lib/app_web/index.html.heex") == :heex
      assert Filetype.detect("lib/app_web/form.leex") == :heex
    end

    test "detects Ruby files" do
      assert Filetype.detect("app.rb") == :ruby
      assert Filetype.detect("tasks/deploy.rake") == :ruby
      assert Filetype.detect("mygem.gemspec") == :ruby
    end

    test "detects JavaScript and TypeScript" do
      assert Filetype.detect("app.js") == :javascript
      assert Filetype.detect("lib.mjs") == :javascript
      assert Filetype.detect("config.cjs") == :javascript
      assert Filetype.detect("app.ts") == :typescript
      assert Filetype.detect("lib.mts") == :typescript
    end

    test "detects JSX and TSX" do
      assert Filetype.detect("App.jsx") == :javascript_react
      assert Filetype.detect("App.tsx") == :typescript_react
    end

    test "detects Go, Rust, Zig" do
      assert Filetype.detect("main.go") == :go
      assert Filetype.detect("lib.rs") == :rust
      assert Filetype.detect("main.zig") == :zig
      assert Filetype.detect("build.zig.zon") == :zig
    end

    test "detects C and C++" do
      assert Filetype.detect("main.c") == :c
      assert Filetype.detect("header.h") == :c
      assert Filetype.detect("main.cpp") == :cpp
      assert Filetype.detect("lib.cc") == :cpp
      assert Filetype.detect("util.cxx") == :cpp
      assert Filetype.detect("header.hpp") == :cpp
    end

    test "detects scripting languages" do
      assert Filetype.detect("script.lua") == :lua
      assert Filetype.detect("app.py") == :python
      assert Filetype.detect("run.sh") == :bash
      assert Filetype.detect("init.bash") == :bash
      assert Filetype.detect("setup.zsh") == :bash
    end

    test "detects web languages" do
      assert Filetype.detect("index.html") == :html
      assert Filetype.detect("page.htm") == :html
      assert Filetype.detect("style.css") == :css
      assert Filetype.detect("style.scss") == :scss
    end

    test "detects data formats" do
      assert Filetype.detect("config.json") == :json
      assert Filetype.detect("data.yaml") == :yaml
      assert Filetype.detect("data.yml") == :yaml
      assert Filetype.detect("config.toml") == :toml
      assert Filetype.detect("README.md") == :markdown
      assert Filetype.detect("schema.sql") == :sql
      assert Filetype.detect("schema.graphql") == :graphql
      assert Filetype.detect("query.gql") == :graphql
    end

    test "detects other languages" do
      assert Filetype.detect("app.kt") == :kotlin
      assert Filetype.detect("app.gleam") == :gleam
      assert Filetype.detect("init.el") == :emacs_lisp
      assert Filetype.detect("config.lfe") == :lfe
      assert Filetype.detect("default.nix") == :nix
    end

    test "is case-insensitive for extensions" do
      assert Filetype.detect("App.EX") == :elixir
      assert Filetype.detect("Main.Go") == :go
      assert Filetype.detect("lib.RS") == :rust
      assert Filetype.detect("CONFIG.JSON") == :json
    end

    test "unknown extension returns :text" do
      assert Filetype.detect("file.xyz") == :text
      assert Filetype.detect("file.unknown") == :text
    end

    test "file with multiple dots uses last extension" do
      assert Filetype.detect("foo.test.ex") == :elixir
      assert Filetype.detect("data.backup.json") == :json
    end
  end

  describe "detect/1 — exact filename matching" do
    test "detects Makefile" do
      assert Filetype.detect("Makefile") == :make
      assert Filetype.detect("/path/to/Makefile") == :make
      assert Filetype.detect("GNUmakefile") == :make
    end

    test "detects Dockerfile" do
      assert Filetype.detect("Dockerfile") == :dockerfile
    end

    test "detects Ruby project files" do
      assert Filetype.detect("Gemfile") == :ruby
      assert Filetype.detect("Rakefile") == :ruby
      assert Filetype.detect("Brewfile") == :ruby
    end

    test "detects git config files" do
      assert Filetype.detect(".gitignore") == :gitconfig
      assert Filetype.detect(".gitattributes") == :gitconfig
    end

    test "exact filenames are case-sensitive" do
      assert Filetype.detect("makefile") == :text
      assert Filetype.detect("dockerfile") != :make
    end

    test "mix.lock detected as elixir" do
      assert Filetype.detect("mix.lock") == :elixir
    end
  end

  describe "detect/1 — .env patterns" do
    test ".env files are detected as bash" do
      assert Filetype.detect(".env") == :bash
      assert Filetype.detect(".env.production") == :bash
      assert Filetype.detect(".env.test") == :bash
      assert Filetype.detect(".env.local") == :bash
    end

    test ".envrc files are detected as bash" do
      assert Filetype.detect(".envrc") == :bash
      assert Filetype.detect(".envrc.private") == :bash
    end
  end

  describe "detect/1 — edge cases" do
    test "nil path returns :text" do
      assert Filetype.detect(nil) == :text
    end

    test "file with no extension and no filename match returns :text" do
      assert Filetype.detect("somefile") == :text
    end

    test "empty string returns :text" do
      assert Filetype.detect("") == :text
    end
  end

  describe "detect_from_content/2 — shebang detection" do
    test "detects Ruby from shebang" do
      assert Filetype.detect_from_content("script", "#!/usr/bin/env ruby") == :ruby
    end

    test "detects Python from shebang" do
      assert Filetype.detect_from_content("script", "#!/usr/bin/python3") == :python
      assert Filetype.detect_from_content("script", "#!/usr/bin/env python3") == :python
    end

    test "detects Bash from shebang" do
      assert Filetype.detect_from_content("script", "#!/bin/bash") == :bash
      assert Filetype.detect_from_content("script", "#!/usr/bin/env sh") == :bash
    end

    test "detects Node from shebang" do
      assert Filetype.detect_from_content("script", "#!/usr/bin/env node") == :javascript
    end

    test "detects Elixir from shebang" do
      assert Filetype.detect_from_content("script", "#!/usr/bin/env elixir") == :elixir
    end

    test "path-based detection takes priority over shebang" do
      assert Filetype.detect_from_content("app.rb", "#!/usr/bin/env python3") == :ruby
    end

    test "nil first_line falls back to :text" do
      assert Filetype.detect_from_content("script", nil) == :text
    end

    test "empty first_line falls back to :text" do
      assert Filetype.detect_from_content("script", "") == :text
    end

    test "non-shebang first line falls back to :text" do
      assert Filetype.detect_from_content("script", "hello world") == :text
    end

    test "unknown shebang interpreter falls back to :text" do
      assert Filetype.detect_from_content("script", "#!/usr/bin/env obscurelang") == :text
    end
  end
end
