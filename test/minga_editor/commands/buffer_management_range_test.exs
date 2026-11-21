defmodule MingaEditor.Commands.BufferManagementRangeTest do
  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers, only: [command_state: 1, start_buffer: 1]

  alias Minga.Buffer
  alias Minga.Command.Parser
  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  test "sort changes only the selected lines and keeps the final newline" do
    buffer = start_buffer("z head\npear\napple\nlime\na foot\n")

    state = execute_ex(buffer, "2,4sort")

    assert Buffer.content(buffer) == "z head\napple\nlime\npear\na foot\n"
    assert NoticeWorkflow.message(state) == "Sorted lines 2-4"
  end

  test "sort nru reverses numeric ties before removing identical lines" do
    content = "head\n 2 first\n2 second\n2 third\n 2 first\n10 high\nplain\n-3 low\nfoot\n"
    buffer = start_buffer(content)

    execute_ex(buffer, "2,8sort nru")

    expected = "head\n10 high\n 2 first\n2 third\n2 second\nplain\n-3 low\nfoot\n"
    assert Buffer.content(buffer) == expected
  end

  test "global applies a nested command only to lines matching the regex" do
    buffer = start_buffer("hit 1\nhit 3\nbefore hit 2\nhit 2")

    execute_ex(buffer, "g/^hit [12]$/.normal rX")

    assert Buffer.content(buffer) == "Xit 1\nhit 3\nbefore hit 2\nXit 2"
  end

  test "global treats an invalid regex as a literal substring" do
    buffer = start_buffer("a[b\nabc\n[d\n")

    execute_ex(buffer, "g/[/.normal rX")

    assert Buffer.content(buffer) == "X[b\nabc\nXd\n"
  end

  test "global reports a miss without moving the cursor or running the nested command" do
    content = "no match\nmatch no\n"
    buffer = start_buffer(content)
    Buffer.move_to(buffer, {1, 2})

    state = execute_ex(buffer, "g/^match$/.normal dd")

    assert Buffer.content(buffer) == content
    assert Buffer.cursor(buffer) == {1, 2}
    assert NoticeWorkflow.message(state) == "Pattern not found: ^match$"
  end

  test "global visits original matching indexes in order even when nested edits shift lines" do
    buffer = start_buffer("head\nhit one\nfirst neighbor\nhit two\nsecond neighbor\nfoot")

    execute_ex(buffer, "g/^hit/.normal dd")

    assert Buffer.content(buffer) == "head\nfirst neighbor\nhit two\nfoot"
  end

  test "normal runs a key sequence on the selected lines and carries mode state between them" do
    buffer = start_buffer("head\nalpha\nbeta\nfoot\n")

    # The first x deletes; the second x is the replacement requested by the first r.
    state = execute_ex(buffer, "2,3normal xr")

    assert Buffer.content(buffer) == "head\nlpha\nxeta\nfoot\n"
    assert NoticeWorkflow.message(state) == "Normal executed on 2-3"
  end

  test "normal rejects an invalid range without moving the cursor or editing" do
    content = "head\nalpha\nbeta\nfoot\n"
    buffer = start_buffer(content)
    Buffer.move_to(buffer, {2, 2})

    state = execute_ex(buffer, "2,8normal rX")

    assert Buffer.content(buffer) == content
    assert Buffer.cursor(buffer) == {2, 2}
    assert NoticeWorkflow.message(state) == "Invalid range: 2,8"
  end

  defp execute_ex(buffer, input) do
    BufferManagement.execute(command_state(buffer), {:execute_ex_command, Parser.parse(input)})
  end
end
