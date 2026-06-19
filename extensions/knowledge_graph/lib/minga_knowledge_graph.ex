defmodule MingaKnowledgeGraph do
  @moduledoc """
  Personal knowledge graph extension for Minga.

  Watches which files you open and edit and builds a familiarity map that
  persists across sessions. The file tree tints by familiarity (warm =
  well-known, cool = unfamiliar), and opening an unfamiliar file pops a
  short, personalized briefing on what that file does.

  Keybindings (under a dedicated `SPC k` "knowledge" leader):

    * `SPC k b` — briefing for the current file
    * `SPC k k` — familiarity for the current file
    * `SPC k r` — refresh the heat map

  Also available as `M-x knowledge-briefing` / `M-x knowledge-map`.
  """

  use Minga.Extension.Editor

  command(:knowledge_briefing, "Show a briefing for the current file",
    execute: {MingaKnowledgeGraph.Commands, :briefing}
  )

  command(:knowledge_map, "Show familiarity for the current file",
    execute: {MingaKnowledgeGraph.Commands, :familiarity}
  )

  command(:knowledge_heat_refresh, "Refresh the familiarity heat map",
    execute: {MingaKnowledgeGraph.Commands, :refresh_heat}
  )

  keybind(:normal, "SPC k b", :knowledge_briefing, "Briefing for current file")
  keybind(:normal, "SPC k k", :knowledge_map, "Familiarity for current file")
  keybind(:normal, "SPC k r", :knowledge_heat_refresh, "Refresh knowledge heat map")

  @impl true
  def name, do: :minga_knowledge_graph

  @impl true
  def description, do: "Tracks what you know and briefs you on what you don't"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def child_spec(_config) do
    %{
      id: MingaKnowledgeGraph.Tracker,
      start: {MingaKnowledgeGraph.Tracker, :start_link, [[]]},
      restart: :permanent,
      type: :worker
    }
  end
end
