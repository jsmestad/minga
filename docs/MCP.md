# MCP servers

Minga can attach one Model Context Protocol (MCP) server to each native agent session. This is useful when you already have local tools exposed through MCP and want them to appear next to Minga's built-in file, shell, git, and LSP tools.

## Configure one stdio server

Set `:agent_mcp_server` in your Minga config. The value is a map with a display name, command, optional args, and optional environment variables.

```elixir
Minga.Config.set(:agent_mcp_server, %{
  name: "workspace",
  command: "node",
  args: ["/Users/me/tools/workspace-mcp/server.js"],
  env: %{
    "WORKSPACE_ROOT" => "/Users/me/code/my-project",
    "API_TOKEN" => System.fetch_env!("WORKSPACE_MCP_TOKEN")
  }
})
```

`name` and `command` are required strings. `args` defaults to `[]`. `env` defaults to `%{}` and must contain string keys and string values.

The native provider starts the server when the agent session starts. It speaks MCP over JSON lines on stdio, sends `initialize`, sends `notifications/initialized`, then calls `tools/list`. If any step fails, Minga adds a system error message and continues with the built-in tools only.

## Tool names

MCP tool names are prefixed before they are sent to the LLM so they are safe and do not collide with built-ins. A server named `workspace` with a tool named `find symbols` becomes:

```text
mcp_workspace__find_symbols
```

Minga keeps the original MCP tool name internally. When the LLM calls `mcp_workspace__find_symbols`, Minga sends `tools/call` to the MCP server with the original name, `find symbols`, and the arguments from the model.

MCP tools are treated as destructive by default when `:agent_tool_approval` is `:destructive`, so Minga asks before running them unless you add per-tool permissions.

## Worked example

The filesystem reference server is a good first smoke test because it exposes familiar file tools through MCP. Install Node.js, then point the server at the directory it is allowed to read and write:

```elixir
Minga.Config.set(:agent_mcp_server, %{
  name: "filesystem",
  command: "npx",
  args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/code/my-project"]
})
```

At session start, Minga lists the server tools and exposes them with the server prefix. For example, a filesystem tool named `read_file` becomes `mcp_filesystem__read_file`. The model can call that tool during a normal agent turn. The result is appended as a normal tool result, just like Minga's built-in `read_file` or `grep`.

If the server exits halfway through the session, Minga adds a system message naming the MCP server and the reason. The provider stays alive, removes the MCP tools from future LLM requests, and built-in tools keep working.
