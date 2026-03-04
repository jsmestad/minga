defmodule Minga.Extension do
  @moduledoc """
  Behaviour for Minga editor extensions.

  Extensions are self-contained Elixir modules that add functionality to
  the editor. Each extension runs under its own supervisor, so a crash in
  one extension never affects others or the editor itself.

  ## Implementing an extension

      defmodule MyExtension do
        use Minga.Extension

        @impl true
        def name, do: :my_extension

        @impl true
        def description, do: "Does something useful"

        @impl true
        def version, do: "0.1.0"

        @impl true
        def init(config) do
          # config is the keyword list from the extension declaration
          {:ok, %{greeting: Keyword.get(config, :greeting, "hello")}}
        end
      end

  ## Config declaration

      use Minga.Config

      extension :my_extension, path: "~/code/my_extension"
      extension :greeter, path: "~/code/greeter", greeting: "howdy"

  ## Lifecycle

  1. The extension module is compiled from the declared path
  2. `init/1` is called with the config keyword list (minus `:path`)
  3. The extension's `child_spec/1` is started under `Minga.Extension.Supervisor`
  4. On config reload (`SPC h r`), all extensions are stopped and re-loaded
  """

  @typedoc "Extension runtime status."
  @type extension_status :: :running | :stopped | :crashed | :load_error

  @typedoc "Extension metadata and runtime info."
  @type extension_info :: %{
          module: module(),
          path: String.t(),
          config: keyword(),
          status: extension_status(),
          pid: pid() | nil
        }

  @doc "The extension's unique name (atom)."
  @callback name() :: atom()

  @doc "A short human-readable description of what the extension does."
  @callback description() :: String.t()

  @doc "The extension's version string (e.g. `\"0.1.0\"`)."
  @callback version() :: String.t()

  @doc """
  Called when the extension is loaded. Receives the config keyword list
  from the extension declaration (with `:path` removed).

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

  @doc """
  Injects the `Minga.Extension` behaviour and a default `child_spec/1`.

  The default child_spec starts an Agent holding the extension's init state.
  Override `child_spec/1` for custom process trees.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Minga.Extension

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
  end
end
