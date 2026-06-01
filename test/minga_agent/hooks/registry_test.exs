defmodule MingaAgent.Hooks.RegistryTest do
  # async: false because these tests mutate the global agent hook contribution registry.
  use ExUnit.Case, async: false

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.Registry

  @source {:extension, :hook_registry_test}

  setup do
    ensure_registry_started()
    Registry.unregister_source(@source)

    on_exit(fn ->
      Registry.unregister_source(@source)
    end)

    :ok
  end

  test "register_many normalizes extension hooks with source metadata" do
    assert :ok =
             Registry.register_many(@source, [
               {:pre_tool_use, [tool: "write_*", command: "hooks/lint.sh"]},
               {:session_start, [command: "hooks/start.sh"]}
             ])

    hooks = Registry.all()
    assert [%Hook{}, %Hook{}] = hooks
    assert Enum.map(hooks, & &1.extension_source) == [:hook_registry_test, :hook_registry_test]
    assert Enum.map(hooks, & &1.command) == ["hooks/lint.sh", "hooks/start.sh"]
  end

  test "AgentConfig.resolve includes source-owned registry hooks once" do
    assert :ok = Registry.register_many(@source, [{:session_start, [command: "hooks/start.sh"]}])

    config = AgentConfig.resolve()
    matching = Enum.filter(config.agent_hooks, &(&1.command == "hooks/start.sh"))

    assert length(matching) == 1
  end

  defp ensure_registry_started do
    if Process.whereis(Registry) == nil do
      start_supervised!(Registry)
    end
  end
end
