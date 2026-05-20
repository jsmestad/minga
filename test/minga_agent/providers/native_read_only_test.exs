defmodule MingaAgent.Providers.NativeReadOnlyTest do
  use ExUnit.Case, async: true

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

    %{tools: tools} = :sys.get_state(provider)
    names = Enum.map(tools, & &1.name)

    assert names == ["read_file"]
    refute "write_file" in names
    refute "todo_write" in names
    refute "notebook_write" in names
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
