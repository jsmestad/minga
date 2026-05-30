defmodule Minga.Extension.Agent do
  @moduledoc """
  Agent surface for Minga extensions.

  This module provides the DSL macros and compile-time wiring for agent-specific extension components: hooks, skills, MCP servers, and slash commands.

  `use Minga.Extension.Agent` is the recommended way to define an extension that contributes agent-side features. It injects the `Minga.Extension` behaviour, registers compile-time accumulate attributes for each agent component, provides a default `child_spec/1`, and imports the agent DSL macros.

  Agent extensions can also declare config options with `option/3`, just like editor extensions.

  ## Types

  Hook specs are `{event, opts}` tuples where `event` is an atom like `:pre_tool_use` or `:session_start` and `opts` is a keyword list with keys like `:tool`, `:command`, etc.

  Skill specs are path strings pointing to a skill directory on disk.

  MCP server specs are `{name, opts}` tuples where `name` is an atom identifier and `opts` is a keyword list with keys like `:command` and `:args`.

  Slash command specs are `{name, description, opts}` tuples where `name` is an atom, `description` is a human-readable string, and `opts` is a keyword list with keys like `:command`.

  ## Usage

      defmodule MingaLint do
        use Minga.Extension.Agent

        option :auto_fix, :boolean,
          default: false,
          description: "Automatically apply lint fixes"

        hook :pre_tool_use, tool: "write_*", command: "hooks/lint.sh"
        hook :session_start, command: "hooks/hello.sh"

        skill "skills/greet"

        mcp_server :my_mcp, command: "servers/my-mcp", args: ["--port", "3000"]

        slash_command :my_cmd, "Runs my custom command", command: "commands/my-cmd.sh"

        @impl true
        def name, do: :minga_lint

        @impl true
        def description, do: "Linting hooks for agent sessions"

        @impl true
        def version, do: "0.1.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end

  For extensions that contribute editor-side components (commands, keybindings, modeline segments, capabilities), see `Minga.Extension.Editor`.
  """

  @doc """
  Injects the `Minga.Extension` behaviour, agent DSL macros, and a default `child_spec/1`.

  The injected macros are: `option/3`, `hook/2`, `skill/1`, `mcp_server/2`, and `slash_command/3`.

  At compile time, each macro accumulates declarations into module attributes. The `__before_compile__` hook then generates `__option_schema__/0`, `__hook_schema__/0`, `__skill_schema__/0`, `__mcp_server_schema__/0`, and `__slash_command_schema__/0` functions that the framework reads at load time.
  """
  defmacro __using__(_opts) do
    quote do
      unless Minga.Extension in (Module.get_attribute(__MODULE__, :behaviour) || []) do
        @behaviour Minga.Extension
      end

      Module.register_attribute(__MODULE__, :__extension_options__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_hooks__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_skills__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_mcp_servers__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_slash_commands__, accumulate: true)
      @before_compile Minga.Extension.Agent

      unless Module.defines?(__MODULE__, {:child_spec, 1}) do
        @doc false
        @spec child_spec(keyword()) :: Supervisor.child_spec()
        def child_spec(config) do
          %{
            id: __MODULE__,
            start: {Agent, :start_link, [fn -> config end]},
            restart: :permanent,
            type: :worker
          }
        end

        defoverridable child_spec: 1
      end

      import Minga.Extension.Macros, only: [option: 3]

      import Minga.Extension.Agent,
        only: [
          hook: 2,
          skill: 1,
          mcp_server: 2,
          slash_command: 3
        ]
    end
  end

  # option/3 is imported from Minga.Extension.Macros (shared with Editor).

  @doc """
  Declares a lifecycle hook this extension provides.

  Hooks fire at specific agent lifecycle events and can run shell commands or invoke functions.

  Accumulated at compile time and exposed via `__hook_schema__/0`.

  ## Options

  - `:command` (required) -- path to the script or executable to run
  - `:tool` -- glob pattern to match tool names (only for tool-related events)

  ## Examples

      hook :pre_tool_use, tool: "write_*", command: "hooks/lint.sh"
      hook :session_start, command: "hooks/hello.sh"
  """
  defmacro hook(event, opts) do
    quote do
      @__extension_hooks__ {unquote(event), unquote(opts)}
    end
  end

  @doc """
  Declares a skill directory this extension provides.

  Skills are directories containing agent instructions, prompts, and tool definitions that extend the agent's capabilities.

  Accumulated at compile time and exposed via `__skill_schema__/0`.

  ## Examples

      skill "skills/greet"
      skill "skills/refactor"
  """
  defmacro skill(path) do
    quote do
      @__extension_skills__ unquote(path)
    end
  end

  @doc """
  Declares an MCP server this extension provides.

  MCP (Model Context Protocol) servers expose tools and resources to the agent through a standardized protocol.

  Accumulated at compile time and exposed via `__mcp_server_schema__/0`.

  ## Options

  - `:command` (required) -- path to the server executable
  - `:args` -- list of command-line arguments (default: `[]`)

  ## Examples

      mcp_server :my_mcp, command: "servers/my-mcp", args: ["--port", "3000"]
      mcp_server :db_tools, command: "servers/db-tools"
  """
  defmacro mcp_server(name, opts) do
    quote do
      @__extension_mcp_servers__ {unquote(name), unquote(opts)}
    end
  end

  @doc """
  Declares a slash command this extension provides.

  Slash commands are user-invokable agent commands prefixed with `/` in chat interfaces.

  Accumulated at compile time and exposed via `__slash_command_schema__/0`.

  ## Options

  - `:command` (required) -- path to the script or executable to run

  ## Examples

      slash_command :my_cmd, "Runs my custom command", command: "commands/my-cmd.sh"
      slash_command :deploy, "Deploy the current branch", command: "commands/deploy.sh"
  """
  defmacro slash_command(name, description, opts) do
    quote do
      @__extension_slash_commands__ {unquote(name), unquote(description), unquote(opts)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :__extension_options__) || []
    hooks = Module.get_attribute(env.module, :__extension_hooks__) || []
    skills = Module.get_attribute(env.module, :__extension_skills__) || []
    mcp_servers = Module.get_attribute(env.module, :__extension_mcp_servers__) || []
    slash_commands = Module.get_attribute(env.module, :__extension_slash_commands__) || []
    # Accumulated attributes are in reverse order; restore declaration order
    options = Enum.reverse(options)
    hooks = Enum.reverse(hooks)
    skills = Enum.reverse(skills)
    mcp_servers = Enum.reverse(mcp_servers)
    slash_commands = Enum.reverse(slash_commands)

    quote do
      @doc false
      @spec __option_schema__() :: [Minga.Extension.option_spec()]
      def __option_schema__, do: unquote(Macro.escape(options))

      @doc false
      @spec __hook_schema__() :: [{atom(), keyword()}]
      def __hook_schema__, do: unquote(Macro.escape(hooks))

      @doc false
      @spec __skill_schema__() :: [String.t()]
      def __skill_schema__, do: unquote(Macro.escape(skills))

      @doc false
      @spec __mcp_server_schema__() :: [{atom(), keyword()}]
      def __mcp_server_schema__, do: unquote(Macro.escape(mcp_servers))

      @doc false
      @spec __slash_command_schema__() :: [{atom(), String.t(), keyword()}]
      def __slash_command_schema__, do: unquote(Macro.escape(slash_commands))
    end
  end
end
