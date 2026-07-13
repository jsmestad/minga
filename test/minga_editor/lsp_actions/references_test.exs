defmodule MingaEditor.LspActions.ReferencesTest do
  @moduledoc "Structured find-references response feedback tests."

  use ExUnit.Case, async: true

  alias MingaEditor.LspActions
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.Viewport

  test "error, nil, and empty responses finish the same correlated operation" do
    cases = [
      {{:error, "timeout"}, :error, "References request failed"},
      {{:ok, nil}, :success, "No references found"},
      {{:ok, []}, :success, "No references found"}
    ]

    for {response, status, message} <- cases do
      {state, operation} = start_operation()
      state = LspActions.handle_references_response(state, response, operation.id)
      selected = OperationFeedback.selected(state.operation_feedback)

      assert selected.id == operation.id
      assert selected.status == status
      assert selected.message == message
      assert EditorState.status_msg(state) == nil
    end
  end

  test "a result list opens the picker and finishes successfully" do
    path =
      Path.join(System.tmp_dir!(), "references-feedback-#{System.unique_integer([:positive])}.ex")

    File.write!(path, "first\nsecond\n")
    on_exit(fn -> File.rm(path) end)
    {state, operation} = start_operation()

    locations = [location(path, 0), location(path, 1)]
    state = LspActions.handle_references_response(state, {:ok, locations}, operation.id)

    assert OperationFeedback.selected(state.operation_feedback).status == :success
    assert OperationFeedback.selected(state.operation_feedback).message == "Found 2 references"
    assert EditorState.status_msg(state) == nil
  end

  test "a response for a replaced identity cannot mutate the current operation" do
    {state, old} = start_operation()

    {state, current} =
      OperationFeedback.start_in(
        state,
        :lsp_references,
        "lsp:references:file.ex",
        "Finding current references",
        cancelable?: false
      )

    state = LspActions.handle_references_response(state, {:error, "late"}, old.id)

    assert OperationFeedback.selected(state.operation_feedback).id == current.id
    assert OperationFeedback.selected(state.operation_feedback).status == :pending
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

  @spec start_operation() :: {EditorState.t(), MingaEditor.State.Operation.t()}
  defp start_operation do
    state = %EditorState{
      port_manager: nil,
      workspace: %SessionState{viewport: Viewport.new(40, 120)}
    }

    OperationFeedback.start_in(
      state,
      :lsp_references,
      "lsp:references:file.ex",
      "Finding references...",
      cancelable?: false
    )
  end
end
