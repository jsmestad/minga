# MCP servers

Minga can attach multiple Model Context Protocol (MCP) servers to each native agent session. This is useful when your workflow spans separate local tools for files, GitHub, Linear, browsers, databases, or internal systems, and you want those tools to appear next to Minga's built-in file, shell, git, and LSP tools.

## Configure stdio servers

Set `:agent_mcp_servers` in your Minga config. The value is a list of maps. Each map has a stable display name, launch command, optional args, optional environment variables, and an optional `enabled` flag.

```elixir
Minga.Config.set(:agent_mcp_servers, [
  %{
    name: "workspace",
    command: "node",
    args: ["/Users/me/tools/workspace-mcp/server.js"],
    env: %{
      "WORKSPACE_ROOT" => "/Users/me/code/my-project",
      "API_TOKEN" => System.fetch_env!("WORKSPACE_MCP_TOKEN")
    }
  },
  %{
    name: "github",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-github"],
    env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => System.fetch_env!("GITHUB_TOKEN")}
  }
])
```

`name` and `command` are required strings for enabled servers. `args` defaults to `[]`. `env` defaults to `%{}` and may use string or atom keys, but values must be strings. Server names must be unique because they become part of the provider-facing tool name.

Use `enabled: false` to keep a server in your config without launching it:

```elixir
Minga.Config.set(:agent_mcp_servers, [
  %{name: "workspace", command: "node", args: ["/Users/me/tools/workspace-mcp/server.js"]},
  %{name: "browser", enabled: false}
])
```

Disabled entries are ignored at session start, so you can leave incomplete or temporarily unavailable server configs in place while you work.

The native provider starts enabled servers when the agent session starts. Each server launches independently. For every healthy server, Minga speaks MCP over JSON lines on stdio, sends `initialize`, sends `notifications/initialized`, then calls `tools/list`. If one server fails, Minga adds a system error message naming that server and continues with built-in tools plus tools from the other healthy MCP servers.

## Tool names

MCP tool names are prefixed before they are sent to the LLM so they are safe and do not collide with built-ins or tools from another MCP server. A server named `workspace` with a tool named `find symbols` becomes:

```text
mcp_workspace__find_symbols
```

The prefix is based on the configured server name. Minga sanitizes characters that model providers do not allow in tool names. If two generated names still collide, Minga adds a numeric suffix to the later tool name.

Minga keeps the original MCP tool name internally. When the LLM calls `mcp_workspace__find_symbols`, Minga sends `tools/call` to the `workspace` MCP server with the original name, `find symbols`, and the arguments from the model.

MCP tools are treated as destructive by default when `:agent_tool_approval` is `:destructive`, so Minga asks before running them unless you add per-tool permissions.

## Worked example

The filesystem reference server is a good first smoke test because it exposes familiar file tools through MCP. Install Node.js, then point the server at the directory it is allowed to read and write:

```elixir
Minga.Config.set(:agent_mcp_servers, [
  %{
    name: "filesystem",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/code/my-project"]
  }
])
```

At session start, Minga lists the server tools and exposes them with the server prefix. For example, a filesystem tool named `read_file` becomes `mcp_filesystem__read_file`. The model can call that tool during a normal agent turn. The result is appended as a normal tool result, just like Minga's built-in `read_file` or `grep`.

If one server exits halfway through the session, Minga adds a system message naming the MCP server and the reason. The provider stays alive, removes only that server's MCP tools from future LLM requests, and built-in tools plus other healthy MCP servers keep working.
