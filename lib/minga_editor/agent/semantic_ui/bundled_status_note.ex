defmodule MingaEditor.Agent.SemanticUI.BundledStatusNote do
  @moduledoc """
  Static bundled semantic UI declaration for the agent status transcript note.
  """

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
end
