defmodule MingaEditor.State.ExtensionSurfaces do
  @moduledoc """
  Per-editor registries through which extensions contribute behavior and UI.

  Keeping registry identities together makes editor isolation explicit without
  moving daemon-singleton extension lifecycle into the Editor process.
  """

  @type t :: %__MODULE__{
          events_registry: Minga.Events.registry(),
          sidebar_registry: MingaEditor.Extension.Sidebar.table(),
          agent_semantic_ui_registry: MingaEditor.Agent.SemanticUI.Registry.table()
        }

  defstruct events_registry: Minga.EventBus,
            sidebar_registry: MingaEditor.Extension.Sidebar,
            agent_semantic_ui_registry: MingaEditor.Agent.SemanticUI.Registry

  @doc "Creates extension registry state for one editor instance."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      events_registry: Keyword.get(opts, :events_registry, Minga.EventBus),
      sidebar_registry: Keyword.get(opts, :sidebar_registry, MingaEditor.Extension.Sidebar),
      agent_semantic_ui_registry:
        Keyword.get(opts, :agent_semantic_ui_registry, MingaEditor.Agent.SemanticUI.Registry)
    }
  end

  @doc "Installs the event registry selected for this editor."
  @spec install_events_registry(t(), Minga.Events.registry()) :: t()
  def install_events_registry(%__MODULE__{} = surfaces, registry),
    do: %{surfaces | events_registry: registry}

  @doc "Installs the semantic agent UI registry selected for this editor."
  @spec install_agent_semantic_ui_registry(
          t(),
          MingaEditor.Agent.SemanticUI.Registry.table()
        ) :: t()
  def install_agent_semantic_ui_registry(%__MODULE__{} = surfaces, table) when is_atom(table),
    do: %{surfaces | agent_semantic_ui_registry: table}
end
