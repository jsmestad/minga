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
    assert NoticeWorkflow.message(state) == "Pattern not found: missing"
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
end
