defmodule MingaEditor.LspActions.ReferencesTest do
  @moduledoc "Structured find-references response feedback tests."

  use ExUnit.Case, async: true

  alias MingaEditor.LspActions
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.UI.Picker.LocationSource

  test "error, nil, and empty responses finish the same correlated operation" do
    cases = [
      {{:error, "timeout"}, :error, "References request failed"},
      {{:error, :timeout}, :timeout, "References request timed out"},
      {{:ok, nil}, :success, "No references found"},
      {{:ok, []}, :success, "No references found"}
    ]

    for {response, status, message} <- cases do
      {state, operation} = start_operation()
      state = LspActions.handle_references_response(state, response, operation.id)
      selected = OperationFeedback.selected(state.feedback.operation_feedback)

      assert selected.id == operation.id
      assert selected.status == status
      assert selected.message == message
      assert state.shell_runtime.state.notice.message == nil
    end
  end

  test "a result list opens the picker and finishes successfully" do
    path =
      Path.join(System.tmp_dir!(), "references-feedback-#{System.unique_integer([:positive])}.ex")

    File.write!(path, "first\nsecond\n")
    on_exit(fn -> File.rm(path) end)
    {state, operation} = start_operation(Path.dirname(path))

    locations = [location(path, 0), location(path, 1)]
    state = LspActions.handle_references_response(state, {:ok, locations}, operation.id)

    assert OperationFeedback.selected(state.feedback.operation_feedback).status == :success

    assert OperationFeedback.selected(state.feedback.operation_feedback).message ==
             "Found 2 references"

    assert state.shell_runtime.state.notice.message == nil

    assert {:picker, %{picker_ui: %{source: LocationSource, picker: picker}}} =
             state.shell_runtime.state.modal

    assert Enum.map(picker.items, & &1.id) == [{path, 0, 0}, {path, 1, 0}]

    assert Enum.map(picker.items, & &1.label) == [
             "#{Path.basename(path)}:1:1",
             "#{Path.basename(path)}:2:1"
           ]
  end

  test "a response for a replaced identity cannot mutate feedback or perform picker effects" do
    {state, old} = start_operation()

    {current_feedback, current} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :lsp_references,
        "lsp:references:file.ex",
        "Finding current references",
        cancelable?: false
      )

    state = %{
      state
      | feedback: Feedback.accept_operation_feedback(state.feedback, current_feedback)
    }

    path =
      Path.join(System.tmp_dir!(), "stale-references-#{System.unique_integer([:positive])}.ex")

    File.write!(path, "first\nsecond\n")
    on_exit(fn -> File.rm(path) end)

    result =
      LspActions.handle_references_response(
        state,
        {:ok, [location(path, 0), location(path, 1)]},
        old.id
      )

    assert result == state
    assert OperationFeedback.selected(result.feedback.operation_feedback).id == current.id
    assert OperationFeedback.selected(result.feedback.operation_feedback).status == :pending
  end

  @spec location(String.t(), non_neg_integer()) :: map()
  defp location(path, line) do
    %{
      "uri" => "file://#{path}",
      "range" => %{
        "start" => %{"line" => line, "character" => 0},
        "end" => %{"line" => line, "character" => 1}
      }
    }
  end

  @spec start_operation(String.t() | nil) ::
          {EditorState.t(), MingaEditor.State.Operation.t()}
  defp start_operation(project_root \\ nil) do
    workspace = %SessionState{}
    workspace = with_project_root(workspace, project_root)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: workspace
    }

    {operation_feedback, operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        :lsp_references,
        "lsp:references:file.ex",
        "Finding references...",
        cancelable?: false
      )

    {%{state | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)},
     operation}
  end

  @spec with_project_root(SessionState.t(), String.t() | nil) :: SessionState.t()
  defp with_project_root(workspace, nil), do: workspace

  defp with_project_root(workspace, root) do
    file_tree = FileTreeState.set_project_root(%FileTreeState{}, root)
    SessionState.set_file_tree(workspace, file_tree)
  end
end
