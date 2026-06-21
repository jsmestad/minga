defmodule MingaKnowledgeGraph.Commands do
  @moduledoc """
  Command implementations for the knowledge graph extension.

  Each command reads the active file from editor state and delegates to the
  Tracker, which owns the graph and the briefing lifecycle.
  """

  alias MingaEditor.Extension.EditorAPI
  alias MingaKnowledgeGraph.Tracker

  @spec briefing(EditorAPI.state()) :: EditorAPI.state()
  def briefing(state) do
    case EditorAPI.active_path(state) do
      nil ->
        EditorAPI.set_status(state, "Knowledge: no current file to brief")

      path ->
        Tracker.request_briefing(path)
        EditorAPI.set_status(state, "Generating briefing for #{Path.basename(path)}…")
    end
  end

  @spec familiarity(EditorAPI.state()) :: EditorAPI.state()
  def familiarity(state) do
    case EditorAPI.active_path(state) do
      nil -> EditorAPI.set_status(state, "Knowledge: no current file")
      path -> EditorAPI.set_status(state, Tracker.familiarity(path))
    end
  end

  @spec refresh_heat(EditorAPI.state()) :: EditorAPI.state()
  def refresh_heat(state) do
    Tracker.refresh_heat()
    EditorAPI.set_status(state, "Knowledge: heat map refreshed")
  end
end
