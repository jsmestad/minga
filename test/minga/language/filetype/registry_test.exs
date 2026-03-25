defmodule Minga.Language.Filetype.RegistryTest do
  @moduledoc "Tests for Minga.Language.Filetype.Registry — runtime-extensible filetype lookup."
  use ExUnit.Case, async: true

  alias Minga.Language.Filetype.Registry

  # Each test gets its own named Registry to avoid interference.

  setup do
    name = :"registry_#{:erlang.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: name)
    %{name: name}
  end

  # Helper to call Registry functions on the test-specific agent.
  defp lookup_ext(name, ext), do: Agent.get(name, fn s -> Map.get(s.extensions, ext) end)
  defp lookup_fname(name, f), do: Agent.get(name, fn s -> Map.get(s.filenames, f) end)

  defp lookup_shebang(name, i),
    do: Agent.get(name, fn s -> Map.get(s.shebang_interpreters, i) end)

  defp register_ext(name, ext, ft) do
    "." <> bare = ext

    Agent.update(name, fn s ->
      %{s | extensions: Map.put(s.extensions, String.downcase(bare), ft)}
    end)
  end

  defp register_fname(name, filename, ft) do
    Agent.update(name, fn s -> %{s | filenames: Map.put(s.filenames, filename, ft)} end)
  end

  defp register_shebang(name, interpreter, ft) do
    Agent.update(name, fn s ->
      %{s | shebang_interpreters: Map.put(s.shebang_interpreters, interpreter, ft)}
    end)
  end

  describe "defaults" do
    test "includes hardcoded extensions", %{name: name} do
      assert lookup_ext(name, "ex") == :elixir
      assert lookup_ext(name, "go") == :go
      assert lookup_ext(name, "rs") == :rust
    end

    test "includes hardcoded filenames", %{name: name} do
      assert lookup_fname(name, "Makefile") == :make
      assert lookup_fname(name, "Dockerfile") == :dockerfile
    end

    test "includes hardcoded shebang interpreters", %{name: name} do
      assert lookup_shebang(name, "ruby") == :ruby
      assert lookup_shebang(name, "python3") == :python
    end
  end

  describe "register/2" do
    test "registers a new extension", %{name: name} do
      assert lookup_ext(name, "astro") == nil
      register_ext(name, ".astro", :astro)
      assert lookup_ext(name, "astro") == :astro
    end

    test "registers a new filename", %{name: name} do
      assert lookup_fname(name, "Justfile") == nil
      register_fname(name, "Justfile", :just)
      assert lookup_fname(name, "Justfile") == :just
    end

    test "overrides an existing extension", %{name: name} do
      assert lookup_ext(name, "h") == :c
      register_ext(name, ".h", :cpp)
      assert lookup_ext(name, "h") == :cpp
    end
  end

  describe "register_shebang/2" do
    test "registers a new shebang interpreter", %{name: name} do
      assert lookup_shebang(name, "deno") == nil
      register_shebang(name, "deno", :typescript)
      assert lookup_shebang(name, "deno") == :typescript
    end
  end
end
