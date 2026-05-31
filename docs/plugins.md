# Plugins

Plugins bundle agent components (hooks, skills, MCP servers, slash commands) in one directory with one manifest. Instead of declaring everything in your `config.exs`, drop a plugin directory and Minga loads it automatically.

Think of plugins as portable, reusable units of functionality. A plugin for linting, a plugin for database operations, a plugin for custom agent behavior. Each plugin is self-contained and can be shared with teammates or published.

---

## What plugins are

A plugin is a directory with a manifest (`plugin.json` or `.ex` file) and supporting files like hooks, skills, and MCP server executables. The manifest declares which components the plugin provides. Minga loads plugins at startup and merges them with config-declared components.

Plugins and config-declared components are equivalent. A hook declared in `plugin.json` behaves identically to a hook declared in `config.exs`. The only difference is how they're packaged and where they live.

---

## Two manifest formats

### Elixir format

A single `.ex` file using `use Minga.Extension.Agent`.

```elixir
defmodule MyPlugin do
  use Minga.Extension.Agent
  hook :session_start, command: "#{__DIR__}/hooks/hello.sh"
  skill "#{__DIR__}/skills/greet"
  slash_command :greet, "Say hello", command: "#{__DIR__}/hooks/hello.sh"

  @impl true
  def name, do: :my_plugin
  @impl true
  def description, do: "My custom plugin"
  @impl true
  def version, do: "0.1.0"
  @impl true
  def init(_config), do: {:ok, %{}}
end
```

Use `__DIR__` in paths so they work when the plugin is moved or symlinked.

### JSON format

A `plugin.json` file at the root.

```json
{
  "name": "my-plugin",
  "description": "My custom plugin",
  "version": "0.1.0",
  "hooks": [{"event": "session_start", "command": "${MINGA_PLUGIN_ROOT}/hooks/hello.sh"}],
  "skills": ["${MINGA_PLUGIN_ROOT}/skills/greet"],
  "slash_commands": [{"name": "greet", "description": "Say hello", "command": "${MINGA_PLUGIN_ROOT}/hooks/hello.sh"}]
}
```

Use `${MINGA_PLUGIN_ROOT}` in string paths. Minga replaces it with the actual plugin directory when loading.

---

## Component types

### Hooks

Fire at lifecycle events like session start or before a tool runs.

```elixir
hook :session_start, command: "#{__DIR__}/hooks/setup.sh"
hook :pre_tool_use, tool: "write_*", command: "#{__DIR__}/hooks/lint.sh"
```

Events: `:session_start`, `:session_end`, `:pre_tool_use`, `:post_tool_use`.

### Skills

Teach the agent how to do something. Point to a skill directory on disk.

```elixir
skill "#{__DIR__}/skills/database"
```

### MCP servers

Extend the agent with new capabilities.

```elixir
mcp_server :postgres, command: "#{__DIR__}/servers/postgres-mcp", args: ["--host", "localhost"]
```

### Slash commands

Quick actions the agent can invoke inline.

```elixir
slash_command :git_status, "Show git status", command: "#{__DIR__}/commands/git-status.sh"
```

---

## Path resolution

### Elixir: `__DIR__`

In a `.ex` file, `__DIR__` evaluates to the directory containing the file. It works at compile time and survives relocation.

```elixir
hook :session_start, command: "#{__DIR__}/hooks/hello.sh"
```

If you symlink or move the plugin directory, `__DIR__` keeps pointing to the right place because it was resolved when the module was compiled.

### JSON: `${MINGA_PLUGIN_ROOT}`

In JSON, `${MINGA_PLUGIN_ROOT}` is a placeholder string. Minga replaces it with the actual plugin directory path at load time.

```json
"command": "${MINGA_PLUGIN_ROOT}/hooks/hello.sh"
```

This works anywhere a string appears in the JSON, including nested objects and arrays. Minga does a simple find-replace before parsing hooks, skills, MCP servers, and slash commands.

---

## Plugin directories

Plugins live in two places: user scope (one copy per user) and project scope (one copy per project).

### User-scoped plugins

Available in all projects.

```
~/.config/minga/plugins/
├── my-plugin/
│   ├── plugin.json
│   ├── hooks/
│   │   └── setup.sh
│   └── skills/
│       └── greet/
│           └── skill.md
└── another-plugin/
    └── another_plugin.ex
```

If `XDG_CONFIG_HOME` is set, Minga uses `$XDG_CONFIG_HOME/minga/plugins/` instead.

### Project-scoped plugins

Available only in the current project.

```
.minga/plugins/
├── local-lint-rules/
│   └── plugin.json
└── project-data-tools/
    └── project_data_tools.ex
```

Both directories are created on demand. Minga checks both at startup.

### Override rules

If a user-scoped and project-scoped plugin have the same name, the project-scoped one wins. This lets you customize plugins per project while keeping a shared user baseline.

Example: You have `~/.config/minga/plugins/lint` with standard rules. In a strict project, you can create `.minga/plugins/lint` with stricter rules. When you change projects, Minga picks up the right version automatically.

---

## Trust model

Plugins run shell hooks and launch MCP servers. Both can execute arbitrary code. There is no sandboxing or permission system in v1.

**Only install plugins you trust.** A malicious plugin can read files, modify buffers, execute git commands, or anything else the shell can do.

When you add a plugin from a git repo or Hex package via `config.exs`, a confirmation prompt appears on first install. For plugins dropped into `.minga/plugins/` by hand, Minga assumes you know what you're doing.

Think of plugin trust the same way you think of Emacs package trust or shell script trust. If you're not sure what a plugin does, read its manifest and hook/command scripts before installing.

---

## How to create a plugin

1. Create a directory and choose a manifest format (`.ex` file or `plugin.json`).
2. Create subdirectories for hooks, skills, MCP servers, or commands.
3. Write your scripts and skill definitions.
4. Declare components in the manifest using the macros or JSON arrays.
5. Symlink or copy the directory to `~/.config/minga/plugins/` (user-scoped) or `.minga/plugins/` (project-scoped).
6. Restart Minga or press `SPC h r` to reload.

---

## Install and remove

### Install

Symlink or copy the plugin directory to either location.

```bash
# Symlink keeps the original as the source of truth
ln -s /path/to/my-plugin ~/.config/minga/plugins/my-plugin

# Copy makes the plugin independent of the source
cp -r /path/to/my-plugin ~/.config/minga/plugins/my-plugin
```

Symlinks are preferred because updates to the plugin automatically propagate.

Restart Minga or press `SPC h r` to reload plugins.

### Remove

Delete the plugin directory.

```bash
rm -rf ~/.config/minga/plugins/my-plugin
```

On the next session start or reload (`SPC h r`), the plugin and all its components are cleaned up automatically.

---

## Interaction with config.exs

Plugins are appended to config-declared components. If your `config.exs` declares a hook and a plugin declares the same hook event, both run.

**config.exs:**

```elixir
hook :session_start, command: "~/.config/minga/hooks/setup.sh"
```

**Plugin (hooks/hello.sh):**

```bash
#!/bin/bash
echo "Plugin loaded!"
```

Both hooks fire in order when the session starts. Execution order is: config hooks first, then plugins in load order (user plugins before project plugins, alphabetical within each scope).

The same applies to skills, MCP servers, and slash commands. You can have both config-declared and plugin-declared versions of the same component type, and they all coexist.

If you want to replace a config-declared component, use a project-scoped plugin with the same name. That plugin will be registered instead of (or in addition to) the config version, depending on the component type. For hooks and skills, both accumulate. For MCP servers and slash commands, project-scoped ones take precedence if they have the same name.

---

## Examples

See `examples/plugins/` for complete working examples. The `hello-world` plugin demonstrates JSON format with hooks and skills. The `hello-elixir` plugin demonstrates Elixir format with similar components.
