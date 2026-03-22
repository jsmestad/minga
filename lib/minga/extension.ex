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

        option :pretty_bullets, :boolean,
          default: true,
          description: "Replace heading stars with Unicode bullets"

        option :heading_bullets, :string_list,
          default: ["◉", "○", "◈", "◇"],
          description: "Unicode bullets for heading levels (cycles when depth exceeds list)"

        option :todo_keywords, :string_list,
          default: ["TODO", "DONE"],
          description: "TODO keyword cycle sequence"

        @impl true
        def name, do: :minga_org

        @impl true
        def description, do: "Org-mode support"

        @impl true
        def version, do: "0.1.0"

        @impl true
        def init(config) do
          todo_keywords = Keyword.get(config, :todo_keywords, ["TODO", "DONE"])
          {:ok, %{todo_keywords: todo_keywords}}
        end
      end

  ## Config declaration

      use Minga.Config

      extension :minga_org, git: "https://github.com/jsmestad/minga-org",
        conceal: false,
        pretty_bullets: true

  Options declared with `option/3` are validated against their type at
  load time. Users get clear errors for type mismatches. Unknown keys
  produce a warning log.

  ## Reading options at runtime

      Minga.Config.Options.get_extension_option(:minga_org, :conceal)
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

  The default implementation (provided by `use Minga.Extension`) starts
  a simple Agent that holds the state returned by `init/1`. Override this
  if your extension needs a custom GenServer, multiple processes, or a
  full supervision tree.
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
          {atom(), Minga.Config.Options.type_descriptor(), term(), description :: String.t()}

  @doc """
  Injects the `Minga.Extension` behaviour, the `option/3` DSL macro,
  and a default `child_spec/1`.

  ## The `option` macro

  Declares a typed config option the extension accepts:

      option :conceal, :boolean, default: true
      option :heading_bullets, :string_list, default: ["◉", "○", "◈", "◇"]

  At compile time, these are accumulated into `__option_schema__/0`,
  a generated function the framework reads at load time to validate
  user config and register options in ETS.

  ## Supported types

  `:boolean`, `:pos_integer`, `:non_neg_integer`, `:integer`, `:string`,
  `:string_or_nil`, `:string_list`, `:atom`, `{:enum, [atoms]}`,
  `:map_or_nil`, `:any`.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Minga.Extension
      Module.register_attribute(__MODULE__, :__extension_options__, accumulate: true)
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

      import Minga.Extension, only: [option: 3]
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

  @doc false
  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :__extension_options__) || []
    # Accumulated attributes are in reverse order; restore declaration order
    options = Enum.reverse(options)

    quote do
      @doc false
      @spec __option_schema__() :: [Minga.Extension.option_spec()]
      def __option_schema__, do: unquote(Macro.escape(options))
    end
  end
end
