Code.require_file(Path.expand("../../mix/release_erts.ex", __DIR__))

defmodule Minga.ReleaseERTSTest do
  # Receipt selection is a process-global environment input.
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias Minga.ReleaseERTS
  alias Mix.Tasks.Release.Tui

  @repo Path.expand("../..", __DIR__)
  @moduletag :tmp_dir
  @executables ~w(Install erts-17.1.1/bin/erl erts-17.1.1/bin/erlexec erts-17.1.1/bin/beam.smp)
  @files ~w(usr/include/ei.h usr/include/erl_nif.h usr/lib/libei.a erts-17.1.1/include/erl_nif.h lib/kernel-1/ebin/kernel.app lib/stdlib-1/ebin/stdlib.app lib/crypto-1/ebin/crypto.app lib/crypto-1/priv/lib/crypto.so)

  setup_all do
    # Synthetic runtime files below prove only the consumer filesystem boundary.

    manifest =
      Path.join(@repo, "scripts/release_erts_sources.json") |> File.read!() |> JSON.decode!()

    %{
      manifest: manifest,
      recipe_sha: sha(File.read!(Path.join(@repo, "scripts/build-release-erts.py")))
    }
  end

  setup context do
    previous = System.get_env("MINGA_RELEASE_ERTS_RECEIPT")
    path = Path.join(context.tmp_dir, "receipt.json")
    System.put_env("MINGA_RELEASE_ERTS_RECEIPT", path)
    on_exit(fn -> restore_env("MINGA_RELEASE_ERTS_RECEIPT", previous) end)
    target = native_target()
    root = "otp-29.1.2-#{target.os}-#{target.arch}"
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

  test "supplies a fresh private ERTS path and complete OTP root only within the callback",
       context do
    first =
      ReleaseERTS.with_verified_runtime(fn erts ->
        otp = Path.dirname(erts)
        parent = Path.dirname(otp)
        assert Path.type(erts) == :absolute
        assert Path.basename(erts) == "erts-17.1.1"
        assert File.ls!(parent) == [context.root]
        assert band(File.stat!(parent).mode, 0o777) == 0o700
        assert File.stat!(parent).uid == File.stat!(context.tmp_dir).uid

        File.write!(
          Path.join([context.tree, context.root, "usr/lib/libei.a"]),
          "mutated producer extraction"
        )

        assert File.read!(Path.join(otp, "usr/lib/libei.a")) =~ "consumer filesystem fixture"

        ReleaseERTS.with_verified_runtime(fn other ->
          refute other == erts
          assert File.dir?(erts)
          assert File.dir?(other)
        end)

        assert File.dir?(erts)
        erts
      end)

    refute File.exists?(first |> Path.dirname() |> Path.dirname())
  end

  test "requires an explicit absolute receipt and rejects absent or malformed inputs", context do
    for path <- [nil, "", "receipt.json", Path.join(context.tmp_dir, "absent.json")] do
      restore_env("MINGA_RELEASE_ERTS_RECEIPT", path)
      assert_invalid_runtime()
    end

    System.put_env("MINGA_RELEASE_ERTS_RECEIPT", context.path)
    File.write!(context.path, "{bad json")
    assert_invalid_runtime()
  end

  test "rejects nonnative receipts before invoking the callback", context do
    base = read_receipt(context)
    other_arch = if context.target.arch == "aarch64", do: "x86_64", else: "aarch64"
    other_os = if context.target.os == "macos", do: "linux", else: "macos"

    for {key, other} <- [{"arch", other_arch}, {"os", other_os}] do
      write_receipt(context, Map.put(base, key, other))
      assert_invalid_runtime()
    end
  end

  test "rejects receipt target, version, source, recipe and ABI waivers", context do
    base = read_receipt(context)

    for changed <- [
          Map.put(base, "version", 1),
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
      assert_invalid_runtime()
    end
  end

  test "rejects changed toolchain identities and unbounded or missing observed facts", context do
    base = read_receipt(context)

    keys =
      if context.target.os == "macos",
        do:
          ~w(kind host_arch developer_dir xcode_version xcode_build clang_version sdk_version host_os_version),
        else: ~w(kind host_arch os_id os_version glibc_version cc_version)

    for key <- keys, value <- ["", "different", nil, String.duplicate("x", 4097)] do
      changed = put_in(base, ["build_environment", key], value)
      # Observed version strings are facts, not another compiler allowlist.
      if value != "different" or
           key not in ~w(clang_version sdk_version host_os_version cc_version) do
        write_receipt(context, changed)
        assert_invalid_runtime()
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
      assert_invalid_runtime()
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
      assert_invalid_runtime()
    end

    write_receipt(context, base)
    File.write!(Path.join(context.tmp_dir, "erts.tar.gz"), "altered bytes")
    assert_invalid_runtime()
    File.rm!(Path.join(context.tmp_dir, "erts.tar.gz"))
    assert_invalid_runtime()
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
      assert_invalid_runtime()
    end

    File.write!(Path.join(context.tmp_dir, "erts.tar.gz"), "not a tar archive")
    update_archive_receipt!(context)
    assert_invalid_runtime()
  end

  test "rejects symbolic links and missing or nonexecutable runtime inputs", context do
    full = Path.join([context.tree, context.root, "usr/lib/link"])
    File.ln_s!("libei.a", full)
    archive!(context)
    assert_invalid_runtime()
    File.rm!(full)

    for file <- @executables ++ @files do
      full = Path.join([context.tree, context.root, file])
      bytes = File.read!(full)
      File.rm!(full)
      archive!(context)
      assert_invalid_runtime()
      File.write!(full, bytes)
      File.chmod!(full, if(file in @executables, do: 0o755, else: 0o644))
    end

    File.chmod!(Path.join([context.tree, context.root, "erts-17.1.1/bin/beam.smp"]), 0o644)
    archive!(context)
    assert_invalid_runtime()
  end

  test "rejects missing qualification and ABI evidence", context do
    base = read_receipt(context)
    abi = base["abi"]

    waivers =
      if context.target.os == "linux" do
        [first | rest] = abi["external_dependencies"]

        [
          {"interpreter", "/tmp/libc-musl-helper.so"},
          {"interpreter", nil},
          {"external_dependencies", []},
          {"external_dependencies", [first, first | rest]},
          {"external_dependencies", [%{first | "file" => "../beam.smp"} | rest]},
          {"external_dependencies", [%{first | "libraries" => []} | rest]},
          {"external_dependencies", [%{first | "libraries" => ["libssl.so.3"]} | rest]}
        ]
      else
        [{"minimum_macos", "14.0"}, {"interpreter", "/unexpected/loader"}]
      end

    for {key, value} <- waivers do
      write_receipt(context, put_in(base, ["abi", key], value))
      assert_invalid_runtime()
    end

    extra_check = if context.target.os == "linux", do: "host-interpreter", else: "minimum-macos"
    write_receipt(context, Map.update!(base, "checks", &List.delete(&1, extra_check)))
    assert_invalid_runtime()
  end

  test "cleans the private path on callback failure without replacing its error" do
    assert_raise RuntimeError, "assembly failed", fn ->
      ReleaseERTS.with_verified_runtime(fn erts ->
        send(self(), {:staging, erts |> Path.dirname() |> Path.dirname()})
        raise "assembly failed"
      end)
    end

    assert_received {:staging, path}
    refute File.exists?(path)
  end

  test "rejects accessing the TUI task include_erts callback outside its scope" do
    assert_raise Mix.Error, ~r/mix release.tui/, fn ->
      Tui.erts_path!()
    end
  end

  test "rejects Mix falling back to host OTP but accepts Elixir and normal dependency paths",
       context do
    otp_root = Path.join(context.tree, context.root)

    release = %Mix.Release{
      erts_source: String.to_charlist(Path.join(otp_root, "erts-17.1.1")),
      applications: %{
        crypto: [path: Path.join(otp_root, "lib/crypto-1")],
        elixir: [path: :code.lib_dir(:elixir)],
        req: [path: Path.join(context.tmp_dir, "_build/prod/lib/req")]
      }
    }

    assert Tui.verify_otp_apps!(release) == release

    fallback = put_in(release.applications[:crypto][:path], :code.lib_dir(:crypto))

    assert_raise Mix.Error, ~r/Mix resolved them from the host: crypto/, fn ->
      Tui.verify_otp_apps!(fallback)
    end
  end

  defp assert_invalid_runtime do
    assert_raise Mix.Error, fn ->
      ReleaseERTS.with_verified_runtime(fn _ -> flunk("invalid runtime reached the callback") end)
    end
  end

  defp receipt(context, target, root) do
    linux? = target.os == "linux"

    interpreter =
      get_in(context.manifest, ["linux_build_environment", "interpreters", target.arch])

    dependencies =
      for name <- ~w(beam.smp erlexec) do
        %{"file" => "erts-17.1.1/bin/#{name}", "libraries" => ["libc.so.6"]}
      end

    %{
      "version" => 2,
      "kind" => "local-source-build",
      "os" => target.os,
      "arch" => target.arch,
      "otp_version" => "29.1.2",
      "erts_version" => "17.1.1",
      "openssl_version" => "3.5.1",
      "minimum_macos" => if(linux?, do: nil, else: "15.0"),
      "archive" => %{
        "file" => "erts.tar.gz",
        "root" => root,
        "bytes" => 1,
        "sha256" => sha("fixture")
      },
      "recipe_sha256" => context.recipe_sha,
      "sources" =>
        Map.new(~w(otp openssl), &{&1, Map.take(context.manifest[&1], ~w(url sha256))}),
      "build_environment" => build_environment(context.manifest, target),
      "abi" => %{
        "interpreter" => if(linux?, do: interpreter, else: nil),
        "external_dependencies" => if(linux?, do: dependencies, else: []),
        "minimum_macos" => if(linux?, do: nil, else: "15.0")
      },
      "checks" =>
        ~w(otp-version erts-version native-architecture crypto-result native-library-closure) ++
          if(linux?, do: ~w(host-interpreter), else: ~w(minimum-macos))
    }
  end

  defp build_environment(manifest, %{os: "macos", arch: arch}) do
    Map.merge(manifest["macos_build_environment"], %{
      "kind" => "native-macos",
      "host_arch" => arch,
      "clang_version" => "filesystem fixture only",
      "sdk_version" => "filesystem fixture only",
      "host_os_version" => "filesystem fixture only"
    })
  end

  defp build_environment(manifest, %{os: "linux", arch: arch}) do
    manifest["linux_build_environment"]
    |> Map.take(~w(os_id os_version glibc_version))
    |> Map.merge(%{
      "kind" => "native-ubuntu",
      "host_arch" => arch,
      "cc_version" => "filesystem fixture only"
    })
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

  defp native_target do
    arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

    os =
      case :os.type() do
        {:unix, :darwin} -> "macos"
        {:unix, :linux} -> "linux"
      end

    %{os: os, arch: arch}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp read_receipt(context), do: context.path |> File.read!() |> JSON.decode!()
  defp write_receipt(context, receipt), do: File.write!(context.path, JSON.encode!(receipt))
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
