defmodule Minga.Extension.Editor do
  @moduledoc """
  Editor surface for Minga extensions.

  This module provides the DSL macros and compile-time wiring for editor-specific extension components: options, commands, keybindings, modeline segments, and capabilities.

  `use Minga.Extension.Editor` is the recommended way to define an extension that contributes editor UI and interaction features. It injects the `Minga.Extension` behaviour, registers compile-time accumulate attributes for each editor component, provides a default `child_spec/1`, and imports the editor DSL macros.

  ## Usage

      defmodule MingaOrg do
        use Minga.Extension.Editor

        option :conceal, :boolean,
          default: true,
          description: "Hide markup delimiters and show styled content"

        command :org_cycle_todo, "Cycle TODO keyword",
          execute: {MingaOrg.Todo, :cycle},
          requires_buffer: true

        keybind :normal, "SPC m t", :org_cycle_todo, "Cycle TODO", filetype: :org

        modeline_segment :word_count, side: :right, priority: 50 do
          if ctx.data.filetype in [:markdown, :text, :org] do
            {" WORDS ", ctx.info_fg, ctx.bar_bg, [], nil}
          end
        end

        capability :filetype, :org

        @impl true
        def name, do: :minga_org

        @impl true
        def description, do: "Org-mode support"

        @impl true
        def version, do: "0.1.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end

  For extensions that contribute agent-side components (hooks, skills, MCP servers, slash commands), see `Minga.Extension.Agent`.
  """

  @doc """
  Injects the `Minga.Extension` behaviour, editor DSL macros, and a default `child_spec/1`.

  The injected macros are: `option/3`, `command/3`, `keybind/4`, `keybind/5`, `modeline_segment/2`, `modeline_segment/3`, and `capability/2`.

  At compile time, each macro accumulates declarations into module attributes. The `__before_compile__` hook then generates `__option_schema__/0`, `__command_schema__/0`, `__keybind_schema__/0`, `__modeline_segment_schema__/0`, and `__capability_schema__/0` functions that the framework reads at load time.
  """
  defmacro __using__(_opts) do
    quote do
      unless Minga.Extension in (Module.get_attribute(__MODULE__, :behaviour) || []) do
        @behaviour Minga.Extension
      end

      Module.register_attribute(__MODULE__, :__extension_options__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_keybinds__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_modeline_segments__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_capabilities__, accumulate: true)
      Module.put_attribute(__MODULE__, :__extension_load_policy__, :eager)
      @before_compile Minga.Extension.Editor

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

      import Minga.Extension.Editor,
        only: [
          option: 3,
          command: 3,
          keybind: 4,
          keybind: 5,
          modeline_segment: 2,
          modeline_segment: 3,
          capability: 2,
          load_policy: 1
        ]
    end
  end

  @doc """
  Declares a typed config option for this extension.

  Accumulated at compile time and exposed via `__option_schema__/0`.

  ## Options

  - `:default` (required) -- the default value when the user doesn't set it
  - `:description` (required) -- a short human-readable description shown by `SPC h v`

  ## Examples

      option :conceal, :boolean,
        default: true,
        description: "Hide markup delimiters and show styled content"

      option :format, {:enum, [:html, :pdf, :md]},
        default: :html,
        description: "Default export format"

      option :heading_bullets, :string_list,
        default: ["◉", "○"],
        description: "Unicode bullets for heading levels (cycles when depth exceeds list length)"
  """
  defmacro option(name, type, opts) do
    quote do
      @__extension_options__ {
        unquote(name),
        unquote(type),
        Keyword.fetch!(unquote(opts), :default),
        Keyword.fetch!(unquote(opts), :description)
      }
    end
  end

  @doc """
  Declares an editor command this extension provides.

  Accumulated at compile time and exposed via `__command_schema__/0`.
  The framework auto-registers these commands when the extension loads.

  ## Options

  - `:execute` (required) -- `{Module, :function}` MFA tuple. The function receives editor state and returns new state.
  - `:requires_buffer` -- when `true`, command is skipped if no buffer is active (default: `false`)

  ## Examples

      command :org_cycle_todo, "Cycle TODO keyword",
        execute: {MingaOrg.Todo, :cycle},
        requires_buffer: true

      command :org_toggle_checkbox, "Toggle checkbox",
        execute: {MingaOrg.Checkbox, :toggle},
        requires_buffer: true
  """
  defmacro command(name, description, opts) do
    quote do
      @__extension_commands__ {unquote(name), unquote(description), unquote(opts)}
    end
  end

  @doc """
  Declares a modeline segment this extension provides.

  The block receives `ctx`, the same context map used by built-in modeline segments, and returns a segment tuple, a list of segment tuples, `nil`, or `[]`.

  ## Examples

      modeline_segment :word_count, side: :right, priority: 50 do
        if ctx.data.filetype in [:markdown, :text, :org] do
          {" WORDS ", ctx.info_fg, ctx.bar_bg, [], nil}
        end
      end
  """
  defmacro modeline_segment(name, opts \\ [], do: block) do
    fun_name = :"__modeline_segment_#{name}__"

    quote do
      @__extension_modeline_segments__ {unquote(name), unquote(opts),
                                        {__MODULE__, unquote(fun_name)}}

      @doc false
      @spec unquote(fun_name)(map()) :: term()
      def unquote(fun_name)(var!(ctx)) do
        unquote(block)
      end
    end
  end

  @doc """
  Declares a runtime or UI capability this extension uses.

  Capabilities are declarative and are available through `Minga.Extension.Manifest` before `init/1` runs. They should describe contribution surfaces or runtime needs, not perform side effects.
  """
  defmacro capability(family, value) do
    quote do
      @__extension_capabilities__ {unquote(family), unquote(value)}
    end
  end

  @doc """
  Declares a keybinding this extension provides.

  Accumulated at compile time and exposed via `__keybind_schema__/0`.
  The framework auto-registers these keybindings when the extension loads.

  ## Examples

      keybind :normal, "SPC m t", :org_cycle_todo, "Cycle TODO"
      keybind :normal, "M-h", :org_promote_heading, "Promote heading", filetype: :org
  """
  defmacro keybind(mode, key_string, command_name, description) do
    quote do
      @__extension_keybinds__ {unquote(mode), unquote(key_string), unquote(command_name),
                               unquote(description), []}
    end
  end

  @doc false
  defmacro keybind(mode, key_string, command_name, description, opts) do
    quote do
      @__extension_keybinds__ {unquote(mode), unquote(key_string), unquote(command_name),
                               unquote(description), unquote(opts)}
    end
  end

  @doc """
  Sets the extension's load policy.

  See `Minga.Extension` for supported policies and examples.
  """
  defmacro load_policy(policy) do
    quote do
      @__extension_load_policy__ unquote(policy)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :__extension_options__) || []
    commands = Module.get_attribute(env.module, :__extension_commands__) || []
    keybinds = Module.get_attribute(env.module, :__extension_keybinds__) || []
    modeline_segments = Module.get_attribute(env.module, :__extension_modeline_segments__) || []
    capabilities = Module.get_attribute(env.module, :__extension_capabilities__) || []
    load_policy = Module.get_attribute(env.module, :__extension_load_policy__) || :eager
    options = Enum.reverse(options)
    commands = Enum.reverse(commands)
    keybinds = Enum.reverse(keybinds)
    modeline_segments = Enum.reverse(modeline_segments)
    capabilities = Enum.reverse(capabilities)

    quote do
      @doc false
      @spec __option_schema__() :: [Minga.Extension.option_spec()]
      def __option_schema__, do: unquote(Macro.escape(options))

      @doc false
      @spec __command_schema__() :: [Minga.Extension.command_spec()]
      def __command_schema__, do: unquote(Macro.escape(commands))

      @doc false
      @spec __keybind_schema__() :: [Minga.Extension.keybind_spec()]
      def __keybind_schema__, do: unquote(Macro.escape(keybinds))

      @doc false
      @spec __modeline_segment_schema__() :: [Minga.Extension.modeline_segment_spec()]
      def __modeline_segment_schema__, do: unquote(Macro.escape(modeline_segments))

      @doc false
      @spec __capability_schema__() :: [Minga.Extension.capability_spec()]
      def __capability_schema__, do: unquote(Macro.escape(capabilities))

      @doc false
      @spec __load_policy__() :: Minga.Extension.load_policy()
      def __load_policy__, do: unquote(Macro.escape(load_policy))
    end
  end
end
