defmodule MingaEditor.Commands.EditTimeline do
  @moduledoc """
  Commands for navigating agent edit history.

  `]e` jumps to the next edit point, `[e` to the previous.
  When scrubbing, the timeline viewing index tracks the position.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias Minga.Buffer

  @command_specs [
    {:timeline_next_edit, "Next agent edit", true},
    {:timeline_prev_edit, "Previous agent edit", true},
    {:timeline_toggle, "Toggle edit timeline visibility", false},
    {:timeline_go_live, "Return to current file state", true}
  ]

  @spec execute(EditorState.t(), atom()) :: EditorState.t()
  def execute(%{workspace: %{buffers: %{active: nil}}} = state, _cmd), do: state

  def execute(state, :timeline_next_edit) do
    with_timeline(state, fn path, timeline ->
      case EditTimeline.navigate_next(timeline, path) do
        {timeline, :moved} ->
          idx = EditTimeline.viewing_index(timeline, path)
          count = EditTimeline.entry_count(timeline, path)
          state = set_timeline(state, timeline)
          EditorState.set_status(state, "Edit #{idx + 1}/#{count}")

        {_timeline, :at_end} ->
          state = set_timeline(state, EditTimeline.go_live(timeline, path))
          EditorState.set_status(state, "Live (current state)")

        {_timeline, :no_entries} ->
          EditorState.set_status(state, "No agent edits for this file")
      end
    end)
  end

  def execute(state, :timeline_prev_edit) do
    with_timeline(state, fn path, timeline ->
      case EditTimeline.navigate_prev(timeline, path) do
        {timeline, :moved} ->
          idx = EditTimeline.viewing_index(timeline, path)
          count = EditTimeline.entry_count(timeline, path)
          state = set_timeline(state, timeline)
          EditorState.set_status(state, "Edit #{idx + 1}/#{count}")

        {_timeline, :at_baseline} ->
          EditorState.set_status(state, "At baseline (before agent)")

        {_timeline, :no_entries} ->
          EditorState.set_status(state, "No agent edits for this file")
      end
    end)
  end

  def execute(state, :timeline_go_live) do
    with_timeline(state, fn path, timeline ->
      state = set_timeline(state, EditTimeline.go_live(timeline, path))
      EditorState.set_status(state, "Live (current state)")
    end)
  end

  def execute(state, :timeline_toggle) do
    EditorState.set_status(state, "Edit timeline toggled")
  end

  @spec navigate_to_index(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def navigate_to_index(state, index) do
    with_timeline(state, fn path, timeline ->
      count = EditTimeline.entry_count(timeline, path)

      if index < count do
        timeline = EditTimeline.set_viewing(timeline, path, index)
        state = set_timeline(state, timeline)
        EditorState.set_status(state, "Edit #{index + 1}/#{count}")
      else
        state
      end
    end)
  end

  defp with_timeline(state, fun) do
    buf = state.workspace.buffers.active

    case Buffer.file_path(buf) do
      nil ->
        EditorState.set_status(state, "No file path")

      path ->
        timeline = AgentAccess.view(state).edit_timeline
        fun.(path, timeline)
    end
  end

  defp set_timeline(state, timeline) do
    AgentAccess.update_view(state, fn view ->
      %{view | edit_timeline: timeline}
    end)
  end

  commands(@command_specs)
end
