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
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess

  @command_specs [
    {:timeline_next_edit, "Next agent edit", true},
    {:timeline_prev_edit, "Previous agent edit", true},
    {:timeline_next_file, "Next agent-changed file", false},
    {:timeline_prev_file, "Previous agent-changed file", false},
    {:timeline_toggle, "Toggle edit timeline visibility", false},
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

  def execute(state, :timeline_next_file), do: navigate_file(state, 1)
  def execute(state, :timeline_prev_file), do: navigate_file(state, -1)

  def execute(state, :timeline_toggle) do
    NoticeWorkflow.publish(state, "Edit timeline toggled")
  end

  @spec navigate_to_index(EditorState.t(), non_neg_integer()) :: EditorState.t()
  def navigate_to_index(state, index) do
    with_timeline(state, fn path, timeline ->
      count = EditTimeline.entry_count(timeline, path)

      if index < count do
        timeline = EditTimeline.set_viewing(timeline, path, index)
        state = set_timeline(state, timeline)
        NoticeWorkflow.publish(state, "Edit #{index + 1}/#{count}")
      else
        state
      end
    end)
  end

  defp with_timeline(state, fun) do
    buf = state.workspace.buffers.active

    case Buffer.file_path(buf) do
      nil ->
        NoticeWorkflow.publish(state, "No file path")

      path ->
        timeline = AgentAccess.view(state).edit_timeline
        fun.(path, timeline)
    end
  end

  @spec navigate_file(EditorState.t(), 1 | -1) :: EditorState.t()
  defp navigate_file(state, direction) do
    timeline = AgentAccess.view(state).edit_timeline
    paths = timeline |> EditTimeline.file_summaries() |> Enum.map(& &1.path)

    case paths do
      [] ->
        NoticeWorkflow.publish(state, "No agent-changed files")

      _ ->
        current_path = active_path(state)
        target_path = next_path(paths, current_path, direction)

        case BufferRegistry.open_file_by_path_result(state, target_path) do
          {:ok, new_state} ->
            NoticeWorkflow.publish(
              new_state,
              "Agent change file: #{target_path}"
            )

          {:error, reason} ->
            NoticeWorkflow.publish(
              state,
              "Could not open agent change file #{target_path}: #{inspect(reason)}"
            )
        end
    end
  end

  @spec active_path(EditorState.t()) :: String.t() | nil
  defp active_path(%{workspace: %{buffers: %{active: buf}}}) when is_pid(buf) do
    Buffer.file_path(buf)
  catch
    :exit, _ -> nil
  end

  defp active_path(_state), do: nil

  @spec next_path([String.t()], String.t() | nil, 1 | -1) :: String.t()
  defp next_path(paths, nil, 1), do: hd(paths)
  defp next_path(paths, nil, -1), do: Enum.at(paths, -1)

  defp next_path(paths, current_path, direction) do
    count = length(paths)

    case Enum.find_index(paths, &(&1 == current_path)) do
      nil -> next_path(paths, nil, direction)
      index -> Enum.at(paths, rem(index + direction + count, count))
    end
  end

  defp set_timeline(state, timeline) do
    AgentAccess.update_agent_ui(state, fn ui ->
      UIState.update_edit_timeline(ui, fn _ -> timeline end)
    end)
  end

  commands(@command_specs)
end
