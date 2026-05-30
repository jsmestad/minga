defmodule MingaGhostCursors do
  @moduledoc """
  Ghost cursor extension for Minga.

  Shows translucent cursor overlays at agent edit positions. When an
  agent edits a file, a labeled ghost cursor appears at the edit
  location and updates as the agent continues editing. The cursor
  disappears when the agent session ends.

  Provides `SPC a F` to jump to the file an agent is currently editing.
  """

  use Minga.Extension.Editor

  command :ghost_cursor_follow, "Jump to the file the agent is editing",
    execute: {MingaGhostCursors.Commands, :follow}

  keybind :normal, "SPC a F", :ghost_cursor_follow, "Follow agent's file"

  @impl true
  def name, do: :minga_ghost_cursors

  @impl true
  def description, do: "Ghost cursor overlays for agent editing sessions"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def child_spec(_config) do
    %{
      id: MingaGhostCursors.Tracker,
      start: {MingaGhostCursors.Tracker, :start_link, [[]]},
      restart: :permanent,
      type: :worker
    }
  end
end
