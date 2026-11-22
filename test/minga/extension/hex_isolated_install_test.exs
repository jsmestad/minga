defmodule Minga.Extension.HexIsolatedInstallTest do
  # Spawns real `erl` OS processes that run Mix.install/2, appends to the global code path, and
  # plants OS environment variables, because the child inherits the OS environment under test.
  use ExUnit.Case, async: false

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.DisposableBeam
  alias Minga.Extension.Entry
  alias Minga.Extension.HexIsolatedInstall
  alias Minga.Extension.Instance.Source

  @moduletag timeout: 300_000

  @sdk_path Path.expand("../../../sdk", __DIR__)

  # ExUnit's tmp_dir lives under the project directory, which has no symlinked components, so
  # the installer's resolved paths compare equal to it.
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    %{root: root, install_dir: Path.join(root, "install")}
  end

  test "installs a package outside the Mix project and admits it through the Hex source path",
       %{root: root, install_dir: install_dir} do
    suffix = System.unique_integer([:positive])
    app = :"hex_iso_ext_#{suffix}"
    module = Module.concat([:"HexIsoExt#{suffix}"])

    package =
      write_package(root, app, """
      defmodule #{inspect(module)} do
        use Minga.Extension

        @impl true
        def name, do: #{inspect(app)}
        @impl true
        def description, do: "isolated hex fixture"
        @impl true
        def version, do: "0.1.0"
        @impl true
        def init(_config), do: {:ok, %{}}
      end
      """)

    host_extension_beam = :code.which(Minga.Extension)

    assert {:ok, ebins} =
             HexIsolatedInstall.install([{app, ">= 0.0.0", path: package}], [app],
               install_dir: install_dir
             )

    assert Enum.any?(ebins, &String.ends_with?(&1, "/#{app}/ebin"))
    assert Enum.all?(ebins, &String.starts_with?(&1, install_dir <> "/"))

    # The SDK detects the host modules on the child's code path and compiles no stubs.
    assert [sdk_ebin] = Path.wildcard(Path.join(install_dir, "*/*/_build/*/lib/minga_sdk/ebin"))
    assert Path.wildcard(Path.join(sdk_ebin, "*.beam")) == []
    assert :code.which(Minga.Extension) == host_extension_beam

    admission = start_admission()
    entry = %Entry{source_type: :hex, hex: %{package: "#{app}", version: nil, app: app}}

    assert {:ok, artifact} = Source.prepare(app, entry, artifact_admission: admission)
    assert artifact.module == module
    assert List.to_string(:code.which(module)) =~ install_dir
  end

  test "refuses a dependency that would shadow a host module and adds no code path",
       %{root: root, install_dir: install_dir} do
    app = :"hex_iso_shadow_#{System.unique_integer([:positive])}"
    package = write_package(root, app, "defmodule Minga.UserPaths do\nend\n")
    host_beam = :code.which(Minga.UserPaths)

    assert {:error, message} =
             HexIsolatedInstall.install([{app, ">= 0.0.0", path: package}], [app],
               install_dir: install_dir
             )

    assert message =~ "would shadow host module Elixir.Minga.UserPaths"
    assert :code.which(Minga.UserPaths) == host_beam
    refute Enum.any?(:code.get_path(), &(List.to_string(&1) =~ install_dir))
  end

  test "reports the Mix.install failure when the package does not compile",
       %{root: root, install_dir: install_dir} do
    app = :"hex_iso_broken_#{System.unique_integer([:positive])}"

    package =
      write_package(root, app, "defmodule HexIsoBroken do\n  def broken, do: missing()\nend\n")

    assert {:error, message} =
             HexIsolatedInstall.install([{app, ">= 0.0.0", path: package}], [app],
               install_dir: install_dir
             )

    assert message =~ "Mix.install failed"
    assert message =~ "undefined function missing/0"
  end

  test "refuses an ebin reached through a symbolic link and adds no code path",
       %{root: root, install_dir: install_dir} do
    app = :"hex_iso_link_#{System.unique_integer([:positive])}"
    package = write_package(root, app, "defmodule HexIsoLinked do\nend\n")
    dep = {app, ">= 0.0.0", path: package}

    # Build once without host admission, then replace lib/<app> with a link to outside the root.
    prebuild(install_dir, dep)
    [app_dir] = Path.wildcard(Path.join(install_dir, "*/*/_build/*/lib/#{app}"))
    outside = Path.join(root, "outside")
    File.rename!(app_dir, outside)
    File.ln_s!(outside, app_dir)

    assert {:error, message} = HexIsolatedInstall.install([dep], [app], install_dir: install_dir)
    assert message =~ "not a real directory"

    refute Enum.any?(:code.get_path(), fn path ->
             path = List.to_string(path)
             path =~ install_dir or path =~ outside
           end)
  end

  test "makes the install directory private", %{install_dir: install_dir} do
    File.mkdir_p!(install_dir)
    File.chmod!(install_dir, 0o777)
    # The directory is prepared before dependencies are encoded, so an invalid dependency
    # stops the install without starting the child.
    assert {:error, "unsupported Hex extension dependency" <> _rest} =
             HexIsolatedInstall.install([:not_a_dependency], [], install_dir: install_dir)

    assert Bitwise.band(File.stat!(install_dir).mode, 0o777) == 0o700
  end

  test "refuses an install directory owned by another user", %{install_dir: install_dir} do
    File.mkdir_p!(install_dir)
    other_uid = File.stat!(install_dir).uid + 1

    assert {:error, message} =
             HexIsolatedInstall.install([:not_a_dependency], [],
               install_dir: install_dir,
               owner_uid: other_uid
             )

    assert message =~ "is not owned by the current user"
  end

  test "refuses a group- or world-writable install directory it cannot make private",
       %{install_dir: install_dir} do
    chflags = System.find_executable("chflags")

    # A user-immutable directory keeps its mode even for its owner; only macOS/BSD chflags does
    # this without root, so the check is exercised there.
    if chflags do
      File.mkdir_p!(install_dir)
      File.chmod!(install_dir, 0o777)
      {_out, 0} = System.cmd(chflags, ["uchg", install_dir])
      on_exit(fn -> System.cmd(chflags, ["nouchg", install_dir]) end)

      assert {:error, message} =
               HexIsolatedInstall.install([:not_a_dependency], [], install_dir: install_dir)

      assert message =~ "is group- or world-writable"
    end
  end

  test "the installer process does not see Minga provider secrets",
       %{root: root, install_dir: install_dir} do
    planted = %{
      "OPENAI_API_KEY" => "planted-openai",
      "ANTHROPIC_PLANTED_TOKEN" => "planted-anthropic",
      "MINGA_GATEWAY_TOKEN" => "planted-gateway",
      "HEX_PLANTED_SETTING" => "kept"
    }

    # The secret filter acts on the OS environment the child inherits, so the test plants there.
    previous = Map.new(planted, fn {name, _value} -> {name, System.get_env(name)} end)
    System.put_env(planted)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    suffix = System.unique_integer([:positive])
    app = :"hex_iso_env_#{suffix}"
    module = Module.concat([:"HexIsoEnv#{suffix}"])
    names = Map.keys(planted) |> Enum.sort()

    package =
      write_package(root, app, """
      defmodule #{inspect(module)} do
        @seen Map.new(#{inspect(names)}, &{&1, System.get_env(&1)})
        def seen, do: @seen
      end
      """)

    assert {:ok, _ebins} =
             HexIsolatedInstall.install([{app, ">= 0.0.0", path: package}], [app],
               install_dir: install_dir
             )

    assert module.seen() == %{
             "ANTHROPIC_PLANTED_TOKEN" => nil,
             "HEX_PLANTED_SETTING" => "kept",
             "MINGA_GATEWAY_TOKEN" => nil,
             "OPENAI_API_KEY" => nil
           }
  end

  test "redacts URL credentials in the installer output",
       %{root: root, install_dir: install_dir} do
    app = :"hex_iso_redact_#{System.unique_integer([:positive])}"

    package =
      write_package(root, app, """
      defmodule HexIsoRedact do
        raise "fetch failed for https://deploy:s3cret-token@git.example.com/repo.git"
      end
      """)

    assert {:error, message} =
             HexIsolatedInstall.install([{app, ">= 0.0.0", path: package}], [app],
               install_dir: install_dir
             )

    assert message =~ "https://[REDACTED]@git.example.com/repo.git"
    refute message =~ "s3cret-token"
  end

  test "a later install in this VM keeps the same version and refuses a different one",
       %{root: root, install_dir: install_dir} do
    suffix = System.unique_integer([:positive])
    app = :"hex_iso_version_#{suffix}"
    module = Module.concat([:"HexIsoVersion#{suffix}"])
    source = "defmodule #{inspect(module)} do\n  def version, do: 1\nend\n"
    package = write_package(root, app, source, version: "0.1.0")

    assert {:ok, ebins} =
             HexIsolatedInstall.install([{app, ">= 0.0.0", path: package}], [app],
               install_dir: install_dir
             )

    first = Enum.find(ebins, &String.ends_with?(&1, "/#{app}/ebin"))

    # A different dependency list builds in a new directory; the version is unchanged.
    assert {:ok, []} =
             HexIsolatedInstall.install([{app, ">= 0.1.0", path: package}], [app],
               install_dir: install_dir
             )

    write_package(root, app, source, version: "0.2.0")

    assert {:error, message} =
             HexIsolatedInstall.install([{app, "~> 0.2", path: package}], [app],
               install_dir: install_dir
             )

    assert message =~ "restart Minga to switch :#{app} from 0.1.0 to 0.2.0"
    assert List.to_string(:code.which(module)) =~ first

    assert [^first] =
             :code.get_path()
             |> Enum.map(&List.to_string/1)
             |> Enum.filter(&String.ends_with?(&1, "/#{app}/ebin"))
  end

  test "skips a shared dependency the host already provides", %{
    root: root,
    install_dir: install_dir
  } do
    fake_jason = write_package(root, :jason, "defmodule HexIsoFakeJason do\nend\n")
    host_jason = :code.lib_dir(:jason)
    app = :"hex_iso_shared_#{System.unique_integer([:positive])}"

    package =
      write_package(root, app, "defmodule HexIsoShared do\nend\n",
        deps: ["{:jason, path: #{inspect(fake_jason)}}"]
      )

    assert {:ok, ebins} =
             HexIsolatedInstall.install([{app, ">= 0.0.0", path: package}], [app],
               install_dir: install_dir
             )

    assert Enum.any?(ebins, &String.ends_with?(&1, "/#{app}/ebin"))
    refute Enum.any?(ebins, &String.ends_with?(&1, "/jason/ebin"))
    assert :code.lib_dir(:jason) == host_jason
  end

  test "refuses a declared extension application that the host already provides",
       %{root: root, install_dir: install_dir} do
    fake_jason = write_package(root, :jason, "defmodule HexIsoDeclaredJason do\nend\n")

    assert {:error, message} =
             HexIsolatedInstall.install([{:jason, ">= 0.0.0", path: fake_jason}], [:jason],
               install_dir: install_dir
             )

    assert message =~ "Hex extension application :jason conflicts with a host application"
    refute Enum.any?(:code.get_path(), &(List.to_string(&1) =~ install_dir))
  end

  defp prebuild(install_dir, {app, requirement, path: path}) do
    File.mkdir_p!(install_dir)
    report = Path.join(install_dir, "prebuild-report.json")

    request = %{
      "deps" => [
        %{"app" => "#{app}", "requirement" => requirement, "source" => "path", "value" => path}
      ],
      "install_dir" => install_dir,
      "force" => false,
      "report_path" => report
    }

    assert :ok = DisposableBeam.run(:hex_installer, request, install_dir, 120_000)
    assert {:ok, %{"status" => "ok"}} = report |> File.read!() |> JSON.decode()
  end

  defp write_package(root, app, source, opts \\ []) do
    dir = Path.join(root, Atom.to_string(app))
    File.mkdir_p!(Path.join(dir, "lib"))
    version = Keyword.get(opts, :version, "0.1.0")

    deps =
      Enum.join(
        ["{:minga_sdk, path: #{inspect(@sdk_path)}}" | Keyword.get(opts, :deps, [])],
        ", "
      )

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{Macro.camelize(Atom.to_string(app))}.MixProject do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: #{inspect(version)}, deps: [#{deps}]]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """)

    File.write!(Path.join([dir, "lib", "#{app}.ex"]), source)
    dir
  end

  defp start_admission do
    suffix = System.unique_integer([:positive])
    generation = :"hex_iso_generation_#{suffix}"
    admission = :"hex_iso_admission_#{suffix}"
    persistence_key = {__MODULE__, make_ref()}

    start_supervised!(
      {ArtifactGenerationState, name: generation, persistence_key: persistence_key}
    )

    start_supervised!({ArtifactAdmission, name: admission, state_owner: generation})
    on_exit(fn -> ArtifactGenerationState.reset_for_test(persistence_key) end)
    admission
  end
end
