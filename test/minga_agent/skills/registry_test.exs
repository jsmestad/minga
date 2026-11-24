defmodule MingaAgent.Skills.RegistryTest do
  # async: false because these tests mutate the global agent skill contribution registry.
  use ExUnit.Case, async: false

  alias Minga.Extension.Entry
  alias Minga.Extension.Manifest
  alias Minga.Extension.Registry, as: ExtRegistry
  alias MingaAgent.Skills
  alias MingaAgent.Skills.Registry

  @source {:extension, :skill_registry_test}
  @moduletag :tmp_dir

  setup do
    ensure_registry_started()
    Registry.unregister_source(@source)

    on_exit(fn ->
      Registry.unregister_source(@source)
    end)

    :ok
  end

  test "extension skill paths are source-owned and discoverable", %{tmp_dir: dir} do
    skill_dir = Path.join(dir, "skills/hello")
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: hello
    description: Hello from extension
    ---

    Use a friendly greeting.
    """)

    assert :ok = Registry.register_many(@source, ["skills/hello"], root: dir)

    assert [%{source: @source, path: ^skill_dir}] = Registry.entries()
    assert {:ok, %{name: "hello", source: :extension}} = Skills.find("hello")

    assert :ok = Registry.unregister_source(@source)
    assert Registry.entries() == []
  end

  test "skills of running path and Git extensions resolve under their source directory", %{
    tmp_dir: dir
  } do
    path_root = Path.join(dir, "path_ext")
    checkout = Path.join(dir, "git_checkout")
    suffix = System.unique_integer([:positive])
    path_name = :"skill_seed_path_#{suffix}"
    git_name = :"skill_seed_git_#{suffix}"

    :ok = ExtRegistry.register(path_name, path_root, [])
    :ok = ExtRegistry.register_git(git_name, "https://example.com/skills.git", [])
    :ok = ExtRegistry.update_entry(git_name, &Entry.resolve_git_path(&1, checkout))

    on_exit(fn ->
      ExtRegistry.unregister(path_name)
      ExtRegistry.unregister(git_name)
    end)

    # The loaded module of a compiled extension lives in the compile cache, away from its source.
    for name <- [path_name, git_name] do
      manifest = %Manifest{name: name, version: "1.0.0", source: :path, skills: ["skills/hello"]}

      :ok =
        ExtRegistry.update(name,
          status: :running,
          manifest: manifest,
          module: Minga.Extension.Entry
        )
    end

    seeded = start_supervised!({Registry, name: :"skill_seed_registry_#{suffix}"})
    paths = Registry.entries(seeded) |> Map.new(&{&1.source, &1.path})

    assert paths[{:extension, path_name}] == Path.join(path_root, "skills/hello")
    assert paths[{:extension, git_name}] == Path.join(checkout, "skills/hello")
  end

  defp ensure_registry_started do
    if Process.whereis(Registry) == nil do
      start_supervised!(Registry)
    end
  end
end
