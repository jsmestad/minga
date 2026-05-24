defmodule MingaAgent.Providers.NativeReadOnlyTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Providers.Native
  alias ReqLLM.Tool

  test "read_only provider filters final tool list and removes internal tools" do
    read_tool = tool("read_file")
    write_tool = tool("write_file")

    provider =
      start_supervised!(
        {Native,
         subscriber: self(),
         project_root: File.cwd!(),
         skip_api_key_env: true,
         provider: :test,
         model: "test",
         read_only?: true,
         tools: [read_tool, write_tool]},
        id: {:native_read_only, make_ref()}
      )

    names = provider |> Native.tools() |> Enum.map(& &1.name)

    assert names == ["read_file"]
    refute "write_file" in names
    refute "todo_write" in names
    refute "notebook_write" in names
  end

  test "tool_allowlist is enforced after read_only filtering" do
    provider =
      start_supervised!(
        {Native,
         subscriber: self(),
         project_root: File.cwd!(),
         skip_api_key_env: true,
         provider: :test,
         model: "test",
         read_only?: true,
         tool_allowlist: [],
         tools: [tool("read_file")]},
        id: {:native_read_only_allowlist, make_ref()}
      )

    assert Native.tools(provider) == []
  end

  test "read_only provider clears configured hooks" do
    hook = %Hook{event: :pre_tool_use, tool_pattern: "read_file", command: "policy"}
    config = %AgentConfig{agent_hooks: [hook]}

    provider =
      start_supervised!(
        {Native,
         subscriber: self(),
         project_root: File.cwd!(),
         skip_api_key_env: true,
         provider: :test,
         model: "test",
         read_only?: true,
         config: config,
         tools: [tool("read_file")]},
        id: {:native_read_only_hooks, make_ref()}
      )

    assert Native.agent_hooks(provider) == []
  end

  defp tool(name) do
    Tool.new!(
      name: name,
      description: name,
      parameter_schema: %{"type" => "object", "properties" => %{}},
      callback: fn _args -> {:ok, "ok"} end
    )
  end
end
