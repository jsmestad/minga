defmodule MingaEditor.Commands.EditingLineTargetsTest do
  use ExUnit.Case, async: true

  import MingaEditor.CommandStateHelpers

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Language.Highlight.InjectionRange
  alias MingaEditor.Commands.Editing
  alias MingaEditor.State.Parser, as: ParserState
  alias MingaEditor.UI.Highlight

  test "counted indentation stops at EOF and keeps the cursor on the same text" do
    buffer = start_buffer("first\nsecond\nthird")
    BufferProcess.set_option(buffer, :tab_width, 2)
    BufferProcess.set_option(buffer, :indent_with, :spaces)
    BufferProcess.move_to(buffer, {1, 3})
    state = command_state(buffer)

    assert Editing.execute(state, {:indent_lines, 9}) == state
    assert BufferProcess.content(buffer) == "first\n  second\n  third"
    assert BufferProcess.cursor(buffer) == {1, 5}
  end

  test "a backward motion dedents both endpoints and adjusts the cursor" do
    buffer = start_buffer("\tfirst\n\tsecond\n\tthird")
    BufferProcess.move_to(buffer, {1, 4})
    state = command_state(buffer)

    assert Editing.execute(state, {:dedent_motion, :document_start}) == state
    assert BufferProcess.content(buffer) == "first\nsecond\n\tthird"
    assert BufferProcess.cursor(buffer) == {1, 3}
  end

  test "a characterwise selection comments whole lines using the first line's injected prefix" do
    buffer = start_buffer("outside\n  alpha\n  beta\nuntouched", filetype: :elixir)
    BufferProcess.move_to(buffer, {2, 4})
    state = buffer |> command_state() |> with_visual_selection({1, 5}, :char)

    injection =
      InjectionRange.new(
        BufferProcess.byte_offset_for_line(buffer, 1),
        BufferProcess.byte_offset_for_line(buffer, 2),
        "javascript"
      )

    state = %{
      state
      | parser: ParserState.accept_injection_ranges(state.parser, %{buffer => [injection]})
    }

    assert Editing.execute(state, :comment_visual_selection) == state
    assert BufferProcess.content(buffer) == "outside\n  // alpha\n  // beta\nuntouched"
  end

  test "a missing motion target keeps parser preparation but does not edit or move the cursor" do
    buffer = start_buffer("  word\n  tail", filetype: :text)
    BufferProcess.move_to(buffer, {0, 2})
    state = command_state(buffer)
    state = %{state | parser: ParserState.new(__MODULE__)}

    for command <- [:indent_motion, :dedent_motion, :reindent_motion, :comment_motion] do
      result = Editing.execute(state, {command, :match_bracket})

      assert %{^buffer => %Highlight{}} = result.parser.highlighting.highlights
      assert BufferProcess.content(buffer) == "  word\n  tail"
      assert BufferProcess.cursor(buffer) == {0, 2}
    end
  end

  test "reindenting a word edits its line and moves the cursor to the first nonblank" do
    buffer = start_buffer("  parent\nchild\nleaf", filetype: :text)
    BufferProcess.move_to(buffer, {1, 3})
    state = command_state(buffer)
    state = %{state | parser: ParserState.new(__MODULE__)}

    assert Editing.execute(state, {:reindent_text_object, :inner, :word}) == state
    assert BufferProcess.content(buffer) == "  parent\n  child\nleaf"
    assert BufferProcess.cursor(buffer) == {1, 2}
  end
end
