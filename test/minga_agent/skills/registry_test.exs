defmodule MingaAgent.Skills.RegistryTest do
  # async: false because these tests mutate the global agent skill contribution registry.
  use ExUnit.Case, async: false

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

  defp ensure_registry_started do
    if Process.whereis(Registry) == nil do
      start_supervised!(Registry)
    end
  end
end
