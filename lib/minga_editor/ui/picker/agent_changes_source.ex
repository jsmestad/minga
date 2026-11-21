defmodule MingaEditor.UI.Picker.AgentChangesSource do
  @moduledoc "Browses all attributed files in the current Agent conversation."
  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.Tools.OutputLimit
  alias MingaEditor.Agent.ConnectionAction
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Commands.EditTimeline, as: TimelineCommands
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.{Context, Item}

  @doc "Opens a searchable list bound to the displayed conversation and Changes generation."
  @spec open(EditorState.t()) :: EditorState.t()
  def open(state) do
    timeline = state.workspace.agent_ui.view.edit_timeline

    with {:ok, workspace, %{target: target}} <- ConnectionAction.origin(state),
         [_ | _] = files <- EditTimeline.file_summaries(timeline) do
      PickerUI.open(state, __MODULE__, %{
        files: files,
        origin: {workspace, target, timeline.generation}
      })
    else
      [] ->
        NoticeWorkflow.publish(state, "No attributed file changes in this conversation.")

      {:error, _reason} ->
        NoticeWorkflow.publish(state, "Open an Agent session to browse its changes.")
    end
  end

  @impl true
  @spec title() :: String.t()
  def title, do: "Agent changed files"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{picker_ui: %{context: %{files: files, origin: origin}}}) do
    Enum.map(files, fn %{path: path, entry_count: count} ->
      %Item{
        id: path,
        label: path_label(path),
        search_text: path,
        description: "Edits: #{count}",
        meta: %{origin: origin}
      }
    end)
  end

  @spec path_label(String.t()) :: String.t()
  defp path_label(path) when byte_size(path) <= 180, do: path

  defp path_label(path) do
    # A 100-row offer must fit a 16-bit section even at two highlight bytes per label byte.
    parent = OutputLimit.truncate_utf8(Path.dirname(path), 74, "…")
    name = OutputLimit.truncate_utf8(Path.basename(path), 92, "…")
    suffix = :crypto.hash(:sha256, path) |> binary_part(0, 4) |> Base.encode16(case: :lower)
    "#{parent}/#{name} [#{suffix}]"
  end

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(%Item{id: path, meta: %{origin: {workspace, target, generation}}}, state)
      when is_binary(path) do
    timeline = state.workspace.agent_ui.view.edit_timeline

    with {:ok, ^workspace, %{target: ^target}} <- ConnectionAction.origin(state),
         ^generation <- timeline.generation,
         :ok <- current_file(timeline, path) do
      TimelineCommands.review_file(state, path)
    else
      _stale ->
        NoticeWorkflow.publish(
          state,
          "The Changes list changed. Open it again to review this file."
        )
    end
  end

  @spec current_file(EditTimeline.t(), String.t()) :: :ok | :stale
  defp current_file(timeline, path) do
    if EditTimeline.changed_file?(timeline, path), do: :ok, else: :stale
  end
end
