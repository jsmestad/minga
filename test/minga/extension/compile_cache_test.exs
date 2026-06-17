defmodule Minga.Extension.CompileCacheTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.CompileCache

  setup do
    cache_dir = Path.join(System.tmp_dir!(), "ext_cache_#{:erlang.unique_integer([:positive])}")
    src_dir = Path.join(System.tmp_dir!(), "ext_src_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(src_dir)

    on_exit(fn ->
      File.rm_rf!(cache_dir)
      File.rm_rf!(src_dir)
    end)

    %{cache_dir: cache_dir, src_dir: src_dir}
  end

  # Writes a single-module extension source and returns {root, files, module}.
  defp write_extension(src_dir, body) do
    module = :"Elixir.ExtFixture#{:erlang.unique_integer([:positive])}"
    file = Path.join(src_dir, "ext.ex")

    File.write!(file, """
    defmodule #{inspect(module)} do
      def marker, do: #{body}
    end
    """)

    {src_dir, [file], module}
  end

  defp opts(cache_dir), do: [cache_dir: cache_dir, enabled: true]

  describe "type inference during runtime compilation (issue #2355)" do
    # NOTE: `:infer_signatures` is global VM compiler state, not process-local.
    # These tests are safe under `async: true` because CompileCache mutates and
    # restores it under a `:global.trans` lock (so concurrent compiles here are
    # serialized) and no other test suite touches `:infer_signatures`. If a
    # future async test starts reading/writing that option, move this block to a
    # separate `async: false` module.

    # A fixture that records, at compile time, whether type inference was on
    # while it was being compiled.
    defp write_infer_probe(src_dir) do
      module = :"Elixir.ExtInferProbe#{:erlang.unique_integer([:positive])}"
      file = Path.join(src_dir, "infer_probe.ex")

      File.write!(file, """
      defmodule #{inspect(module)} do
        @infer_during_compile Code.get_compiler_option(:infer_signatures)
        def infer_during_compile, do: @infer_during_compile
      end
      """)

      {src_dir, [file], module}
    end

    test "disables type inference while compiling and restores it after (cache path)", %{
      cache_dir: cache_dir,
      src_dir: src_dir
    } do
      {root, files, module} = write_infer_probe(src_dir)
      before = Code.get_compiler_option(:infer_signatures)

      assert {:ok, %{modules: modules}} =
               CompileCache.load_or_compile(root, files, opts(cache_dir))

      assert module in modules
      # The extension's module graph was NOT type-inferred at compile time, so a
      # release boot does not re-run the type checker over it (the #2355 spike).
      assert module.infer_during_compile() == false
      # The global compiler option is restored, not leaked, after the compile.
      assert Code.get_compiler_option(:infer_signatures) == before
    end

    test "disables inference on the in-memory (cache-off) path too", %{src_dir: src_dir} do
      {root, files, module} = write_infer_probe(src_dir)
      before = Code.get_compiler_option(:infer_signatures)

      assert {:ok, %{modules: modules}} =
               CompileCache.load_or_compile(root, files, enabled: false)

      assert module in modules
      assert module.infer_during_compile() == false
      assert Code.get_compiler_option(:infer_signatures) == before
    end
  end

  describe "load_or_compile/3" do
    test "compiles and writes beams on a miss", %{cache_dir: cache_dir, src_dir: src_dir} do
      {root, files, module} = write_extension(src_dir, ":v1")

      assert {:ok, %{modules: modules, source: :compiled, diagnostics: []}} =
               CompileCache.load_or_compile(root, files, opts(cache_dir))

      assert module in modules
      assert module.marker() == :v1
      # A .beam was persisted somewhere under the cache root.
      assert Path.wildcard(Path.join(cache_dir, "**/*.beam")) != []
    end

    test "loads from cache on a hit without recompiling", %{
      cache_dir: cache_dir,
      src_dir: src_dir
    } do
      {root, files, module} = write_extension(src_dir, ":v1")

      assert {:ok, %{source: :compiled}} =
               CompileCache.load_or_compile(root, files, opts(cache_dir))

      assert {:ok, %{modules: modules, source: :cache, diagnostics: []}} =
               CompileCache.load_or_compile(root, files, opts(cache_dir))

      assert module in modules
      assert module.marker() == :v1
    end

    test "recompiles and prunes the old entry when source changes", %{
      cache_dir: cache_dir,
      src_dir: src_dir
    } do
      module = :"Elixir.ExtFixtureChange#{:erlang.unique_integer([:positive])}"
      file = Path.join(src_dir, "ext.ex")

      write = fn body ->
        File.write!(file, "defmodule #{inspect(module)} do\n  def marker, do: #{body}\nend\n")
      end

      write.(":v1")

      assert {:ok, %{source: :compiled}} =
               CompileCache.load_or_compile(src_dir, [file], opts(cache_dir))

      [ext_dir] = Path.wildcard(Path.join(cache_dir, "*"))
      assert length(File.ls!(ext_dir)) == 1

      write.(":v2")

      assert {:ok, %{source: :compiled, modules: modules}} =
               CompileCache.load_or_compile(src_dir, [file], opts(cache_dir))

      assert module.marker() == :v2
      # Old key pruned: still exactly one entry for this extension.
      assert length(File.ls!(ext_dir)) == 1
      assert module in modules
    end

    test "falls back to recompiling when a cached beam is corrupt", %{
      cache_dir: cache_dir,
      src_dir: src_dir
    } do
      {root, files, module} = write_extension(src_dir, ":v1")

      assert {:ok, %{source: :compiled}} =
               CompileCache.load_or_compile(root, files, opts(cache_dir))

      # Corrupt every cached beam.
      for beam <- Path.wildcard(Path.join(cache_dir, "**/*.beam")) do
        File.write!(beam, "not a beam file")
      end

      assert {:ok, %{source: :compiled, modules: modules}} =
               CompileCache.load_or_compile(root, files, opts(cache_dir))

      assert module in modules
      assert module.marker() == :v1
    end

    test "compiles in memory and writes nothing when disabled", %{
      cache_dir: cache_dir,
      src_dir: src_dir
    } do
      {root, files, module} = write_extension(src_dir, ":v1")

      assert {:ok, %{modules: modules, source: :compiled}} =
               CompileCache.load_or_compile(root, files, cache_dir: cache_dir, enabled: false)

      assert module in modules
      assert module.marker() == :v1
      refute File.exists?(cache_dir)
    end

    test "returns an error for a syntax error and leaves no cache entry", %{
      cache_dir: cache_dir,
      src_dir: src_dir
    } do
      file = Path.join(src_dir, "broken.ex")
      File.write!(file, "defmodule Broken do def oops(")

      assert {:error, message} = CompileCache.load_or_compile(src_dir, [file], opts(cache_dir))
      assert is_binary(message)
      assert Path.wildcard(Path.join(cache_dir, "**/*.beam")) == []
    end

    test "returns an error when given no files", %{cache_dir: cache_dir} do
      assert {:error, _} = CompileCache.load_or_compile("/tmp/whatever", [], opts(cache_dir))
    end

    test "returns an error (no crash) when a source file is missing", %{
      cache_dir: cache_dir,
      src_dir: src_dir
    } do
      ghost = Path.join(src_dir, "ghost.ex")

      assert {:error, message} = CompileCache.load_or_compile(src_dir, [ghost], opts(cache_dir))
      assert message =~ "ghost.ex"
      assert Path.wildcard(Path.join(cache_dir, "**/*.beam")) == []
    end
  end
end
