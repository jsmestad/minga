Code.require_file(Path.expand("../../mix/release_erts.ex", __DIR__))

defmodule Minga.ReleaseERTSTest do
  # Receipt selection and Burrito resolver registration are process-global build inputs.
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias Burrito.Builder.Context
  alias Burrito.Builder.Target
  alias Minga.ReleaseERTS

  @repo Path.expand("../..", __DIR__)
  @moduletag :tmp_dir
  @executables ~w(Install erts-17.1.1/bin/erl erts-17.1.1/bin/erlexec erts-17.1.1/bin/beam.smp)
  @files ~w(usr/include/ei.h usr/include/erl_nif.h usr/lib/libei.a erts-17.1.1/include/erl_nif.h lib/kernel-1/ebin/kernel.app lib/stdlib-1/ebin/stdlib.app lib/crypto-1/ebin/crypto.app lib/crypto-1/priv/lib/crypto.so)

  setup_all do
    # Relocate the actual module, not a copy of its implementation in a test helper.
    # The fixture checkout contains the actual trusted producer inputs.
    # Synthetic runtime files below prove only the consumer filesystem boundary.
    source_root = System.get_env("MINGA_ERTS_TEST_SOURCE_ROOT", @repo)

    repo =
      Path.join(System.tmp_dir!(), "minga-erts-test-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(repo, "mix"))
    File.mkdir_p!(Path.join(repo, "scripts"))

    for file <- ~w(release_erts_sources.json build-release-erts.py) do
      File.cp!(Path.join([source_root, "scripts", file]), Path.join([repo, "scripts", file]))
    end

    source = Path.join(@repo, "mix/release_erts.ex")
    relocated = Path.join(repo, "mix/release_erts.ex")
    File.cp!(source, relocated)
    previous = Code.compiler_options()[:ignore_module_conflict]
    Code.compiler_options(ignore_module_conflict: true)
    Code.compile_file(relocated)
    Code.compiler_options(ignore_module_conflict: previous)

    on_exit(fn ->
      previous = Code.compiler_options()[:ignore_module_conflict]
      Code.compiler_options(ignore_module_conflict: true)
      Code.compile_file(source)
      Code.compiler_options(ignore_module_conflict: previous)
      File.rm_rf!(repo)
    end)

    manifest =
      Path.join(repo, "scripts/release_erts_sources.json") |> File.read!() |> JSON.decode!()

    %{
      manifest: manifest,
      manifest_path: Path.join(repo, "scripts/release_erts_sources.json"),
      recipe_sha: sha(File.read!(Path.join(repo, "scripts/build-release-erts.py")))
    }
  end

  setup context do
    previous = System.get_env("MINGA_RELEASE_ERTS_RECEIPT")
    path = Path.join(context.tmp_dir, "receipt.json")
    System.put_env("MINGA_RELEASE_ERTS_RECEIPT", path)
    on_exit(fn -> restore_env("MINGA_RELEASE_ERTS_RECEIPT", previous) end)
    target = native_target()
    root = "otp-29.1.2-#{os_name(target.os)}-#{target.cpu}"
    tree = Path.join(context.tmp_dir, "tree")
    for dir <- ~w(releases misc), do: File.mkdir_p!(Path.join([tree, root, dir]))

    for file <- @files ++ @executables do
      full = Path.join([tree, root, file])
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "consumer filesystem fixture; not an OTP runtime\n")
      File.chmod!(full, if(file in @executables, do: 0o755, else: 0o644))
    end

    receipt = receipt(context, target, root)

    context =
      Map.merge(context, %{path: path, target: target, root: root, tree: tree, receipt: receipt})

    archive!(context)
    context
  end

  test "returns the documented Target with a fresh private parent and complete OTP root",
       context do
    first = ReleaseERTS.do_resolve(context.target)
    second = ReleaseERTS.do_resolve(context.target)
    {:local_unpacked, path: first_parent} = first.erts_source
    {:local_unpacked, path: second_parent} = second.erts_source
    on_exit(fn -> Enum.each([first_parent, second_parent], &File.rm_rf!/1) end)
    refute first_parent == second_parent
    assert first == %{context.target | erts_source: {:local_unpacked, path: first_parent}}
    assert File.ls!(first_parent) == [context.root]
    assert band(File.stat!(first_parent).mode, 0o777) == 0o700
    assert File.stat!(first_parent).uid == File.stat!(context.tmp_dir).uid
    assert File.regular?(Path.join([first_parent, context.root, "usr/lib/libei.a"]))

    File.write!(
      Path.join([context.tree, context.root, "usr/lib/libei.a"]),
      "mutated producer extraction"
    )

    assert File.read!(Path.join([first_parent, context.root, "usr/lib/libei.a"])) =~
             "consumer filesystem fixture"
  end

  test "requires an explicit absolute receipt and rejects absent or malformed inputs", context do
    for path <- [nil, "", "receipt.json", Path.join(context.tmp_dir, "absent.json")] do
      restore_env("MINGA_RELEASE_ERTS_RECEIPT", path)
      assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
    end

    System.put_env("MINGA_RELEASE_ERTS_RECEIPT", context.path)
    File.write!(context.path, "{bad json")
    assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
  end

  test "rejects runtime shortcuts and nonnative CPU or OS requests", context do
    for source <- [
          {:runtime, []},
          {:local_unpacked, path: context.tree},
          {:precompiled, version: "29.1.1"}
        ] do
      assert_raise Mix.Error, fn ->
        ReleaseERTS.do_resolve(%{context.target | erts_source: source})
      end
    end

    other_cpu = if context.target.cpu == :aarch64, do: :x86_64, else: :aarch64
    other_os = if context.target.os == :darwin, do: :linux, else: :darwin

    for target <- [%{context.target | cpu: other_cpu}, %{context.target | os: other_os}] do
      assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(target) end
    end
  end

  test "rejects receipt target, version, source, recipe and ABI waivers", context do
    base = read_receipt(context)

    for changed <- [
          Map.put(base, "version", 2),
          Map.put(base, "kind", "precompiled"),
          Map.put(base, "arch", "wrong"),
          Map.put(base, "os", "wrong"),
          Map.put(base, "otp_version", "29.1.1"),
          Map.put(base, "erts_version", "17.1.0"),
          Map.put(base, "openssl_version", "3.5.0"),
          Map.put(base, "sources", %{}),
          Map.put(base, "recipe_sha256", String.duplicate("0", 64)),
          Map.put(base, "checks", []),
          Map.put(base, "build_environment", %{}),
          Map.put(base, "abi", %{}),
          Map.put(base, "minimum_macos", "14.0")
        ] do
      write_receipt(context, changed)
      assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
    end
  end

  test "rejects changed toolchain identities and unbounded or missing observed facts", context do
    base = read_receipt(context)

    keys =
      if context.target.os == :darwin,
        do:
          ~w(kind host_arch developer_dir xcode_version xcode_build clang_version sdk_version host_os_version),
        else: ~w(kind host_arch image musl_version cc_version container_os_version)

    for key <- keys, value <- ["", "different", nil, String.duplicate("x", 4097)] do
      changed = put_in(base, ["build_environment", key], value)
      # Observed version strings are facts, not another compiler allowlist.
      if value != "different" or
           key not in ~w(clang_version sdk_version host_os_version cc_version container_os_version) do
        write_receipt(context, changed)
        assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
      end
    end
  end

  test "rejects special archive members, privileged modes and oversized expansion", context do
    for {type, size, mode} <- [
          {?1, 0, 0o644},
          {?2, 0, 0o644},
          {?3, 0, 0o644},
          {?4, 0, 0o644},
          {?6, 0, 0o644},
          {?0, 0, 0o4755},
          {?0, 1_073_741_825, 0o644}
        ] do
      archive = raw_member(context.root <> "/member", type, size, mode)
      File.write!(Path.join(context.tmp_dir, "erts.tar.gz"), :zlib.gzip(archive))
      update_archive_receipt!(context)
      assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
    end
  end

  test "rejects altered archive identity, exact bytes and missing archive", context do
    base = read_receipt(context)

    for {key, value} <- [
          {"file", "../other.tar.gz"},
          {"root", "other"},
          {"bytes", 0},
          {"bytes", 2_147_483_649},
          {"bytes", base["archive"]["bytes"] + 1},
          {"sha256", String.duplicate("0", 64)}
        ] do
      write_receipt(context, put_in(base, ["archive", key], value))
      assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
    end

    write_receipt(context, base)
    File.write!(Path.join(context.tmp_dir, "erts.tar.gz"), "altered bytes")
    assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
    File.rm!(Path.join(context.tmp_dir, "erts.tar.gz"))
    assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
  end

  test "rejects unsafe paths, extra roots, duplicate members and invalid archives", context do
    for entries <- [
          [{String.to_charlist(context.root <> "/../outside"), "bad"}],
          [{~c"/absolute", "bad"}],
          [{~c"other/file", "bad"}],
          [
            {String.to_charlist(context.root <> "/file"), "a"},
            {String.to_charlist(context.root <> "/file"), "b"}
          ]
        ] do
      path = Path.join(context.tmp_dir, "erts.tar.gz")
      :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
      update_archive_receipt!(context)
      assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
    end

    File.write!(Path.join(context.tmp_dir, "erts.tar.gz"), "not a tar archive")
    update_archive_receipt!(context)
    assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
  end

  test "rejects symbolic links and missing or nonexecutable runtime inputs", context do
    full = Path.join([context.tree, context.root, "usr/lib/link"])
    File.ln_s!("libei.a", full)
    archive!(context)
    assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
    File.rm!(full)

    for file <- @executables ++ @files do
      full = Path.join([context.tree, context.root, file])
      bytes = File.read!(full)
      File.rm!(full)
      archive!(context)
      assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
      File.write!(full, bytes)
      File.chmod!(full, if(file in @executables, do: 0o755, else: 0o644))
    end

    File.chmod!(Path.join([context.tree, context.root, "erts-17.1.1/bin/beam.smp"]), 0o644)
    archive!(context)
    assert_raise Mix.Error, fn -> ReleaseERTS.do_resolve(context.target) end
  end

  test "post-fetch skips helper only for a qualified macOS target and returns context unchanged",
       context do
    target = %{context.target | os: :darwin, erts_source: {:local_unpacked, path: context.tree}}
    receipt = receipt(context, target, "otp-29.1.2-macos-#{target.cpu}")
    write_receipt(context, receipt)
    fetched = build_context(target, context.tmp_dir, [])
    assert ReleaseERTS.execute(fetched) == fetched
    write_receipt(context, Map.put(receipt, "minimum_macos", "14.0"))
    assert_raise Mix.Error, fn -> ReleaseERTS.execute(fetched) end

    assert_raise Mix.Error, fn ->
      ReleaseERTS.execute(%{fetched | target: context.target})
    end
  end

  test "Linux helper requires both completed checks, qualified bytes and one interpreter binding",
       context do
    helper_bytes = "consumer hash fixture; not a qualified musl runtime"
    original_manifest = File.read!(context.manifest_path)
    on_exit(fn -> File.write!(context.manifest_path, original_manifest) end)

    manifest =
      put_in(
        context.manifest,
        ["musl", "helpers", "linux_#{context.target.cpu}", "sha256"],
        sha(helper_bytes)
      )

    File.write!(context.manifest_path, JSON.encode!(manifest))
    context = %{context | manifest: manifest}
    target = %{context.target | os: :linux, erts_source: {:local_unpacked, path: context.tree}}
    receipt = receipt(context, target, "otp-29.1.2-linux-#{target.cpu}")
    write_receipt(context, receipt)
    binding = {"__BURRITO_MUSL_RUNTIME_PATH", receipt["abi"]["interpreter"]}
    fetched = build_context(target, context.tmp_dir, [binding])
    assert_raise Mix.Error, fn -> ReleaseERTS.execute(fetched) end
    helper = Path.join([context.tmp_dir, "src", "musl-runtime.so"])
    File.mkdir_p!(Path.dirname(helper))
    File.write!(helper, helper_bytes)
    assert ReleaseERTS.execute(fetched) == fetched

    checks = receipt["checks"]

    for incomplete <- [
          List.delete(checks, "musl-interpreter"),
          List.delete(checks, "musl-helper"),
          (checks -- ["musl-interpreter", "musl-helper"]) ++ ["musl-interpreter/helper"]
        ] do
      write_receipt(context, Map.put(receipt, "checks", incomplete))
      assert_raise Mix.Error, fn -> ReleaseERTS.execute(fetched) end
    end

    write_receipt(context, receipt)
    File.write!(helper, "wrong helper")
    assert_raise Mix.Error, fn -> ReleaseERTS.execute(fetched) end
    File.write!(helper, helper_bytes)

    for bindings <- [[], [{elem(binding, 0), "/tmp/wrong.so"}], [binding, binding]] do
      assert_raise Mix.Error, fn ->
        ReleaseERTS.execute(%{fetched | extra_build_env: bindings})
      end
    end
  end

  test "failed synchronous Burrito wrap restores a previous resolver or removes its registration" do
    previous = Application.fetch_env(:burrito, :erts_resolver)

    on_exit(fn ->
      case previous do
        {:ok, resolver} -> Application.put_env(:burrito, :erts_resolver, resolver)
        :error -> Application.delete_env(:burrito, :erts_resolver)
      end
    end)

    # Invalid wrapper configuration fails after resolver registration but before Burrito performs external work.

    for prior <- [:error, {:ok, __MODULE__}] do
      case prior do
        :error -> Application.delete_env(:burrito, :erts_resolver)
        {:ok, resolver} -> Application.put_env(:burrito, :erts_resolver, resolver)
      end

      release = %Mix.Release{
        options: [burrito: [extra_steps: [fetch: [post: [ReleaseERTS]]]]]
      }

      assert_raise Mix.Error, fn -> ReleaseERTS.wrap(release) end
      assert Application.fetch_env(:burrito, :erts_resolver) == prior
    end
  end

  defp receipt(context, target, root) do
    os = os_name(target.os)
    linux? = os == "linux"
    source_keys = if linux?, do: ~w(otp openssl musl), else: ~w(otp openssl)
    helper = context.manifest["musl"]["helpers"]["linux_#{target.cpu}"]["sha256"]

    %{
      "version" => 1,
      "kind" => "local-source-build",
      "os" => os,
      "arch" => to_string(target.cpu),
      "otp_version" => "29.1.2",
      "erts_version" => "17.1.1",
      "openssl_version" => "3.5.1",
      "musl_version" => if(linux?, do: "1.2.5", else: nil),
      "minimum_macos" => if(linux?, do: nil, else: "15.0"),
      "archive" => %{
        "file" => "erts.tar.gz",
        "root" => root,
        "bytes" => 1,
        "sha256" => sha("fixture")
      },
      "recipe_sha256" => context.recipe_sha,
      "sources" => Map.new(source_keys, &{&1, Map.take(context.manifest[&1], ~w(url sha256))}),
      "build_environment" => build_environment(context.manifest, target),
      "abi" => %{
        "interpreter" => if(linux?, do: "/tmp/libc-musl-#{helper}.so", else: nil),
        "musl_sha256" => if(linux?, do: helper, else: nil),
        "external_dependencies" => [],
        "minimum_macos" => if(linux?, do: nil, else: "15.0")
      },
      "checks" =>
        ~w(otp-version erts-version native-architecture crypto-result native-library-closure) ++
          if(linux?, do: ~w(musl-interpreter musl-helper), else: ~w(minimum-macos))
    }
  end

  defp build_environment(manifest, %{os: :darwin, cpu: arch}) do
    Map.merge(manifest["macos_build_environment"], %{
      "kind" => "native-macos",
      "host_arch" => to_string(arch),
      "clang_version" => "filesystem fixture only",
      "sdk_version" => "filesystem fixture only",
      "host_os_version" => "filesystem fixture only"
    })
  end

  defp build_environment(manifest, %{os: :linux, cpu: arch}) do
    %{
      "kind" => "native-alpine",
      "host_arch" => to_string(arch),
      "image" => manifest["linux_build_image"]["image"],
      "musl_version" => "1.2.5",
      "cc_version" => "filesystem fixture only",
      "container_os_version" => "filesystem fixture only"
    }
  end

  defp archive!(context) do
    path = Path.join(context.tmp_dir, "erts.tar.gz")
    {:ok, archive} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])

    :ok =
      :erl_tar.add(
        archive,
        String.to_charlist(Path.join(context.tree, context.root)),
        String.to_charlist(context.root),
        []
      )

    :ok = :erl_tar.close(archive)
    update_archive_receipt!(context)
  end

  defp update_archive_receipt!(context) do
    bytes = File.read!(Path.join(context.tmp_dir, "erts.tar.gz"))

    receipt = %{
      context.receipt
      | "archive" =>
          Map.merge(context.receipt["archive"], %{
            "bytes" => byte_size(bytes),
            "sha256" => sha(bytes)
          })
    }

    write_receipt(context, receipt)
  end

  defp raw_member(name, type, size, mode) do
    header =
      IO.iodata_to_binary([
        String.pad_trailing(name, 100, <<0>>),
        octal(mode, 8),
        octal(0, 8),
        octal(0, 8),
        octal(size, 12),
        octal(0, 12),
        "        ",
        <<type>>,
        :binary.copy(<<0>>, 100),
        "ustar",
        <<0>>,
        "00",
        :binary.copy(<<0>>, 32 + 32),
        octal(0, 8),
        octal(0, 8),
        :binary.copy(<<0>>, 155 + 12)
      ])

    checksum =
      header
      |> :binary.bin_to_list()
      |> Enum.sum()
      |> Integer.to_string(8)
      |> String.pad_leading(6, "0")

    <<prefix::binary-size(148), _::binary-size(8), suffix::binary>> = header
    prefix <> checksum <> <<0>> <> " " <> suffix <> :binary.copy(<<0>>, 1024)
  end

  defp octal(value, width),
    do: String.pad_leading(Integer.to_string(value, 8), width - 1, "0") <> <<0>>

  defp build_context(target, self_dir, env) do
    %Context{
      target: target,
      mix_release: %Mix.Release{},
      work_dir: "",
      self_dir: self_dir,
      extra_build_env: env,
      halted: false
    }
  end

  defp native_target do
    cpu = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

    cpu =
      case cpu do
        "aarch64" -> :aarch64
        "x86_64" -> :x86_64
      end

    os =
      case :os.type() do
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
      end

    %Target{
      alias: :fixture,
      cpu: cpu,
      os: os,
      cross_build: false,
      qualifiers: [],
      erts_source: {:precompiled, version: "29.1.2"},
      debug?: false
    }
  end

  defp os_name(:darwin), do: "macos"
  defp os_name(:linux), do: "linux"
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp read_receipt(context), do: context.path |> File.read!() |> JSON.decode!()
  defp write_receipt(context, receipt), do: File.write!(context.path, JSON.encode!(receipt))
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
