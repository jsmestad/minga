defmodule MingaEditor.Commands.EditingAutopairConfigTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Language.Highlight.Span
  alias MingaEditor
  alias MingaEditor.Commands.Editing
  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Highlight

  setup do
    %{options_server: start_supervised!({Options, name: nil})}
  end

  defp command_state(buffer, highlight) do
    %MingaEditor.State{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      parser: %MingaEditor.State.Parser{
        highlighting: Highlighting.set_highlights(%Highlighting{}, %{buffer => highlight})
      },
      workspace: %MingaEditor.Session.State{
        buffers: %MingaEditor.State.Buffers{active: buffer, list: [buffer]},
        editing: MingaEditor.VimState.new()
      }
    }
  end

  test "global autopair_block config disables block insertion without touching the buffer option",
       %{options_server: options_server} do
    assert {:ok, false} = Options.set(options_server, :autopair_block, false)

    {:ok, buffer} =
      BufferProcess.start_link(
        content: "def run do",
        filetype: :elixir,
        options_server: options_server
      )

    BufferProcess.move_to(buffer, {0, byte_size("def run do")})

    Editing.execute(command_state(buffer, Highlight.new()), :insert_newline)

    assert BufferProcess.get_option(buffer, :autopair_block) == false
    assert BufferProcess.content(buffer) == "def run do\n"
  end

  test "per-filetype autopair_block config disables block insertion without touching the buffer option",
       %{options_server: options_server} do
    assert {:ok, true} = Options.set(options_server, :autopair_block, true)

    assert {:ok, false} =
             Options.set_for_filetype(options_server, :elixir, :autopair_block, false)

    {:ok, buffer} =
      BufferProcess.start_link(
        content: "def run do",
        filetype: :elixir,
        options_server: options_server
      )

    BufferProcess.move_to(buffer, {0, byte_size("def run do")})

    Editing.execute(command_state(buffer, Highlight.new()), :insert_newline)

    assert BufferProcess.get_option(buffer, :autopair_block) == false
    assert BufferProcess.content(buffer) == "def run do\n"
  end

  test "inside a multibyte document comment, a closer skips and an opener inserts once", %{
    options_server: options_server
  } do
    assert {:ok, true} = Options.set(options_server, :autopair, true)
    content = "é\n# )"

    buffer =
      start_supervised!(
        {BufferProcess, content: content, filetype: :elixir, options_server: options_server}
      )

    highlight =
      Highlight.new()
      |> Highlight.put_names(["comment"])
      |> Highlight.put_spans(1, [Span.new(byte_size("é\n"), byte_size(content), 0)])

    state = command_state(buffer, highlight)
    BufferProcess.move_to(buffer, {1, 2})
    Editing.execute(state, {:insert_char, ")"})
    assert BufferProcess.content(buffer) == content
    assert BufferProcess.cursor(buffer) == {1, 3}

    BufferProcess.move_to(buffer, {1, 0})
    Editing.execute(state, {:insert_char, "("})
    assert BufferProcess.content(buffer) == "é\n(# )"
    assert BufferProcess.cursor(buffer) == {1, 1}
  end

  test "Enter before whitespace checks the opener byte, not the cursor byte", %{
    options_server: options_server
  } do
    assert {:ok, true} = Options.set(options_server, :autopair_block, true)

    buffer =
      start_supervised!(
        {BufferProcess, content: "# do ", filetype: :elixir, options_server: options_server}
      )

    highlight =
      Highlight.new()
      |> Highlight.put_names(["comment"])
      |> Highlight.put_spans(1, [Span.new(0, byte_size("# do"), 0)])

    BufferProcess.move_to(buffer, {0, 4})
    Editing.execute(command_state(buffer, highlight), :insert_newline)
    assert BufferProcess.content(buffer) == "# do\n "
    assert BufferProcess.cursor(buffer) == {1, 0}
  end
end
