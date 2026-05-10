defmodule MingaAgent.MCP.ToolTest do
  use ExUnit.Case, async: true

  alias MingaAgent.MCP.Tool

  test "safe names fit ReqLLM tool name limits" do
    safe_name =
      Tool.safe_name(
        String.duplicate("very-long-server-name-", 4),
        String.duplicate("very-long-tool-name-", 4)
      )

    assert String.length(safe_name) <= 64
    assert ReqLLM.Tool.valid_name?(safe_name)
  end

  test "duplicate long names stay unique and within ReqLLM limits" do
    tools = [
      %{"name" => String.duplicate("lookup-symbol-", 8)},
      %{"name" => String.duplicate("lookup_symbol_", 8)}
    ]

    names =
      "workspace"
      |> Tool.from_list(tools)
      |> Enum.map(& &1.safe_name)

    assert length(names) == length(Enum.uniq(names))
    assert Enum.all?(names, &(String.length(&1) <= 64))
    assert Enum.all?(names, &ReqLLM.Tool.valid_name?/1)
  end
end
