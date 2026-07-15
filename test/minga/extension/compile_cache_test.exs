defmodule Minga.Extension.CompileCacheTest do
  # Every test starts real disposable BEAM OS processes, which must be serialized to
  # avoid the runtime's erl_child_setup EPIPE race.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.CompileCache

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "minga-ext-src-#{suffix}")
    cache = Path.join(System.tmp_dir!(), "minga-ext-cache-#{suffix}")
    owner_name = String.to_atom("compile_cache_generation_#{suffix}")
    admission_name = String.to_atom("compile_cache_admission_#{suffix}")
    admission_id = String.to_atom("compile_cache_admission_child_#{suffix}")
    persistence_key = {__MODULE__, suffix, make_ref()}
    File.mkdir_p!(root)

    _owner =
      start_supervised!(
        {ArtifactGenerationState, name: owner_name, persistence_key: persistence_key},
        id: owner_name
      )

    _admission =
      start_supervised!(
        {ArtifactAdmission, name: admission_name, state_owner: owner_name},
        id: admission_id
      )

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(cache)
      assert :ok = ArtifactGenerationState.reset_for_test(persistence_key)
    end)

    %{
      root: root,
      cache: cache,
      admission: admission_name,
      admission_id: admission_id,
      owner_name: owner_name
    }
  end

  test "isolated artifacts include direct, nested, macro, atom-targeted, runtime, and spawned modules",
       context do
    names = generated_names("Forms")
    macro_file = Path.join(context.root, "emitter.ex")
    forms_file = Path.join(context.root, "forms.ex")

    File.write!(macro_file, macro_source(names))
    File.write!(forms_file, forms_source(names))

    assert {:ok, %{modules: modules, source: :compiled}} =
             load(context, [macro_file, forms_file], :forms)

    assert Enum.sort(modules) == Enum.sort(Map.values(names))
    assert names.direct.marker() == :direct
    assert names.nested.marker() == :nested
    assert names.generated.marker() == :macro_generated
    assert names.atom_target.marker() == :atom_target
    assert names.runtime.marker() == :runtime_generated
    assert names.spawned.marker() == :spawned_generated
  end

  test "cache hits repeat complete validation and preserve the admitted generation", context do
    module = unique_module("CacheHit")
    file = write_module(context.root, module, ":v1")

    assert {:ok, %{source: :compiled, modules: [^module]}} = load(context, [file], :cache_hit)
    assert {:ok, %{source: :cache, modules: [^module]}} = load(context, [file], :cache_hit)
    assert module.marker() == :v1
  end

  test "a corrupt cache artifact recompiles through the same admission path", context do
    module = unique_module("Corrupt")
    file = write_module(context.root, module, ":good")

    assert {:ok, %{source: :compiled}} = load(context, [file], :corrupt)
    [beam] = Path.wildcard(Path.join(context.cache, "**/*.beam"))
    File.write!(beam, "not a beam")

    assert {:ok, %{source: :compiled, modules: [^module]}} = load(context, [file], :corrupt)
    assert module.marker() == :good
  end

  test "unexpected and incomplete cache contents are never loaded as a hit", context do
    module = unique_module("Completeness")
    file = write_module(context.root, module, ":complete")

    assert {:ok, %{source: :compiled}} = load(context, [file], :completeness)
    [cache_key] = Path.wildcard(Path.join(context.cache, "*/*"))
    File.write!(Path.join(cache_key, "surprise.txt"), "hostile")

    compiler = fn _files, _dir, _opts -> {:error, "recompile requested"} end

    assert {:error, "recompile requested"} =
             load(context, [file], :completeness, compiler: compiler)

    File.rm!(Path.join(cache_key, "surprise.txt"))
    [beam] = Path.wildcard(Path.join(cache_key, "*.beam"))
    File.rm!(beam)

    assert {:error, "recompile requested"} =
             load(context, [file], :completeness, compiler: compiler)
  end

  test "filename and internal module disagreement invalidates the cache", context do
    module = unique_module("Filename")
    file = write_module(context.root, module, ":filename")

    assert {:ok, %{source: :compiled}} = load(context, [file], :filename)
    [beam] = Path.wildcard(Path.join(context.cache, "**/*.beam"))
    renamed = Path.join(Path.dirname(beam), "Elixir.WrongArtifactName.beam")
    File.rename!(beam, renamed)
    compiler = fn _files, _dir, _opts -> {:error, "metadata mismatch forced compile"} end

    assert {:error, "metadata mismatch forced compile"} =
             load(context, [file], :filename, compiler: compiler)
  end

  test "bounded artifact count rejects hostile compiler output before loading", context do
    first = unique_module("LimitA")
    second = unique_module("LimitB")
    file = Path.join(context.root, "many.ex")

    File.write!(file, """
    defmodule #{inspect(first)} do
      def marker, do: :first
    end
    defmodule #{inspect(second)} do
      def marker, do: :second
    end
    """)

    assert {:error, message} = load(context, [file], :limit, max_artifacts: 1)
    assert message =~ "artifact_limit_exceeded"
    refute Code.ensure_loaded?(first)
    refute Code.ensure_loaded?(second)
  end

  test "declared atom count is rejected before decoding an oversized table", context do
    module = unique_module("AtomCount")
    file = write_module(context.root, module, ":atom_count")

    assert {:error, message} =
             load(context, [file], :atom_count, max_atoms_per_artifact: 1)

    assert message =~ "atom_limit_exceeded"
    refute Code.ensure_loaded?(module)
  end

  test "host atom headroom is audited before BEAM metadata creates module atoms", context do
    module_name = "Elixir.CompileCacheAtomAudit#{System.unique_integer([:positive])}"
    file = Path.join(context.root, "atom_audit.ex")
    File.write!(file, "defmodule #{module_name} do\n  def marker, do: :audit\nend\n")

    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end

    assert {:error, message} =
             load(context, [file], :atom_headroom,
               host_atom_reserve: :erlang.system_info(:atom_limit)
             )

    assert message =~ "host_atom_capacity_exceeded"
    assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
  end

  test "host atom capacity failure on a cache hit is terminal rather than a cache miss",
       context do
    module = unique_module("CachedAtomCapacity")
    file = write_module(context.root, module, ":cached_atom_capacity")
    assert {:ok, %{source: :compiled}} = load(context, [file], :cached_atom_capacity)
    parent = self()

    compiler = fn _files, _staging, _opts ->
      send(parent, :atom_capacity_compiler_called)
      {:error, "must not recompile for host capacity"}
    end

    assert {:error, message} =
             load(context, [file], :cached_atom_capacity,
               host_atom_reserve: :erlang.system_info(:atom_limit),
               compiler: compiler
             )

    assert message =~ "host_atom_capacity_exceeded"
    refute_received :atom_capacity_compiler_called
  end

  test "ordinary non-Elixir internal names are rejected before host loading", context do
    invalid = String.to_atom("artifact_internal_#{System.unique_integer([:positive])}")
    file = Path.join(context.root, "internal.ex")

    File.write!(file, """
    Module.create(#{inspect(invalid)}, quote(do: def(marker, do: :invalid)), Macro.Env.location(__ENV__))
    """)

    assert {:error, message} = load(context, [file], :internal)
    assert message =~ "invalid_module_name"
    refute :code.is_loaded(invalid)
  end

  test "symlinked, non-regular, and symlink-directory cache artifacts force safe recompilation",
       context do
    module = unique_module("CacheTypes")
    file = write_module(context.root, module, ":cache_types")

    assert {:ok, %{source: :compiled}} = load(context, [file], :cache_types)
    cache_key = cache_key_dir(context.cache)
    [beam] = Path.wildcard(Path.join(cache_key, "*.beam"))
    external = Path.join(context.root, "external.beam")
    File.cp!(beam, external)
    File.rm!(beam)
    File.ln_s!(external, beam)

    compiler = fn _files, _dir, _opts -> {:error, "symlink cache forced compile"} end

    assert {:error, "symlink cache forced compile"} =
             load(context, [file], :cache_types, compiler: compiler)

    File.rm!(beam)
    File.mkdir!(beam)

    compiler = fn _files, _dir, _opts -> {:error, "directory cache forced compile"} end

    assert {:error, "directory cache forced compile"} =
             load(context, [file], :cache_types, compiler: compiler)
  end

  test "a symlinked cache manifest is never followed", context do
    module = unique_module("ManifestSymlink")
    file = write_module(context.root, module, ":manifest_symlink")

    assert {:ok, %{source: :compiled}} = load(context, [file], :manifest_symlink)
    cache_key = cache_key_dir(context.cache)
    manifest = Path.join(cache_key, "inventory.etf")
    external = Path.join(context.root, "external-inventory.etf")
    File.cp!(manifest, external)
    File.rm!(manifest)
    File.ln_s!(external, manifest)

    compiler = fn _files, _dir, _opts -> {:error, "manifest symlink forced compile"} end

    assert {:error, "manifest symlink forced compile"} =
             load(context, [file], :manifest_symlink, compiler: compiler)
  end

  test "an unsafe symlinked extension cache root is terminal without invoking the compiler",
       context do
    module = unique_module("UnsafeCacheRoot")
    file = write_module(context.root, module, ":unsafe_cache_root")

    assert {:ok, %{source: :compiled}} = load(context, [file], :unsafe_cache_root)
    [ext_dir] = Path.wildcard(Path.join(context.cache, "*"))
    external = Path.join(context.root, "external-cache")
    File.mkdir_p!(external)
    File.rm_rf!(ext_dir)
    File.ln_s!(external, ext_dir)
    parent = self()

    compiler = fn _files, _dir, _opts ->
      send(parent, :unsafe_compiler_called)
      {:error, "must not compile through a symlinked cache root"}
    end

    assert {:error, message} =
             load(context, [file], :unsafe_cache_root, compiler: compiler)

    assert message =~ "unsafe_extension_cache_directory"
    refute_received :unsafe_compiler_called
  end

  test "hostile BEAM metadata is rejected before admission or loading", context do
    module = unique_module("HostileMetadata")
    file = write_module(context.root, module, ":hostile_metadata")

    compiler = fn files, staging, opts ->
      with {:ok, report} <- Minga.Extension.IsolatedCompiler.compile(files, staging, opts) do
        [beam] = Path.wildcard(Path.join(staging, "*.beam"))
        File.write!(beam, corrupt_beam_chunk(File.read!(beam), "Attr"))
        {:ok, report}
      end
    end

    assert {:error, message} =
             load(context, [file], :hostile_metadata, compiler: compiler)

    assert message =~ "invalid_beam"
    refute Code.ensure_loaded?(module)
  end

  test "declared literal-table decompression is bounded in the validator peer", context do
    module = unique_module("LiteralBomb")
    file = Path.join(context.root, "literal_bomb.ex")

    File.write!(
      file,
      "defmodule #{inspect(module)}, do: def(marker, do: #{inspect(Enum.to_list(1..100))})"
    )

    compiler = fn files, staging, opts ->
      with {:ok, report} <- Minga.Extension.IsolatedCompiler.compile(files, staging, opts) do
        [beam] = Path.wildcard(Path.join(staging, "*.beam"))
        File.write!(beam, replace_chunk_prefix(File.read!(beam), "LitT", <<4_294_967_295::32>>))
        {:ok, report}
      end
    end

    assert {:error, message} =
             load(context, [file], :literal_bomb,
               compiler: compiler,
               max_decompressed_bytes: 1_024
             )

    assert message =~ "decompressed_limit_exceeded"
    refute Code.ensure_loaded?(module)
  end

  test "valid compressed Attr and LitT ETF with excess unique atoms is rejected structurally",
       context do
    Enum.each(["Attr", "LitT"], fn chunk_id ->
      module = unique_module("CompressedAtoms#{chunk_id}")
      file = write_module(context.root, module, ":compressed_atoms")
      names = Enum.map(1..100, &"validator_unique_#{chunk_id}_#{&1}")
      encoded_atoms = etf_atom_list(names)

      replacement =
        case chunk_id do
          "Attr" -> compressed_etf(encoded_atoms)
          "LitT" -> compressed_literal_table(encoded_atoms)
        end

      compiler = fn files, staging, opts ->
        with {:ok, report} <- Minga.Extension.IsolatedCompiler.compile(files, staging, opts) do
          [beam] = Path.wildcard(Path.join(staging, "*.beam"))
          File.write!(beam, replace_beam_chunk(File.read!(beam), chunk_id, replacement))
          {:ok, report}
        end
      end

      assert {:error, message} =
               load(context, [file], unique_module("CompressedAtomSource"),
                 compiler: compiler,
                 max_atoms_per_artifact: 64
               )

      assert message =~ "atom_limit_exceeded"
      refute Code.ensure_loaded?(module)
    end)
  end

  test "compressed ETF actual size is bounded and must equal its declaration", context do
    cases = [
      {:bomb, 1_024, String.duplicate("x", 100_000), 64 * 1_024, "decompressed_limit_exceeded"},
      {:mismatch, 100_001, String.duplicate("y", 100_000), 128 * 1_024,
       "decompressed_size_mismatch"}
    ]

    Enum.each(cases, fn {kind, declared, payload, max_decompressed, expected} ->
      module = unique_module("CompressedSize#{kind}")
      file = write_module(context.root, module, ":compressed_size")
      encoded = <<109, byte_size(payload)::unsigned-big-32, payload::binary>>
      replacement = compressed_etf(encoded, declared)

      compiler = fn files, staging, opts ->
        with {:ok, report} <- Minga.Extension.IsolatedCompiler.compile(files, staging, opts) do
          [beam] = Path.wildcard(Path.join(staging, "*.beam"))
          File.write!(beam, replace_beam_chunk(File.read!(beam), "Attr", replacement))
          {:ok, report}
        end
      end

      assert {:error, message} =
               load(context, [file], unique_module("CompressedSizeSource"),
                 compiler: compiler,
                 max_decompressed_bytes: max_decompressed
               )

      assert message =~ expected
      refute Code.ensure_loaded?(module)
    end)
  end

  test "compressed ETF rejects truncated streams and bytes after the zlib boundary", context do
    encoded = <<106>>
    valid = compressed_etf(encoded)

    cases = [
      {:truncated, binary_part(valid, 0, byte_size(valid) - 2), "malformed_compressed_etf"},
      {:trailing, valid <> "junk", "compressed_etf_trailing_bytes"}
    ]

    Enum.each(cases, fn {kind, replacement, expected} ->
      module = unique_module("CompressedBoundary#{kind}")
      file = write_module(context.root, module, ":compressed_boundary")

      compiler = fn files, staging, opts ->
        with {:ok, report} <- Minga.Extension.IsolatedCompiler.compile(files, staging, opts) do
          [beam] = Path.wildcard(Path.join(staging, "*.beam"))
          File.write!(beam, replace_beam_chunk(File.read!(beam), "Attr", replacement))
          {:ok, report}
        end
      end

      assert {:error, message} =
               load(context, [file], unique_module("CompressedBoundarySource"),
                 compiler: compiler
               )

      assert message =~ expected
      refute Code.ensure_loaded?(module)
    end)
  end

  test "unexpected staging output is rejected before admission or promotion", context do
    module = unique_module("UnexpectedStage")
    file = write_module(context.root, module, ":unexpected_stage")

    compiler = fn files, staging, opts ->
      with {:ok, report} <- Minga.Extension.IsolatedCompiler.compile(files, staging, opts) do
        File.write!(Path.join(staging, "unexpected.txt"), "hostile")
        {:ok, report}
      end
    end

    assert {:error, message} =
             load(context, [file], :unexpected_stage, compiler: compiler)

    assert message =~ "unexpected_artifact_entry"
    refute Code.ensure_loaded?(module)
    assert Path.wildcard(Path.join(context.cache, "**/*.beam")) == []
  end

  test "host module collision is terminal before cache or host code changes", context do
    file = Path.join(context.root, "collision.ex")
    File.write!(file, "defmodule Minga.Buffer do\n  def hostile, do: true\nend\n")
    before = :code.which(Minga.Buffer)

    assert {:error, message} = load(context, [file], :host_collision)
    assert message =~ "module_conflicts_with_host"
    assert :code.which(Minga.Buffer) == before
    refute function_exported?(Minga.Buffer, :hostile, 0)
    assert Path.wildcard(Path.join(context.cache, "**/*.beam")) == []
  end

  test "trusted application artifacts are adopted atomically with ordinary outputs", context do
    generated = unique_module("TrustedGenerated")
    file = Path.join(context.root, "trusted.ex")

    File.write!(file, """
    defmodule Minga.Buffer do
      def hostile, do: true
    end

    defmodule #{inspect(generated)} do
      def marker, do: :trusted_generated
    end
    """)

    before = :code.which(Minga.Buffer)

    assert {:ok, %{modules: modules}} =
             load(context, [file], :trusted_application, trusted_application: :minga)

    assert Enum.sort(modules) == Enum.sort([Minga.Buffer, generated])
    assert generated.marker() == :trusted_generated
    assert :code.which(Minga.Buffer) == before
    refute function_exported?(Minga.Buffer, :hostile, 0)
  end

  test "cross-extension ownership conflict on a valid cache hit is terminal without recompiling",
       context do
    module = unique_module("Owner")
    file = write_module(context.root, module, ":owner")

    assert {:ok, %{source: :compiled}} = load(context, [file], :first_owner)
    parent = self()

    compiler = fn _files, _dir, _opts ->
      send(parent, :compiler_called)
      {:error, "must not compile"}
    end

    assert {:error, message} = load(context, [file], :second_owner, compiler: compiler)
    assert message =~ "module_owned_by_source"
    refute_received :compiler_called
    assert module.marker() == :owner
  end

  test "partial load failure unloads only this attempt and releases only its claims", context do
    first = unique_module("PartialA")
    second = unique_module("PartialB")
    file = Path.join(context.root, "partial.ex")

    File.write!(file, """
    defmodule #{inspect(first)} do
      def marker, do: :first
    end
    defmodule #{inspect(second)} do
      def marker, do: :second
    end
    """)

    loader = fn module, path, binary ->
      if module == second,
        do: {:error, :injected_failure},
        else: :code.load_binary(module, path, binary)
    end

    assert {:error, message} = load(context, [file], :partial, artifact_loader: loader)
    assert message =~ "artifact_load_failed"
    refute Code.ensure_loaded?(first)
    refute Code.ensure_loaded?(second)

    source = {:extension, source_name(:partial)}
    assert :error = ArtifactAdmission.source_modules(source, server: context.admission)

    assert {:ok, %{modules: modules}} = load(context, [file], :partial)
    assert Enum.sort(modules) == Enum.sort([first, second])
  end

  test "failed changed generation preserves the prior good cache and loaded code", context do
    module = unique_module("PriorGood")
    file = write_module(context.root, module, ":v1")

    assert {:ok, %{source: :compiled}} = load(context, [file], :prior_good)
    old_beams = Path.wildcard(Path.join(context.cache, "**/*.beam"))
    assert old_beams != []

    write_module(context.root, module, ":v2")

    assert {:error, message} = load(context, [file], :prior_good)
    assert message =~ "source_artifact_changed"
    assert module.marker() == :v1
    assert Path.wildcard(Path.join(context.cache, "**/*.beam")) == old_beams
  end

  test "load failure preserves a previous good cache key and removes the failed candidate",
       context do
    first = unique_module("PreviousKey")
    second = unique_module("FailedCandidate")
    file = write_module(context.root, first, ":previous_key")

    assert {:ok, %{source: :compiled}} = load(context, [file], :previous_key)
    previous_beams = Path.wildcard(Path.join(context.cache, "**/*.beam"))
    assert [_beam] = previous_beams

    write_module(context.root, second, ":failed_candidate")
    loader = fn _module, _path, _binary -> {:error, :injected_candidate_failure} end

    assert {:error, message} =
             load(context, [file], :failed_candidate, artifact_loader: loader)

    assert message =~ "artifact_load_failed"
    assert Path.wildcard(Path.join(context.cache, "**/*.beam")) == previous_beams
    assert first.marker() == :previous_key
    refute Code.ensure_loaded?(second)
  end

  test "cached promotion rolls back when admission stops before commit", context do
    assert_commit_failure_rollback(context, :cached, :unavailable)
  end

  test "cached promotion rolls back when the generation fails before commit", context do
    assert_commit_failure_rollback(context, :cached, :generation_failed)
  end

  test "cache-disabled load rolls back when admission stops before commit", context do
    assert_commit_failure_rollback(context, :disabled, :unavailable)
  end

  test "cache-disabled load rolls back when the generation fails before commit", context do
    assert_commit_failure_rollback(context, :disabled, :generation_failed)
  end

  test "cache-disabled compilation is still isolated and creates no artifacts", context do
    module = unique_module("NoCache")
    file = Path.join(context.root, "pid.ex")

    File.write!(file, """
    defmodule #{inspect(module)} do
      @compiler_os_pid System.pid()
      def compiler_os_pid, do: @compiler_os_pid
    end
    """)

    assert {:ok, %{modules: [^module], source: :compiled}} =
             load(context, [file], :no_cache, enabled: false)

    refute module.compiler_os_pid() == System.pid()
    refute File.exists?(context.cache)
  end

  test "compiler timeout kills the standalone BEAM process", context do
    module = unique_module("CompilerTimeout")
    file = Path.join(context.root, "timeout.ex")
    pid_file = Path.join(context.root, "compiler.pid")

    File.write!(file, """
    File.write!(#{inspect(pid_file)}, System.pid())
    receive do
    after
      :infinity -> :ok
    end
    defmodule #{inspect(module)}, do: def(marker, do: :never_loaded)
    """)

    assert {:error, "isolated compiler timed out"} =
             load(context, [file], :compiler_timeout,
               enabled: false,
               subprocess_timeout: 1_000
             )

    pid = File.read!(pid_file)
    assert await_os_pid_dead(pid, 1_000)
    refute Code.ensure_loaded?(module)
  end

  test "compiler output limit kills a noisy blocked worker and removes every temporary artifact",
       context do
    module = unique_module("CompilerOutputLimit")
    file = Path.join(context.root, "output_limit.ex")
    pid_file = Path.join(context.root, "output-limit.pid")
    snapshot_root = Path.join(context.root, "output-limit-snapshots")
    File.mkdir_p!(snapshot_root)

    File.write!(file, """
    File.write!(#{inspect(pid_file)}, System.pid())
    IO.write(:stdio, String.duplicate("x", 80 * 1024))
    receive do
    after
      :infinity -> :ok
    end
    defmodule #{inspect(module)}, do: def(marker, do: :never_loaded)
    """)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, "isolated compiler output exceeded limit"} =
             load(context, [file], :compiler_output_limit,
               snapshot_root: snapshot_root,
               subprocess_timeout: 15_000
             )

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed < 5_000
    pid = File.read!(pid_file)
    assert await_os_pid_dead(pid, 1_000)
    refute Code.ensure_loaded?(module)
    assert File.ls!(snapshot_root) == []
    assert Path.wildcard(Path.join(context.cache, "**/*.beam")) == []
    assert Path.wildcard(Path.join(context.cache, "**/manifest.json")) == []
    assert Path.wildcard(Path.join(context.cache, "**/.compiler-report-*")) == []
    assert Path.wildcard(Path.join(context.cache, "**/.staging-*")) == []
  end

  test "missing source files and absent source identity fail without artifacts", context do
    missing = Path.join(context.root, "missing.ex")

    assert {:error, message} =
             CompileCache.load_or_compile(context.root, [missing],
               cache_dir: context.cache,
               source: {:extension, :missing},
               artifact_admission: context.admission
             )

    assert message =~ "missing.ex"

    file = write_module(context.root, unique_module("NoSource"), ":none")

    assert {:error, "extension artifact source is required"} =
             CompileCache.load_or_compile(context.root, [file], cache_dir: context.cache)
  end

  test "standalone compiler control messages atoms and oversized diagnostics never cross into the host",
       context do
    module = unique_module("SanitizedReport")
    atom_name = "standalone_report_atom_#{System.unique_integer([:positive])}"
    file = Path.join(context.root, "diagnostics.ex")

    warnings =
      Enum.map_join(1..20, "\n", fn index ->
        "IO.warn(\"#{String.duplicate("w", 600)}#{index}\")"
      end)

    File.write!(file, """
    child_atom = String.to_atom(#{inspect(atom_name)})
    group_leader = Process.group_leader()
    send(group_leader, {:fake_peer_control, child_atom, self(), make_ref()})
    send(group_leader, {:io_request, self(), make_ref(), {:put_chars, :unicode, "child noise"}})
    IO.warn(inspect(child_atom))
    #{warnings}
    defmodule #{inspect(module)}, do: def(marker, do: :sanitized)
    """)

    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

    _captured =
      capture_io(:stderr, fn ->
        send(self(), {:sanitized_result, load(context, [file], :sanitized_report)})
      end)

    assert_receive {:sanitized_result, {:ok, %{modules: [^module], diagnostics: diagnostics}}}

    assert Enum.count_until(diagnostics, 129) <= 128

    assert Enum.all?(diagnostics, fn diagnostic ->
             is_binary(diagnostic.message) and byte_size(diagnostic.message) <= 4_096
           end)

    assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end
    refute_received {:fake_peer_control, _atom, _pid, _ref}
    refute_received {:io_request, _pid, _ref, _request}
  end

  test "real bundled Git Porcelain inventory is adopted without replacing loaded code", context do
    root = Path.expand("extensions/git_porcelain")
    files = root |> Path.join("lib/**/*.ex") |> Path.wildcard() |> Enum.sort()

    assert {:ok, application_modules, _diagnostics} =
             Kernel.ParallelCompiler.compile(files, return_diagnostics: true)

    application_spec =
      {:application, :minga_git_porcelain,
       [vsn: ~c"test", description: ~c"test", modules: application_modules]}

    assert :ok = :application.load(application_spec)

    on_exit(fn ->
      Application.unload(:minga_git_porcelain)

      Enum.each(application_modules, fn module ->
        :code.purge(module)
        :code.delete(module)
      end)
    end)

    source = {:extension, source_name(:bundled_git_porcelain)}
    before = Map.new(application_modules, &{&1, :code.which(&1)})

    assert {:ok, %{modules: modules}} =
             CompileCache.load_or_compile(root, files,
               cache_dir: context.cache,
               source: source,
               artifact_admission: context.admission,
               trusted_application: :minga_git_porcelain
             )

    assert Enum.sort(modules) == Enum.sort(application_modules)
    assert Map.new(application_modules, &{&1, :code.which(&1)}) == before
    assert {:ok, admitted} = ArtifactAdmission.source_modules(source, server: context.admission)
    assert Enum.sort(admitted) == Enum.sort(application_modules)
  end

  test "source count and byte limits reject input before compiler transfer", context do
    first = write_module(context.root, unique_module("SourceLimitA"), ":a")
    second = Path.join(context.root, "second.ex")

    File.write!(
      second,
      "defmodule #{inspect(unique_module("SourceLimitB"))}, do: def(marker, do: :b)"
    )

    parent = self()

    compiler = fn _files, _staging, _opts ->
      send(parent, :source_limit_compiler_called)
      {:error, "compiler must not run"}
    end

    cases = [
      {[first, second], [max_source_files: 1], "source_file_limit_exceeded"},
      {[first], [max_source_file_bytes: 1], "file_too_large"},
      {[first, second], [max_source_file_bytes: 1_024, max_source_total_bytes: 10],
       "source_total_bytes_exceeded"}
    ]

    Enum.each(cases, fn {files, limits, expected} ->
      assert {:error, message} =
               load(
                 context,
                 files,
                 unique_module("SourceLimitCase"),
                 [compiler: compiler] ++ limits
               )

      assert message =~ expected
      refute_received :source_limit_compiler_called
    end)
  end

  test "artifact and manifest limits are enforced for fresh staging and cache validation",
       context do
    module = unique_module("LimitTable")
    file = write_module(context.root, module, ":limits")
    assert {:ok, %{source: :compiled}} = load(context, [file], :limit_table_seed)
    cache_dir = cache_key_dir(context.cache)

    cases = [
      {:max_artifact_bytes, 1, "artifact_too_large"},
      {:max_total_bytes, 1, "total_artifact_bytes_exceeded"},
      {:max_atoms_per_artifact, 1, "atom_limit_exceeded"},
      {:max_total_atoms, 1, "total_atom_limit_exceeded"},
      {:max_atom_name_bytes, 5, "invalid_atom_name"},
      {:max_manifest_bytes, 1, "too_large"}
    ]

    Enum.each(cases, fn {option, value, expected} ->
      assert {:error, reason} =
               Minga.Extension.ArtifactInventory.validate_cache(cache_dir, [{option, value}])

      assert inspect(reason) =~ expected
    end)

    fresh_module = unique_module("FreshLimit")
    fresh_file = write_module(context.root, fresh_module, ":fresh_limit")

    Enum.each(cases, fn {option, value, expected} ->
      assert {:error, message} =
               load(context, [fresh_file], unique_module("FreshLimitCase"), [{option, value}])

      assert message =~ expected
    end)
  end

  test "the cache key and compiler both use the immutable source snapshot", context do
    module = unique_module("Snapshot")
    file = write_module(context.root, module, ":v1")

    compiler = fn snapshot_files, staging, opts ->
      File.write!(file, "defmodule #{inspect(module)} do\n  def marker, do: :v2\nend\n")
      Minga.Extension.IsolatedCompiler.compile(snapshot_files, staging, opts)
    end

    assert {:ok, %{modules: [^module]}} =
             load(context, [file], :snapshot, compiler: compiler)

    assert module.marker() == :v1
    assert {:error, changed} = load(context, [file], :snapshot)
    assert changed =~ "source_artifact_changed"
    assert module.marker() == :v1
  end

  test "source snapshots are removed when isolated compilation exits on timeout", context do
    module = unique_module("SnapshotTimeout")
    file = write_module(context.root, module, ":timeout")
    snapshot_root = Path.join(context.root, "snapshots")
    File.mkdir_p!(snapshot_root)

    compiler = fn snapshot_files, _staging, _opts ->
      assert Enum.all?(snapshot_files, &String.starts_with?(&1, snapshot_root))
      exit(:timeout)
    end

    assert {:error, message} =
             load(context, [file], :snapshot_timeout,
               compiler: compiler,
               snapshot_root: snapshot_root
             )

    assert message =~ "preparation failed"
    assert File.ls!(snapshot_root) == []
    refute Code.ensure_loaded?(module)
  end

  test "incomplete fresh compiler output leaves no claim, load, or cache", context do
    first = unique_module("IncompleteA")
    second = unique_module("IncompleteB")
    file = Path.join(context.root, "incomplete.ex")

    File.write!(file, """
    defmodule #{inspect(first)}, do: def(marker, do: :first)
    defmodule #{inspect(second)}, do: def(marker, do: :second)
    """)

    compiler = fn files, staging, opts ->
      with {:ok, report} <- Minga.Extension.IsolatedCompiler.compile(files, staging, opts) do
        File.rm!(Path.join(staging, Atom.to_string(second) <> ".beam"))
        {:ok, report}
      end
    end

    assert {:error, message} = load(context, [file], :incomplete_fresh, compiler: compiler)
    assert message =~ "incomplete_compiler_output"
    refute Code.ensure_loaded?(first)
    refute Code.ensure_loaded?(second)

    assert :error =
             ArtifactAdmission.source_modules({:extension, source_name(:incomplete_fresh)},
               server: context.admission
             )

    assert Path.wildcard(Path.join(context.cache, "**/*.beam")) == []
  end

  test "duplicate compiler emissions are rejected before artifact overwrite", context do
    module = unique_module("Duplicate")
    first = Path.join(context.root, "duplicate_a.ex")
    second = Path.join(context.root, "duplicate_b.ex")
    File.write!(first, "defmodule #{inspect(module)}, do: def(marker, do: :first)")
    File.write!(second, "defmodule #{inspect(module)}, do: def(marker, do: :second)")

    assert {:error, message} = load(context, [first, second], :duplicate_emission)
    assert message =~ "failed"
    refute Code.ensure_loaded?(module)
    assert Path.wildcard(Path.join(context.cache, "**/*.beam")) == []
  end

  test "duplicate runtime emissions are rejected before either artifact is admitted", context do
    module = unique_module("DuplicateRuntime")
    file = Path.join(context.root, "duplicate_runtime.ex")

    first = "defmodule #{inspect(module)}, do: def(marker, do: :first)"
    second = "defmodule #{inspect(module)}, do: def(marker, do: :second)"

    File.write!(file, """
    Code.compile_string(#{inspect(first)})
    Code.compile_string(#{inspect(second)})
    """)

    assert {:error, message} = load(context, [file], :duplicate_runtime_emission)
    assert message =~ "failed"
    refute Code.ensure_loaded?(module)

    assert :error =
             ArtifactAdmission.source_modules(
               {:extension, source_name(:duplicate_runtime_emission)},
               server: context.admission
             )
  end

  test "partial-load rollback preserves unrelated loaded code and committed claim", context do
    unrelated = unique_module("Unrelated")
    unrelated_source = {:extension, source_name(:unrelated)}
    fingerprint = :crypto.hash(:sha256, "unrelated")

    assert {:ok, claim} =
             ArtifactAdmission.claim_source_modules(
               unrelated_source,
               [unrelated],
               fingerprint,
               server: context.admission
             )

    Module.create(unrelated, quote(do: def(marker, do: :unrelated)), Macro.Env.location(__ENV__))
    assert :ok = ArtifactAdmission.commit_attempt(claim, server: context.admission)

    first = unique_module("RollbackA")
    second = unique_module("RollbackB")
    file = Path.join(context.root, "rollback.ex")

    File.write!(file, """
    defmodule #{inspect(first)}, do: def(marker, do: :first)
    defmodule #{inspect(second)}, do: def(marker, do: :second)
    """)

    loader = fn module, path, binary ->
      if module == second, do: {:error, :stop}, else: :code.load_binary(module, path, binary)
    end

    assert {:error, _message} =
             load(context, [file], :rollback_isolation, artifact_loader: loader)

    assert unrelated.marker() == :unrelated
    refute Code.ensure_loaded?(first)
    refute Code.ensure_loaded?(second)

    assert {:ok, [^unrelated]} =
             ArtifactAdmission.source_modules(unrelated_source, server: context.admission)

    failed_source = {:extension, source_name(:rollback_isolation)}
    assert :error = ArtifactAdmission.source_modules(failed_source, server: context.admission)

    replacement_source = {:extension, source_name(:rollback_replacement)}
    replacement_fingerprint = :crypto.hash(:sha256, "rollback-replacement")

    assert {:ok, replacement_claim} =
             ArtifactAdmission.claim_source_modules(
               replacement_source,
               [first, second],
               replacement_fingerprint,
               server: context.admission
             )

    assert :ok = ArtifactAdmission.abort_attempt(replacement_claim, server: context.admission)
  end

  defp assert_commit_failure_rollback(context, cache_mode, failure_mode) do
    prior = unique_module("CommitPrior")
    attempt = unique_module("CommitAttempt")
    file = write_module(context.root, prior, ":prior")
    prior_suffix = String.to_atom("#{cache_mode}_#{failure_mode}_prior")
    attempt_suffix = String.to_atom("#{cache_mode}_#{failure_mode}_attempt")
    prior_source = {:extension, source_name(prior_suffix)}
    attempt_source = {:extension, source_name(attempt_suffix)}

    assert {:ok, %{source: :compiled, modules: [^prior]}} =
             load(context, [file], prior_suffix)

    prior_beams = Path.wildcard(Path.join(context.cache, "**/*.beam"))
    assert prior_beams != []
    write_module(context.root, attempt, ":attempt")

    loader = fn module, path, bytecode ->
      result = :code.load_binary(module, path, bytecode)
      force_commit_failure(context, failure_mode)
      result
    end

    cache_opts = if cache_mode == :disabled, do: [enabled: false], else: []

    assert {:error, message} =
             load(
               context,
               [file],
               attempt_suffix,
               [artifact_loader: loader] ++ cache_opts
             )

    assert message =~ "artifact_admission_commit_failed"
    assert_explicit_commit_failure(message, failure_mode)
    admission = ensure_admission_available(context, failure_mode)

    assert prior.marker() == :prior
    refute Code.ensure_loaded?(attempt)
    assert Path.wildcard(Path.join(context.cache, "**/*.beam")) == prior_beams
    assert {:ok, [^prior]} = ArtifactAdmission.source_modules(prior_source, server: admission)
    assert {:ok, [^attempt]} = ArtifactAdmission.source_modules(attempt_source, server: admission)
    assert :sys.get_state(admission).failed?
  end

  defp force_commit_failure(context, :unavailable) do
    stop_supervised!(context.admission_id)
  end

  defp force_commit_failure(context, :generation_failed) do
    admission = Process.whereis(context.admission)
    monitor = Process.monitor(admission)
    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^admission, :killed}, 1_000
    _restarted = await_admission_restart(context.admission, admission, 1_000)
    :ok
  end

  defp ensure_admission_available(context, :unavailable) do
    start_supervised!(
      {ArtifactAdmission, name: context.admission, state_owner: context.owner_name},
      id: context.admission_id
    )
  end

  defp ensure_admission_available(context, :generation_failed),
    do: Process.whereis(context.admission)

  defp assert_explicit_commit_failure(message, :unavailable),
    do: assert(message =~ "artifact_admission_unavailable")

  defp assert_explicit_commit_failure(message, :generation_failed),
    do: assert(message =~ "generation_failed")

  defp await_admission_restart(name, old_pid, remaining) when remaining > 0 do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _other ->
        receive do
        after
          10 -> await_admission_restart(name, old_pid, remaining - 10)
        end
    end
  end

  defp await_admission_restart(name, _old_pid, 0),
    do: flunk("#{inspect(name)} did not restart")

  defp await_os_pid_dead(pid, remaining) when remaining > 0 do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, status} when status != 0 ->
        true

      {_output, 0} ->
        receive do
        after
          5 -> await_os_pid_dead(pid, remaining - 5)
        end
    end
  end

  defp await_os_pid_dead(_pid, 0), do: false

  defp load(context, files, source_suffix, extra \\ []) do
    CompileCache.load_or_compile(
      context.root,
      files,
      [
        cache_dir: context.cache,
        source: {:extension, source_name(source_suffix)},
        artifact_admission: context.admission
      ] ++ extra
    )
  end

  defp cache_key_dir(cache) do
    [cache_key] = Path.wildcard(Path.join(cache, "*/*"))
    cache_key
  end

  defp corrupt_beam_chunk(<<"FOR1", size::unsigned-big-32, "BEAM", chunks::binary>>, id) do
    <<"FOR1", size::unsigned-big-32, "BEAM", corrupt_chunk_data(chunks, id)::binary>>
  end

  defp corrupt_chunk_data(<<id::binary-size(4), size::unsigned-big-32, rest::binary>>, id) do
    padding = rem(4 - rem(size, 4), 4)
    <<_data::binary-size(^size), padding_data::binary-size(^padding), tail::binary>> = rest
    <<id::binary, size::unsigned-big-32, 0::size(size * 8), padding_data::binary, tail::binary>>
  end

  defp corrupt_chunk_data(<<chunk_id::binary-size(4), size::unsigned-big-32, rest::binary>>, id) do
    padding = rem(4 - rem(size, 4), 4)
    chunk_size = size + padding
    <<chunk_data::binary-size(^chunk_size), tail::binary>> = rest

    <<chunk_id::binary, size::unsigned-big-32, chunk_data::binary,
      corrupt_chunk_data(tail, id)::binary>>
  end

  defp replace_beam_chunk(<<"FOR1", _size::unsigned-big-32, "BEAM", chunks::binary>>, id, data) do
    replaced = replace_beam_chunk_data(chunks, id, data)
    <<"FOR1", byte_size(replaced) + 4::unsigned-big-32, "BEAM", replaced::binary>>
  end

  defp replace_beam_chunk_data(
         <<id::binary-size(4), size::unsigned-big-32, rest::binary>>,
         id,
         data
       ) do
    padding = rem(4 - rem(size, 4), 4)
    <<_old::binary-size(^size), _old_padding::binary-size(^padding), tail::binary>> = rest
    new_padding = rem(4 - rem(byte_size(data), 4), 4)

    <<id::binary, byte_size(data)::unsigned-big-32, data::binary, 0::size(new_padding * 8),
      tail::binary>>
  end

  defp replace_beam_chunk_data(
         <<chunk_id::binary-size(4), size::unsigned-big-32, rest::binary>>,
         id,
         data
       ) do
    padding = rem(4 - rem(size, 4), 4)
    chunk_size = size + padding
    <<chunk_data::binary-size(^chunk_size), tail::binary>> = rest

    <<chunk_id::binary, size::unsigned-big-32, chunk_data::binary,
      replace_beam_chunk_data(tail, id, data)::binary>>
  end

  defp etf_atom_list(names) do
    atoms = Enum.map(names, fn name -> <<119, byte_size(name), name::binary>> end)
    IO.iodata_to_binary([<<108, length(names)::unsigned-big-32>>, atoms, <<106>>])
  end

  defp compressed_etf(term, declared \\ nil) do
    compressed = :zlib.compress(term)
    declared = declared || byte_size(term)
    <<131, 80, declared::unsigned-big-32, compressed::binary>>
  end

  defp compressed_literal_table(term) do
    external = <<131, term::binary>>
    inflated = <<1::unsigned-big-32, byte_size(external)::unsigned-big-32, external::binary>>
    compressed = :zlib.compress(inflated)
    <<byte_size(inflated)::unsigned-big-32, compressed::binary>>
  end

  defp replace_chunk_prefix(<<"FOR1", size::unsigned-big-32, "BEAM", chunks::binary>>, id, prefix) do
    <<"FOR1", size::unsigned-big-32, "BEAM",
      replace_chunk_prefix_data(chunks, id, prefix)::binary>>
  end

  defp replace_chunk_prefix_data(
         <<id::binary-size(4), size::unsigned-big-32, rest::binary>>,
         id,
         prefix
       ) do
    prefix_size = byte_size(prefix)
    <<_old::binary-size(^prefix_size), tail::binary>> = rest
    <<id::binary, size::unsigned-big-32, prefix::binary, tail::binary>>
  end

  defp replace_chunk_prefix_data(
         <<chunk_id::binary-size(4), size::unsigned-big-32, rest::binary>>,
         id,
         prefix
       ) do
    padding = rem(4 - rem(size, 4), 4)
    chunk_size = size + padding
    <<chunk_data::binary-size(^chunk_size), tail::binary>> = rest

    <<chunk_id::binary, size::unsigned-big-32, chunk_data::binary,
      replace_chunk_prefix_data(tail, id, prefix)::binary>>
  end

  defp source_name(suffix), do: String.to_atom("compile_cache_#{suffix}")

  defp unique_module(suffix),
    do: Module.concat(["CompileCache#{suffix}#{System.unique_integer([:positive])}"])

  defp write_module(root, module, marker) do
    file = Path.join(root, "extension.ex")
    File.write!(file, "defmodule #{inspect(module)} do\n  def marker, do: #{marker}\nend\n")
    file
  end

  defp generated_names(prefix) do
    unique = System.unique_integer([:positive])
    base = "CompileCache#{prefix}#{unique}"

    %{
      macro: Module.concat([base, "Emitter"]),
      direct: Module.concat([base, "Direct"]),
      outer: Module.concat([base, "Outer"]),
      nested: Module.concat([base, "Outer", "Nested"]),
      generated: Module.concat([base, "Generated"]),
      atom_target: Module.concat([base, "AtomTarget"]),
      runtime: Module.concat([base, "Runtime"]),
      spawned: Module.concat([base, "Spawned"])
    }
  end

  defp macro_source(names) do
    """
    defmodule #{inspect(names.macro)} do
      defmacro emit(module) do
        quote do
          defmodule unquote(module) do
            def marker, do: :macro_generated
          end
        end
      end
    end
    """
  end

  defp forms_source(names) do
    atom_target = inspect(Atom.to_string(names.atom_target))

    """
    require #{inspect(names.macro)}
    #{inspect(names.macro)}.emit(#{inspect(names.generated)})

    defmodule #{inspect(names.direct)} do
      def marker, do: :direct
    end

    defmodule #{inspect(names.outer)} do
      defmodule Nested do
        def marker, do: :nested
      end
    end

    defmodule :#{atom_target} do
      def marker, do: :atom_target
    end

    Module.create(
      #{inspect(names.runtime)},
      quote(do: def(marker, do: :runtime_generated)),
      Macro.Env.location(__ENV__)
    )

    spawn(fn ->
      receive do
      after
        50 ->
          Module.create(
            #{inspect(names.spawned)},
            quote(do: def(marker, do: :spawned_generated)),
            Macro.Env.location(__ENV__)
          )
      end
    end)
    """
  end
end
