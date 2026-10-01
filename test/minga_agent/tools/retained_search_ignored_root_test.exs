defmodule MingaAgent.Tools.RetainedSearchIgnoredRootTest do
  # Ignore-policy resolution runs real git processes and cannot run concurrently with other OS-process tests.
  use ExUnit.Case, async: false

  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStores
  alias MingaAgent.ArtifactSupervisor
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tools.Find
  alias MingaAgent.Tools.Grep

  @moduletag :tmp_dir

  test "ignored roots return complete recoverable empty captures rather than plain text", %{
    tmp_dir: dir
  } do
    store = start_store(dir)
    ignored = Path.join(dir, "node_modules")
    File.mkdir_p!(ignored)
    File.write!(Path.join(ignored, "match.txt"), "needle\n")

    for {tool, pattern, name} <- [{Find, "*", "find"}, {Grep, "needle", "grep"}] do
      assert {:ok, %Output{} = output} =
               tool.capture(pattern, ignored, %{},
                 artifact_store: store,
                 capture_key: {:delivery, "ignored-root", name},
                 filter_root: ignored
               )

      assert output.capture == :complete
      assert output.reference.items == 0
      assert output.selection.total == 0
      assert {:ok, %{bytes: ""}} = ArtifactStore.fetch(store, output.reference, output.selection)
    end
  end

  test "captured search and discovery retain matches while excluding ignored paths", %{
    tmp_dir: dir
  } do
    store = start_store(dir)
    project = Path.join(dir, "project")
    ignored = Path.join(project, "node_modules")
    File.mkdir_p!(ignored)
    assert {_output, 0} = System.cmd("git", ["init", "-q", project])
    File.write!(Path.join(project, "keep.txt"), "needle\n")
    File.write!(Path.join(ignored, "hidden.txt"), "needle\n")

    for {tool, pattern, name} <- [{Find, "*.txt", "find"}, {Grep, "needle", "grep"}] do
      assert {:ok, %Output{} = output} =
               tool.capture(pattern, project, %{},
                 artifact_store: store,
                 capture_key: {:delivery, "matching-root", name},
                 filter_root: project
               )

      assert output.capture == :complete
      assert output.reference.items == 1

      assert {:ok, %{bytes: bytes}} =
               ArtifactStore.fetch(store, output.reference, output.selection)

      assert bytes =~ "keep.txt"
      refute bytes =~ "hidden.txt"
      if tool == Grep, do: assert(bytes =~ ":1:needle")
    end
  end

  defp start_store(dir) do
    suffix = System.unique_integer([:positive])

    opts = [
      name: Module.concat(__MODULE__, "Supervisor#{suffix}"),
      root: Path.join(dir, "artifacts"),
      quota: Module.concat(__MODULE__, "Quota#{suffix}"),
      registry: Module.concat(__MODULE__, "Registry#{suffix}"),
      store_supervisor: Module.concat(__MODULE__, "Stores#{suffix}")
    ]

    start_supervised!({ArtifactSupervisor, opts})
    {:ok, runtime} = ArtifactSupervisor.runtime(opts)
    {:ok, store} = ArtifactStores.ensure_record("ignored-search", runtime)
    store
  end
end
