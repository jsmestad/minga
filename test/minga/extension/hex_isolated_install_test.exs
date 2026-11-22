defmodule Minga.Extension.HexIsolatedInstallTest do
  # Spawns real `erl` OS processes that run Mix.install/2, and appends to the global code path.
  use ExUnit.Case, async: false

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
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

  defp write_package(root, app, source) do
    dir = Path.join(root, Atom.to_string(app))
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{Macro.camelize(Atom.to_string(app))}.MixProject do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: "0.1.0", deps: [{:minga_sdk, path: #{inspect(@sdk_path)}}]]
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
