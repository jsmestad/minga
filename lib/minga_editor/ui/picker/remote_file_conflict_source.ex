defmodule MingaEditor.UI.Picker.RemoteFileConflictSource do
  @moduledoc "Picker source for resolving dirty remote file conflicts."

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @type action :: :reload | :keep | :show_diff

  @impl true
  @spec title() :: String.t()
  def title, do: "Remote file changed"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{picker_ui: %{context: %{buffer: buffer, path: path, content: content}}})
      when is_pid(buffer) and is_binary(path) and is_binary(content) do
    [
      item(
        :reload,
        buffer,
        path,
        content,
        "Reload, discard my changes",
        "Replace the buffer with the agent's version"
      ),
      item(
        :keep,
        buffer,
        path,
        content,
        "Keep editing",
        "Keep local edits; save will check for conflicts"
      ),
      item(
        :show_diff,
        buffer,
        path,
        content,
        "Show diff",
        "Review the agent change in the file viewer"
      )
    ]
  end

  def candidates(_ctx), do: []

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(%Item{id: {:remote_conflict, :reload, buffer, path, content}}, state) do
    Buffer.accept_saved_content(buffer, content)

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Reloaded #{Path.basename(path)} from remote"
    )
  catch
    :exit, reason ->
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        state,
        "Remote reload failed: #{inspect(reason)}"
      )
  end

  def on_select(%Item{id: {:remote_conflict, :keep, _buffer, path, _content}}, state) do
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "Keeping local edits for #{Path.basename(path)}; save will check for conflicts"
    )
  end

  def on_select(%Item{id: {:remote_conflict, :show_diff, buffer, path, content}}, state) do
    case DiffReview.new(path, Buffer.content(buffer), content) do
      %DiffReview{} = review ->
        show_diff(state, path, review)

      nil ->
        MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
          state,
          "No remote changes to show for #{Path.basename(path)}"
        )
    end
  catch
    :exit, reason ->
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        state,
        "Remote diff failed: #{inspect(reason)}"
      )
  end

  @impl true
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: state

  @spec show_diff(EditorState.t(), String.t(), DiffReview.t()) :: EditorState.t()
  defp show_diff(state, path, review) do
    state
    |> then(fn state ->
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
        state,
        (&set_diff_preview(&1, review)).(state.workspace.agent_ui)
      )
    end)
    |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      "Showing diff for #{Path.basename(path)}"
    )
  end

  @spec set_diff_preview(UIState.t(), DiffReview.t()) :: UIState.t()
  defp set_diff_preview(ui, review) do
    ui
    |> UIState.replace_preview(Preview.set_diff(Preview.new(), review))
    |> UIState.set_focus(:file_viewer)
  end

  @spec item(action(), pid(), String.t(), String.t(), String.t(), String.t()) :: Item.t()
  defp item(action, buffer, path, content, label, description) do
    %Item{
      id: {:remote_conflict, action, buffer, path, content},
      label: label,
      description: description
    }
  end
end
