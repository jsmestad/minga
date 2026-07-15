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
  alias MingaEditor.EffectScheduler
  alias MingaEditor.State.ModalOverlay
  alias MingaEditor.UI.Picker.FetchEffect

  defp with_search_prompt(state, input) do
    then(state, fn state ->
      %{
        state
        | workspace:
            then(state.workspace, fn workspace ->
              MingaEditor.Session.State.transition_mode(
                workspace,
                :search_prompt,
                %SearchPromptState{
                  input: input
                }
              )
            end)
      }
    end)
  end

  defp with_scheduler(state) do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())
    %{state | effect_scheduler: scheduler}
  end

  describe ":confirm_project_search" do
    test "opens the picker immediately in a loading state without blocking on the scan" do
      state =
        base_state(content: "scratch")
        |> with_scheduler()
        |> with_search_prompt("some-query-that-need-not-match-anything")

      # The command must return promptly. If it blocked on a real subprocess scan,
      # it could not return a :loading picker synchronously — the picker would
      # already hold results (or the call would hang on a large repo).
      new_state = Search.execute(state, :confirm_project_search)

      assert ModalOverlay.match(
               MingaEditor.Shell.Runtime.state(new_state.shell_runtime).modal,
               :picker
             )

      {:picker, %{picker_ui: picker_ui}} =
        MingaEditor.Shell.Runtime.state(new_state.shell_runtime).modal

      assert picker_ui.load_status == :loading
      assert picker_ui.source == MingaEditor.UI.Picker.ProjectSearchSource

      # A fresh fetch revision was minted: this is the latest-wins guard token,
      # carried on the deferred fetch and checked when results land.
      assert is_reference(picker_ui.fetch_revision)
    end

    test "stashes the query for the off-path source to read" do
      state =
        base_state(content: "scratch")
        |> with_scheduler()
        |> with_search_prompt("widget")

      new_state = Search.execute(state, :confirm_project_search)
      assert new_state.workspace.search.project_query == "widget"
    end

    test "submits a typed fetch request instead of a private Editor message" do
      state =
        base_state(content: "scratch")
        |> with_scheduler()
        |> with_search_prompt("widget")

      new_state = Search.execute(state, :confirm_project_search)

      assert EffectScheduler.active?(new_state.effect_scheduler, FetchEffect)
    end

    test "records an explicit admission failure when no scheduler is available" do
      state =
        base_state(content: "scratch")
        |> with_search_prompt("widget")

      new_state = Search.execute(state, :confirm_project_search)
      {:picker, %{picker_ui: picker}} = new_state.shell_runtime.state.modal

      assert picker.load_status ==
               {:error, "Picker fetch not scheduled: :scheduler_unavailable"}
    end

    test "empty query reports a status instead of opening the picker" do
      state =
        base_state(content: "scratch")
        |> with_search_prompt("")

      new_state = Search.execute(state, :confirm_project_search)

      refute ModalOverlay.match(
               MingaEditor.Shell.Runtime.state(new_state.shell_runtime).modal,
               :picker
             )
    end
  end
end
