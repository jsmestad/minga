defmodule MingaEditor.UI.Picker.RemoteServerSource do
  @moduledoc "Picker source for choosing where to start a new agent session."

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Distribution.ConnectionManager
  alias MingaEditor.Commands.Agent
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Start agent session"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_ctx) do
    local = %Item{id: :local, label: "Local", description: "Start on this machine"}

    remote =
      ConnectionManager.connected_nodes()
      |> Enum.filter(fn {_name, _node, status} -> status == :connected end)
      |> Enum.map(fn {name, node, _status} ->
        %Item{id: {:remote, name}, label: name, description: Atom.to_string(node)}
      end)

    [local | remote]
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: :local}, state), do: Agent.new_agent_session(state)

  def on_select(%Item{id: {:remote, server_name}}, state) do
    AgentSession.start_remote_session(state, server_name)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state
end
