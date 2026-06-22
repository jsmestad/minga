defmodule MingaEditor.Agent.SemanticUI.BundledStatusNote do
  @moduledoc """
  Bundled low-risk agent status note published through the semantic UI registry.
  """

  use GenServer

  alias MingaEditor.Agent.SemanticUI.Registry

  @entry_id "agent-status-note"
  @source {:bundle, :agent_status_note}

  @typedoc "Bundled source for the agent status note contribution."
  @type source :: {:bundle, :agent_status_note}

  @doc "Returns the source used for the bundled agent status note."
  @spec source() :: source()
  def source, do: @source

  @doc "Returns the stable entry id for the bundled agent status note."
  @spec entry_id() :: String.t()
  def entry_id, do: @entry_id

  @doc "Starts the bundled status note registrar."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @impl true
  @spec init(keyword()) :: {:ok, Registry.table()} | {:stop, term()}
  def init(opts) do
    registry = Keyword.get(opts, :registry, Registry)

    case register(registry) do
      :ok -> {:ok, registry}
      {:error, reason} -> {:stop, {:agent_status_note_registration_failed, registry, reason}}
    end
  end

  @doc "Returns the semantic transcript contribution entries for this bundled source."
  @spec entries() :: [Registry.register_attrs()]
  def entries do
    [
      %{
        id: @entry_id,
        surface: :transcript_enrichment,
        target: :agent_chat,
        priority: 10,
        payload: {:system, "Agent UI registry online", :info},
        actions: [
          %{
            id: "open_agent",
            label: "Open agent panel",
            kind: :primary,
            editor_action: :toggle_agentic_view,
            payload: %{source: @entry_id}
          }
        ]
      }
    ]
  end

  @doc "Registers the bundled status note into the semantic UI registry."
  @spec register(Registry.table()) :: :ok | {:error, term()}
  def register(registry \\ Registry) when is_atom(registry) do
    Registry.register_many(registry, source(), entries())
  end

  @doc "Removes this bundled status note from the semantic UI registry."
  @spec unregister(Registry.table()) :: :ok
  def unregister(registry \\ Registry) when is_atom(registry) do
    Registry.unregister_source(registry, source())
  end

  @doc "Reloads this bundled status note without touching other agent state."
  @spec reload(Registry.table()) :: :ok | {:error, term()}
  def reload(registry \\ Registry) when is_atom(registry) do
    unregister(registry)
    register(registry)
  end
end
