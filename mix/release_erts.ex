defmodule Minga.ReleaseERTS do
  @moduledoc """
  Build-only bridge from a qualified native source-build receipt to Burrito.

  The explicit `MINGA_RELEASE_ERTS_RECEIPT` input is checked against this checkout's source manifest and producer recipe.
  It is not installed-runtime qualification.
  No runtime download or host-ERTS fallback is provided here.
  """

  import Bitwise, only: [band: 2]

  alias Burrito.Builder.Context
  alias Burrito.Builder.Target

  @behaviour Burrito.Util.ERTSResolver
  @behaviour Burrito.Builder.Step
  @repo Path.expand("..", __DIR__)
  @state {__MODULE__, :staging}
  @otp "29.1.2"
  @erts "17.1.1"
  @openssl "3.5.1"
  @musl "1.2.5"
  @minimum_macos "15.0"
  @checks ~w(otp-version erts-version native-architecture crypto-result native-library-closure)

  @doc "Wraps synchronously with a scoped resolver and cleans its private runtime copies."
  @spec wrap(Mix.Release.t()) :: Mix.Release.t()
  def wrap(%Mix.Release{} = release) do
    previous = Application.fetch_env(:burrito, :erts_resolver)
    previous_staging = Process.get(@state)
    Process.put(@state, [])

    try do
      Burrito.register_erts_resolver(__MODULE__)
      Burrito.wrap(add_fetch_assertion(release))
    after
      try do
        for path <- Process.get(@state, []), do: File.rm_rf!(path)
      after
        restore_staging(previous_staging)
        restore_resolver(previous)
      end
    end
  end

  @doc "Resolves the exact native OTP request to a fresh verified archive extraction."
  @impl true
  @spec do_resolve(Target.t()) :: Target.t()
  def do_resolve(%Target{erts_source: {:precompiled, options}} = target) do
    ensure!(options == [version: @otp], "requested OTP must be #{@otp}")
    ensure_native!(target)
    {receipt, archive} = qualified_receipt!(target)
    parent = fresh_parent!()

    try do
      # Copy first, then hash and consume the same private bytes.
      # A separately mutable producer extraction or archive is never passed to Burrito.
      snapshot = Path.join(parent, "erts.tar.gz")
      stat = File.lstat!(archive)

      ensure!(
        stat.type == :regular and stat.size == receipt["archive"]["bytes"],
        "archive byte size differs"
      )

      File.cp!(archive, snapshot)
      verify_archive!(snapshot, receipt["archive"])
      extract!(snapshot, parent, receipt["archive"]["root"])
      File.rm!(snapshot)
      verify_layout!(parent, receipt["archive"]["root"])
      Process.put(@state, [parent | Process.get(@state, [])])
      %{target | erts_source: {:local_unpacked, path: parent}}
    rescue
      error ->
        File.rm_rf!(parent)
        fail!(Exception.message(error))
    end
  rescue
    error in Mix.Error -> reraise error, __STACKTRACE__
    error -> fail!(Exception.message(error))
  end

  def do_resolve(%Target{}) do
    fail!("only the pinned precompiled version request may enter the local source resolver")
  end

  @doc "Asserts the fetched helper and interpreter binding without changing the context."
  @impl true
  @spec execute(Context.t()) :: Context.t()
  def execute(%Context{target: %Target{erts_source: {:local_unpacked, _}}} = context) do
    {receipt, _archive} = qualified_receipt!(context.target)

    verify_helper!(context, receipt)
    context
  rescue
    error in Mix.Error -> reraise error, __STACKTRACE__
    error -> fail!(Exception.message(error))
  end

  def execute(%Context{}), do: fail!("post-fetch runtime is unresolved")

  defp add_fetch_assertion(release) do
    options = release.options[:burrito] || []
    extra = options[:extra_steps] || []
    fetch = extra[:fetch] || []
    post = fetch[:post] || []
    ensure!(__MODULE__ not in post, "post-fetch assertion is already registered")
    fetch = Keyword.put(fetch, :post, post ++ [__MODULE__])
    options = Keyword.put(options, :extra_steps, Keyword.put(extra, :fetch, fetch))
    %{release | options: Keyword.put(release.options, :burrito, options)}
  end

  defp restore_resolver({:ok, resolver}),
    do: Application.put_env(:burrito, :erts_resolver, resolver)

  defp restore_resolver(:error), do: Application.delete_env(:burrito, :erts_resolver)
  defp restore_staging(nil), do: Process.delete(@state)
  defp restore_staging(staging), do: Process.put(@state, staging)

  defp ensure_native!(target) do
    os =
      case :os.type() do
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
        _ -> fail!("unsupported native host")
      end

    cpu = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

    ensure!(
      target.os == os and to_string(target.cpu) == cpu,
      "target must match the native host CPU and OS"
    )
  end

  defp qualified_receipt!(target) do
    path = System.get_env("MINGA_RELEASE_ERTS_RECEIPT")

    ensure!(
      is_binary(path) and path != "" and Path.type(path) == :absolute,
      "MINGA_RELEASE_ERTS_RECEIPT must name an explicit absolute receipt path"
    )

    receipt = read_json!(path)
    manifest = read_json!(Path.join(@repo, "scripts/release_erts_sources.json"))
    recipe = Path.join(@repo, "scripts/build-release-erts.py")
    os = receipt_os(target.os)
    arch = to_string(target.cpu)

    verify_manifest_pins!(manifest)

    ensure!(
      receipt["version"] == 1 and receipt["kind"] == "local-source-build",
      "unsupported source-build receipt"
    )

    ensure!(receipt["os"] == os and receipt["arch"] == arch, "receipt target differs")

    ensure!(
      receipt["otp_version"] == @otp and receipt["erts_version"] == @erts and
        receipt["openssl_version"] == @openssl,
      "receipt version pins differ"
    )

    ensure!(receipt["recipe_sha256"] == hash_file!(recipe), "producer recipe SHA256 differs")

    source_keys = if os == "linux", do: ~w(otp openssl musl), else: ~w(otp openssl)

    expected_sources =
      Map.new(source_keys, fn key ->
        source = manifest[key]

        ensure!(
          is_map(source) and is_binary(source["url"]) and valid_hash?(source["sha256"]),
          "invalid trusted source #{key}"
        )

        {key, Map.take(source, ~w(url sha256))}
      end)

    ensure!(receipt["sources"] == expected_sources, "receipt source identities differ")
    verify_build_environment!(receipt["build_environment"], manifest, os, arch)
    verify_abi_receipt!(receipt, manifest, os, arch)

    archive = receipt["archive"]

    verify_archive_identity!(archive, os, arch)

    {receipt, Path.join(Path.dirname(path), "erts.tar.gz")}
  end

  defp verify_manifest_pins!(manifest) do
    ensure!(manifest["version"] == 1, "unsupported trusted source manifest")

    ensure!(
      get_in(manifest, ["otp", "version"]) == @otp and
        get_in(manifest, ["otp", "erts_version"]) == @erts and
        get_in(manifest, ["openssl", "version"]) == @openssl and
        get_in(manifest, ["musl", "version"]) == @musl and
        manifest["minimum_macos"] == @minimum_macos,
      "trusted manifest pins differ"
    )
  end

  defp verify_archive_identity!(archive, os, arch) do
    ensure!(
      is_map(archive) and archive["file"] == "erts.tar.gz" and
        archive["root"] == "otp-#{@otp}-#{os}-#{arch}" and
        is_integer(archive["bytes"]) and archive["bytes"] > 0 and
        archive["bytes"] <= 2_147_483_648 and valid_hash?(archive["sha256"]),
      "invalid or oversized archive identity"
    )
  end

  defp receipt_os(:darwin), do: "macos"
  defp receipt_os(:linux), do: "linux"
  defp receipt_os(_), do: fail!("unsupported target OS")

  defp verify_build_environment!(environment, manifest, "macos", arch) do
    expected = manifest["macos_build_environment"]

    ensure!(
      is_map(environment) and is_map(expected) and environment["kind"] == "native-macos" and
        environment["host_arch"] == arch,
      "native macOS build environment differs"
    )

    for key <- ~w(developer_dir xcode_version xcode_build) do
      ensure!(
        bounded_fact?(expected[key]) and environment[key] == expected[key],
        "macOS toolchain #{key} differs"
      )
    end

    verify_facts!(environment, ~w(clang_version sdk_version host_os_version))
  end

  defp verify_build_environment!(environment, manifest, "linux", arch) do
    image = manifest["linux_build_image"]

    ensure!(
      is_map(environment) and is_map(image) and environment["kind"] == "native-alpine" and
        environment["host_arch"] == arch and environment["image"] == image["image"] and
        environment["musl_version"] == @musl and image["musl_version"] == @musl and
        arch in image["architectures"],
      "native Linux build environment differs"
    )

    verify_facts!(environment, ~w(cc_version container_os_version))
  end

  defp verify_facts!(environment, keys) do
    ensure!(map_size(environment) <= 32, "build environment has too many facts")

    for key <- keys do
      ensure!(bounded_fact?(environment[key]), "missing bounded native tool fact #{key}")
    end
  end

  defp bounded_fact?(value) when is_binary(value),
    do:
      byte_size(value) in 1..4096 and String.trim(value) != "" and
        not String.contains?(value, <<0>>)

  defp bounded_fact?(_value), do: false

  defp verify_abi_receipt!(receipt, manifest, "linux", arch) do
    helper = get_in(manifest, ["musl", "helpers", "linux_#{arch}"])
    ensure!(is_map(helper) and valid_hash?(helper["sha256"]), "missing trusted musl helper")
    abi = receipt["abi"]

    ensure!(
      is_map(abi) and receipt["musl_version"] == @musl and receipt["minimum_macos"] == nil and
        abi["musl_sha256"] == helper["sha256"] and
        abi["interpreter"] == "/tmp/libc-musl-#{helper["sha256"]}.so" and
        abi["minimum_macos"] == nil,
      "Linux musl ABI evidence differs"
    )

    verify_checks!(receipt, @checks ++ ~w(musl-interpreter musl-helper))
  end

  defp verify_abi_receipt!(receipt, _manifest, "macos", _arch) do
    abi = receipt["abi"]

    ensure!(
      is_map(abi) and receipt["musl_version"] == nil and
        receipt["minimum_macos"] == @minimum_macos and
        abi["interpreter"] == nil and abi["musl_sha256"] == nil and
        abi["minimum_macos"] == @minimum_macos,
      "macOS minimum-version ABI evidence differs"
    )

    verify_checks!(receipt, @checks ++ ~w(minimum-macos))
  end

  defp verify_checks!(receipt, required) do
    checks = receipt["checks"]

    ensure!(
      is_list(checks) and Enum.all?(required, &(&1 in checks)),
      "missing completed qualification checks"
    )

    dependencies = receipt["abi"]["external_dependencies"]
    ensure!(is_list(dependencies), "missing inspected native dependency inventory")
  end

  defp verify_helper!(%Context{target: %Target{os: :darwin}}, %{"os" => "macos"}), do: :ok

  defp verify_helper!(
         %Context{target: %Target{os: :linux}} = context,
         %{"os" => "linux"} = receipt
       ) do
    abi = receipt["abi"]
    helper = Path.join([context.self_dir, "src", "musl-runtime.so"])

    bindings =
      Enum.filter(context.extra_build_env, fn {key, _} -> key == "__BURRITO_MUSL_RUNTIME_PATH" end)

    ensure!(
      bindings == [{"__BURRITO_MUSL_RUNTIME_PATH", abi["interpreter"]}],
      "musl interpreter binding differs"
    )

    ensure!(hash_file!(helper) == abi["musl_sha256"], "fetched musl helper SHA256 differs")
  end

  defp verify_helper!(_context, _receipt),
    do: fail!("post-fetch target differs from qualified runtime")

  defp fresh_parent! do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    path = Path.join(System.tmp_dir!(), "minga-release-erts-#{suffix}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    stat = File.lstat!(path)

    ensure!(
      stat.type == :directory and band(stat.mode, 0o777) == 0o700,
      "runtime staging is not private"
    )

    path
  end

  defp verify_archive!(path, archive) do
    stat = File.lstat!(path)
    ensure!(stat.type == :regular and stat.size == archive["bytes"], "archive byte size differs")
    ensure!(hash_file!(path) == archive["sha256"], "archive SHA256 differs")
    magic = File.open!(path, [:read, :binary], &IO.binread(&1, 2))
    ensure!(magic == <<0x1F, 0x8B>>, "runtime archive must be gzip-compressed")
  end

  defp extract!(archive, parent, root) do
    entries =
      case :erl_tar.table(String.to_charlist(archive), [:compressed, :verbose]) do
        {:ok, entries} -> entries
        {:error, reason} -> fail!("invalid runtime archive: #{inspect(reason)}")
      end

    ensure!(Enum.count_until(entries, 200_001) <= 200_000, "archive has too many members")

    total =
      Enum.reduce(entries, 0, fn {_name, _type, size, _mtime, _mode, _uid, _gid}, total ->
        ensure!(size >= 0 and size <= 1_073_741_824, "archive member is oversized")
        total + size
      end)

    ensure!(total <= 4_294_967_296, "archive expansion is oversized")

    names =
      Enum.map(entries, fn {name, type, _size, _mtime, mode, _uid, _gid} ->
        name = to_string(name) |> String.trim_trailing("/")
        parts = String.split(name, "/")

        ensure!(
          type in [:regular, :directory] and band(mode, 0o7000) == 0,
          "archive contains links, special files or privileged modes"
        )

        ensure!(
          (type == :directory and band(mode, 0o500) == 0o500) or
            (type == :regular and band(mode, 0o400) == 0o400),
          "archive has unreadable member modes"
        )

        ensure!(
          hd(parts) == root and Enum.all?(parts, &(&1 not in ["", ".", ".."])),
          "archive contains an unsafe path or ambiguous OTP root"
        )

        name
      end)

    ensure!(
      names != [] and length(names) == MapSet.size(MapSet.new(names)),
      "archive has duplicate or missing entries"
    )

    case :erl_tar.extract(String.to_charlist(archive), [
           :compressed,
           {:cwd, String.to_charlist(parent)}
         ]) do
      :ok -> :ok
      {:error, reason} -> fail!("runtime extraction failed: #{inspect(reason)}")
    end
  end

  defp verify_layout!(parent, root) do
    ensure!(Enum.sort(File.ls!(parent)) == [root], "archive must contain exactly one OTP root")
    otp = Path.join(parent, root)

    ensure!(
      Path.wildcard(Path.join(otp, "erts-*")) == [Path.join(otp, "erts-#{@erts}")],
      "archive ERTS layout differs"
    )

    for dir <- [
          "erts-#{@erts}",
          "releases",
          "lib",
          "misc",
          "usr",
          "usr/include",
          "usr/lib",
          "erts-#{@erts}/include"
        ] do
      ensure!(File.dir?(Path.join(otp, dir)), "missing runtime directory #{dir}")
    end

    for file <- [
          "Install",
          "erts-#{@erts}/bin/erl",
          "erts-#{@erts}/bin/erlexec",
          "erts-#{@erts}/bin/beam.smp"
        ] do
      stat = regular_file!(Path.join(otp, file))
      ensure!(band(stat.mode, 0o100) != 0, "missing executable mode on #{file}")
    end

    for file <- [
          "usr/include/ei.h",
          "usr/include/erl_nif.h",
          "usr/lib/libei.a",
          "erts-#{@erts}/include/erl_nif.h"
        ] do
      regular_file!(Path.join(otp, file))
    end

    for pattern <- [
          "lib/kernel-*/ebin/kernel.app",
          "lib/stdlib-*/ebin/stdlib.app",
          "lib/crypto-*/ebin/crypto.app",
          "lib/crypto-*/priv/lib/crypto.so"
        ] do
      files = Path.wildcard(Path.join(otp, pattern))
      ensure!(files != [], "missing runtime library #{pattern}")
      Enum.each(files, &regular_file!/1)
    end
  end

  defp regular_file!(path) do
    stat = File.lstat!(path)

    ensure!(
      stat.type == :regular and stat.size > 0,
      "missing regular runtime input #{Path.basename(path)}"
    )

    stat
  end

  defp read_json!(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular and stat.size <= 1_048_576,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= 1_048_576 do
      case JSON.decode(bytes) do
        {:ok, value} when is_map(value) -> value
        _ -> fail!("invalid JSON object in #{Path.basename(path)}")
      end
    else
      _ -> fail!("cannot read bounded #{Path.basename(path)}")
    end
  end

  defp hash_file!(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          hash_stream!(file, :crypto.hash_init(:sha256))
        after
          File.close(file)
        end

      {:error, reason} ->
        fail!("cannot read #{Path.basename(path)}: #{inspect(reason)}")
    end
  end

  defp hash_stream!(file, state) do
    case IO.binread(file, 65_536) do
      :eof -> :crypto.hash_final(state) |> Base.encode16(case: :lower)
      bytes when is_binary(bytes) -> hash_stream!(file, :crypto.hash_update(state, bytes))
      {:error, reason} -> fail!("cannot hash runtime input: #{inspect(reason)}")
    end
  end

  defp valid_hash?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp valid_hash?(_value), do: false
  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: fail!(message)
  defp fail!(message), do: Mix.raise("Release ERTS: " <> message)
end
