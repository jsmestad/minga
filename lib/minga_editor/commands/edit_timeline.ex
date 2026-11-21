defmodule MingaEditor.Commands.EditTimeline do
  @moduledoc """
  Commands for navigating agent edit history.

  `]e` jumps to the next edit point, `[e` to the previous.
  When scrubbing, the timeline viewing index tracks the position.
  """

  use MingaEditor.Commands.Provider

  alias Minga.Buffer
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Effects.AgentReview
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.State, as: EditorState

  @command_specs [
    {:timeline_next_edit, "Next agent edit", true},
    {:timeline_prev_edit, "Previous agent edit", true},
    {:timeline_next_file, "Next agent-changed file", false},
    {:timeline_prev_file, "Previous agent-changed file", false},
    {:timeline_toggle, "Toggle edit timeline visibility", false},
    {:timeline_browse_files, "Browse Agent changed files", false},
    {:timeline_go_live, "Return to current file state", true}
  ]

  @spec execute(EditorState.t(), atom()) :: EditorState.t()
  def execute(%{workspace: %{buffers: %{active: nil}}} = state, cmd)
      when cmd in [:timeline_next_edit, :timeline_prev_edit, :timeline_go_live],
      do: state

  def execute(state, :timeline_next_edit) do
    with_timeline(state, fn path, timeline ->
      case EditTimeline.navigate_next(timeline, path) do
        {timeline, :moved} ->
          idx = EditTimeline.viewing_index(timeline, path)
          count = EditTimeline.entry_count(timeline, path)
          state = set_timeline(state, timeline)
          NoticeWorkflow.publish(state, "Edit #{idx + 1}/#{count}")

        {_timeline, :at_end} ->
          state = set_timeline(state, EditTimeline.go_live(timeline, path))
          NoticeWorkflow.publish(state, "Live (current state)")

        {_timeline, :no_entries} ->
          NoticeWorkflow.publish(
            state,
            "No agent edits for this file"
          )
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
          NoticeWorkflow.publish(state, "Edit #{idx + 1}/#{count}")

        {_timeline, :at_baseline} ->
          NoticeWorkflow.publish(
            state,
            "At baseline (before agent)"
          )

        {_timeline, :no_entries} ->
          NoticeWorkflow.publish(
            state,
            "No agent edits for this file"
          )
      end
    end)
  end

  def execute(state, :timeline_go_live) do
    with_timeline(state, fn path, timeline ->
      state = set_timeline(state, EditTimeline.go_live(timeline, path))
      NoticeWorkflow.publish(state, "Live (current state)")
    end)
  end

  def execute(state, :timeline_next_file), do: navigate_file(state, :next)
  def execute(state, :timeline_prev_file), do: navigate_file(state, :previous)

  def execute(state, :timeline_browse_files),
    do: MingaEditor.UI.Picker.AgentChangesSource.open(state)

  def execute(state, :timeline_toggle) do
    NoticeWorkflow.publish(state, "Edit timeline toggled")
  end

  @doc "Navigates to the resolved entry's file, never inferring a path from the active buffer."
  @spec navigate_to_entry(EditorState.t(), String.t(), EditTimeline.Entry.t()) :: EditorState.t()
  def navigate_to_entry(state, path, entry) do
    case BufferRegistry.open_file_by_path_result(state, path) do
      {:ok, opened} ->
        timeline = opened.workspace.agent_ui.view.edit_timeline
        count = EditTimeline.entry_count(timeline, path)
        timeline = EditTimeline.set_viewing(timeline, path, entry.index)

        opened
        |> set_timeline(timeline)
        |> NoticeWorkflow.publish("Edit #{entry.index + 1}/#{count}")

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Could not open agent change file #{path}: #{inspect(reason)}"
        )
    end
  end

  @doc "Reviews the explicitly resolved cumulative file through the generation-owned worker."
  @spec review_file(EditorState.t(), String.t()) :: EditorState.t()
  def review_file(state, path) when is_binary(path), do: AgentReview.schedule(state, path)

  defp with_timeline(state, fun) do
    buf = state.workspace.buffers.active

    case Buffer.file_path(buf) do
      nil ->
        NoticeWorkflow.publish(state, "No file path")

      path ->
        timeline = state.workspace.agent_ui.view.edit_timeline
        fun.(path, timeline)
    end
  end

  @spec navigate_file(EditorState.t(), :next | :previous) :: EditorState.t()
  defp navigate_file(state, direction) do
    view = state.workspace.agent_ui.view
    selected = Preview.selected_path(view.preview)

    case EditTimeline.adjacent_path(view.edit_timeline, selected, direction) do
      nil -> NoticeWorkflow.publish(state, "No agent-changed files")
      path -> review_file(state, path)
    end
  end

  defp set_timeline(state, timeline) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
      state,
      (fn ui ->
         UIState.replace_edit_timeline(ui, timeline)
       end).(state.workspace.agent_ui)
    )
  end

  commands(@command_specs)
end
