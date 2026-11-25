defmodule MingaEditor.Commands.SearchCommandTest do
  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers, only: [command_state: 2, start_buffer: 1]

  alias Minga.Buffer
  alias Minga.Mode.SearchState
  alias MingaEditor.Commands.Search
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  test "a failed backward search records the request without moving the cursor" do
    buffer = start_buffer("empty")
    assert :ok = Buffer.move_to(buffer, {0, 1})
    search = %SearchState{input: "missing", direction: :backward, original_cursor: {0, 1}}
    state = command_state(buffer, mode: :search, mode_state: search)

    state = Search.execute(state, :confirm_search)
    assert NoticeWorkflow.message(state) == "No matches for “missing” in this buffer"

    assert [%{id: "search_project", key: "SPC s p", label: "search the project"}] =
             state.shell_runtime.state.notice.actions

    assert Buffer.cursor(buffer) == {0, 1}

    assert :ok = Buffer.replace_content(buffer, "missing middle missing")
    assert :ok = Buffer.move_to(buffer, {0, 8})
    Search.execute(state, :search_next)
    assert Buffer.cursor(buffer) == {0, 0}
  end

  test "substitution records its pattern without changing the repeat direction" do
    buffer = start_buffer("foo foo mid foo")
    search = %SearchState{input: "mid", direction: :backward}
    state = command_state(buffer, mode: :search, mode_state: search)

    state = Search.execute(state, :confirm_search)
    state = Search.execute_substitute(state, buffer, "foo", "bar", false)
    assert Buffer.content(buffer) == "bar foo mid foo"

    assert :ok = Buffer.move_to(buffer, {0, 8})
    Search.execute(state, :search_next)
    assert Buffer.cursor(buffer) == {0, 4}
  end

  test "a buffer search that found nothing hands its query to the next project search, once" do
    buffer = start_buffer("empty")
    search = %SearchState{input: "missing", direction: :forward}

    state =
      command_state(buffer, mode: :search, mode_state: search) |> Search.execute(:confirm_search)

    {:ok, %{execute: execute}} = Minga.Command.lookup(:search_project)
    prompted = execute.(state)
    assert %Minga.Mode.SearchPromptState{input: "missing"} = prompted.workspace.editing.mode_state

    again = execute.(prompted)
    assert %Minga.Mode.SearchPromptState{input: ""} = again.workspace.editing.mode_state
  end

  test "while typing, the prompt says when the query matches nothing in this buffer" do
    buffer = start_buffer("alpha beta")

    for {input, no_match?} <- [{"beta", false}, {"gamma", true}] do
      search = %SearchState{input: input, direction: :forward}

      state =
        command_state(buffer, mode: :search, mode_state: search)
        |> Search.execute(:incremental_search)

      assert state.workspace.editing.mode_state.no_match? == no_match?
      context = MingaEditor.MinibufferData.from_state(state).context
      assert context == "no matches in this buffer" == no_match?
    end
  end

  test "emptying the query clears the no-match note" do
    buffer = start_buffer("alpha beta")
    search = %SearchState{input: "gamma", direction: :forward}

    state =
      command_state(buffer, mode: :search, mode_state: search)
      |> Search.execute(:incremental_search)

    assert state.workspace.editing.mode_state.no_match?

    emptied =
      MingaEditor.Editing.update_mode_state(state, &%{&1 | input: ""})
      |> Search.execute(:incremental_search)

    refute emptied.workspace.editing.mode_state.no_match?
  end

  test "an offer that has gone stale leaves a later project search empty" do
    search =
      MingaEditor.State.Search.offer_project_query(%MingaEditor.State.Search{}, "missing", 0)

    assert {"missing", _taken} = MingaEditor.State.Search.take_project_offer(search, 9_000)
    assert {nil, cleared} = MingaEditor.State.Search.take_project_offer(search, 60_000)
    assert {nil, _} = MingaEditor.State.Search.take_project_offer(cleared, 0)
  end
end
