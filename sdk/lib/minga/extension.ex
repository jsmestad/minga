defmodule Minga.Extension do
  @moduledoc """
  Behaviour and DSL for Minga editor extensions.

  Extensions are self-contained Elixir modules that add functionality to
  the editor. Each extension runs under its own supervisor, so a crash in
  one extension never affects others or the editor itself.

  ## Implementing an extension

      defmodule MingaOrg do
        use Minga.Extension

        option :conceal, :boolean,
          default: true,
          description: "Hide markup delimiters and show styled content"

        option :todo_keywords, :string_list,
          default: ["TODO", "DONE"],
          description: "TODO keyword cycle sequence"

        command :org_cycle_todo, "Cycle TODO keyword",
          execute: {MingaOrg.Todo, :cycle},
          requires_buffer: true

        command :org_toggle_checkbox, "Toggle checkbox",
          execute: {MingaOrg.Checkbox, :toggle},
          requires_buffer: true

        keybind :normal, "SPC m t", :org_cycle_todo, "Cycle TODO", filetype: :org
        keybind :normal, "SPC m x", :org_toggle_checkbox, "Toggle checkbox", filetype: :org

        @impl true
        def name, do: :minga_org

        @impl true
        def description, do: "Org-mode support"

        @impl true
        def version, do: "0.1.0"

        @impl true
        def init(_config), do: {:ok, %{}}
      end

  Commands and keybindings declared with `command/3` and `keybind/4` are
  auto-registered by the framework when the extension loads. Extensions
  that need runtime-dynamic commands can still call the source-owned
  `Minga.Command.Registry.register/5` and `Minga.Keymap.Active.bind/6`
  APIs directly from `init/1`.

  ## Config declaration

      use Minga.Config

      extension :minga_org, git: "https://github.com/jsmestad/minga-org",
        conceal: false,
        pretty_bullets: true

  Options declared with `option/3` are validated against their type at
  load time. Users get clear errors for type mismatches. Unknown keys
  produce a warning log.

  ## Reading options at runtime

      Minga.Config.get_extension_option(:minga_org, :conceal)
      # => false

  ## Lifecycle

  1. The extension module is compiled from the declared path
  2. Options from the extension declaration are validated against the schema
  3. `init/1` is called with the config keyword list (minus `:path`)
  4. The extension's `child_spec/1` is started under `Minga.Extension.Supervisor`
  5. On config reload (`SPC h r`), all extensions are stopped and re-loaded
  """

  @typedoc "Extension runtime status."
  @type extension_status :: :running | :stopped | :crashed | :load_error

  @typedoc "Extension metadata and runtime info. See `Minga.Extension.Entry`."
  @type extension_info :: Minga.Extension.Entry.t()

  @doc "The extension's unique name (atom)."
  @callback name() :: atom()

  @doc "A short human-readable description of what the extension does."
  @callback description() :: String.t()

  @doc "The extension's version string (e.g. `\"0.1.0\"`)."
  @callback version() :: String.t()

  @doc """
  Called when the extension is loaded. Receives the config keyword list
  from the extension declaration (with source keys like `:path` removed).

  Return `{:ok, state}` to start successfully, or `{:error, reason}` to
  report a load failure without crashing the editor.
  """
  @callback init(config :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Optional. Returns a child spec for the extension's supervision subtree.

  The default implementation (provided by `use Minga.Extension`) starts a simple Agent that holds the validated config keyword list. The value returned by `init/1` is setup-only and is not handed to the default child process. Override this if your extension needs a custom GenServer, persisted runtime state, multiple processes, or a full supervision tree.
  """
  @callback child_spec(config :: keyword()) :: Supervisor.child_spec()

  @optional_callbacks [child_spec: 1]

  @typedoc """
  A single option specification: `{name, type, default, description}`.

  The type descriptor uses the same types as `Minga.Config.Options`:
  `:boolean`, `:pos_integer`, `:string`, `:string_list`, `{:enum, [atoms]}`, etc.

  The doc string is used by `SPC h v` (describe option) and other
  introspection features.
  """
  @type option_spec ::
          {atom(), Minga.Config.type_descriptor(), term(), description :: String.t()}

  @typedoc """
  A single command specification: `{name, description, opts}`.

  The opts keyword list supports:

  * `:execute` (required) — `{Module, :function}` MFA tuple. The function
    receives editor state and returns new state. Extensions that need
    config should call `Minga.Config.Options.get_extension_option/2`
    inside the function body.
  * `:requires_buffer` — when `true`, command is skipped if no buffer
    is active (default: `false`)
  """
  @type command_spec :: {atom(), String.t(), keyword()}

  @typedoc """
  Vim modes that extensions can bind keys in.

  Extensions bindable modes are the user-facing editing modes. Internal
  modes like `:search_prompt`, `:substitute_confirm`, and `:extension_confirm`
  are framework internals that extensions should not bind into.
  """
  @type bindable_mode :: :normal | :insert | :visual | :operator_pending

  @typedoc """
  A single keybinding specification: `{mode, key_string, command, description, opts}`.

  The mode must be a `bindable_mode` (`:normal`, `:insert`, `:visual`,
  or `:operator_pending`). The key string uses the same format as
  `Minga.Keymap.Active.bind/5` (e.g. `"SPC m t"`, `"M-h"`, `"TAB"`).
  Opts supports `:filetype` for scoping.
  """
  @type keybind_spec :: {bindable_mode(), String.t(), atom(), String.t(), keyword()}

  @typedoc "A modeline segment declaration: `{name, opts, {module, function}}`."
  @type modeline_segment_spec :: {atom(), keyword(), {module(), atom()}}

  @typedoc "A declared runtime or UI capability: `{family, value}`."
  @type capability_spec :: {atom(), term()}

  @doc "Builds a public manifest for a loaded extension module."
  @spec manifest(module(), Minga.Extension.Manifest.source_type()) :: Minga.Extension.Manifest.t()
  def manifest(module, source) when is_atom(module) and source in [:path, :git, :hex] do
    Minga.Extension.Manifest.from_module(module, source)
  end

  @doc """
  Injects the `Minga.Extension` behaviour, DSL macros (`option/3`,
  `command/3`, `keybind/4`, `keybind/5`), and a default `child_spec/1`.

  ## The `option` macro

  Declares a typed config option the extension accepts:

      option :conceal, :boolean, default: true
      option :heading_bullets, :string_list, default: ["◉", "○", "◈", "◇"]

  At compile time, these are accumulated into `__option_schema__/0`,
  a generated function the framework reads at load time to validate
  user config and register options in ETS.

  ## The `command` macro

  Declares an editor command the extension provides:

      command :org_cycle_todo, "Cycle TODO keyword",
        execute: {MingaOrg.Todo, :cycle},
        requires_buffer: true

  Accumulated into `__command_schema__/0`. The framework registers
  these in `Minga.Command.Registry` when the extension loads. The
  execute MFA must be a `{Module, :function}` tuple whose function
  accepts editor state and returns new state.

  ## The `keybind` macro

  Declares a keybinding the extension provides:

      keybind :normal, "SPC m t", :org_cycle_todo, "Cycle TODO", filetype: :org

  Accumulated into `__keybind_schema__/0`. The framework registers
  these in `Minga.Keymap.Active` when the extension loads.

  ## Supported option types

  `:boolean`, `:pos_integer`, `:non_neg_integer`, `:integer`, `:string`,
  `:string_or_nil`, `:string_list`, `:atom`, `{:enum, [atoms]}`,
  `:map_or_nil`, `:any`.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Minga.Extension
      Module.register_attribute(__MODULE__, :__extension_options__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_commands__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_keybinds__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_modeline_segments__, accumulate: true)
      Module.register_attribute(__MODULE__, :__extension_capabilities__, accumulate: true)
      @before_compile Minga.Extension

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

      import Minga.Extension,
        only: [
          option: 3,
          command: 3,
          keybind: 4,
          keybind: 5,
          modeline_segment: 2,
          modeline_segment: 3,
          capability: 2
        ]
    end
  end

  @doc """
  Declares a typed config option for this extension.

  Accumulated at compile time and exposed via `__option_schema__/0`.

  ## Options

  - `:default` (required) — the default value when the user doesn't set it
  - `:description` (required) — a short human-readable description shown by `SPC h v`

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

  - `:execute` (required) — `{Module, :function}` MFA tuple. The function
    receives editor state and returns new state.
  - `:requires_buffer` — when `true`, command is skipped if no buffer
    is active (default: `false`)

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

  @doc false
  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :__extension_options__) || []
    commands = Module.get_attribute(env.module, :__extension_commands__) || []
    keybinds = Module.get_attribute(env.module, :__extension_keybinds__) || []
    modeline_segments = Module.get_attribute(env.module, :__extension_modeline_segments__) || []
    capabilities = Module.get_attribute(env.module, :__extension_capabilities__) || []
    # Accumulated attributes are in reverse order; restore declaration order
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
    end
  end
end
