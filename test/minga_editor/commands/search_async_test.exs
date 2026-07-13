defmodule MingaEditor.Commands.SearchAsyncTest do
  @moduledoc """
  Verifies project search confirmation hands off to the async picker path
  instead of running the `rg`/`grep` scan synchronously on the editor input
  path (ticket #2376, AC1/AC6).
  """

  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Mode.SearchPromptState
  alias MingaEditor.Commands.Search
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.ModalOverlay

  defp with_search_prompt(state, input) do
    EditorState.transition_mode(state, :search_prompt, %SearchPromptState{input: input})
  end

  describe ":confirm_project_search" do
    test "opens the picker immediately in a loading state without blocking on the scan" do
      state =
        base_state(content: "scratch")
        |> with_search_prompt("some-query-that-need-not-match-anything")

      # The command must return promptly. If it blocked on a real subprocess scan,
      # it could not return a :loading picker synchronously — the picker would
      # already hold results (or the call would hang on a large repo).
      new_state = Search.execute(state, :confirm_project_search)

      assert ModalOverlay.match(EditorState.modal(new_state), :picker)
      {:picker, %{picker_ui: picker_ui}} = EditorState.modal(new_state)
      assert picker_ui.load_status == :loading
      assert picker_ui.source == MingaEditor.UI.Picker.ProjectSearchSource

      # A fresh fetch revision was minted: this is the latest-wins guard token,
      # carried on the deferred fetch and checked when results land.
      assert is_reference(picker_ui.fetch_revision)
    end

    test "stashes the query for the off-path source to read" do
      state =
        base_state(content: "scratch")
        |> with_search_prompt("widget")

      new_state = Search.execute(state, :confirm_project_search)
      assert new_state.workspace.search.project_query == "widget"
    end

    test "defers the actual fetch via a self-sent message rather than running it inline" do
      state =
        base_state(content: "scratch")
        |> with_search_prompt("widget")

      _new_state = Search.execute(state, :confirm_project_search)

      # PickerUI.open/3 for an async source enqueues the fetch to the editor's own
      # mailbox (self() here is the test process), keeping the scan off the
      # synchronous command path. Assert the deferred fetch was scheduled.
      assert_received {:picker_fetch_candidates, MingaEditor.UI.Picker.ProjectSearchSource,
                       revision, _ctx}

      assert is_reference(revision)
    end

    test "empty query reports a status instead of opening the picker" do
      state =
        base_state(content: "scratch")
        |> with_search_prompt("")

      new_state = Search.execute(state, :confirm_project_search)
      refute ModalOverlay.match(EditorState.modal(new_state), :picker)
    end
  end
end
