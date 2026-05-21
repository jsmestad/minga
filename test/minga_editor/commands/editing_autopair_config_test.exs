defmodule MingaEditor.Commands.EditingAutopairConfigTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor
  alias MingaEditor.Commands.Editing
  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Highlight

  setup do
    %{options_server: start_supervised!({Options, name: nil})}
  end

  defp command_state(buffer, highlight) do
    %MingaEditor.State{
      port_manager: nil,
      workspace: %MingaEditor.Session.State{
        viewport: %MingaEditor.Viewport{top: 0, left: 0, rows: 10, cols: 40},
        buffers: %MingaEditor.State.Buffers{active: buffer, list: [buffer]},
        editing: MingaEditor.VimState.new(),
        highlight: %Highlighting{highlights: %{buffer => highlight}}
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
end
