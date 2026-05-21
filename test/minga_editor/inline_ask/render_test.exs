defmodule MingaEditor.InlineAsk.RenderTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Project.FileRef
  alias MingaEditor.InlineAsk.Render
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.InlineAsk

  test "merge_decorations adds one dynamic block for the active buffer" do
    buffer_pid = self()

    ask =
      InlineAsk.new(
        buffer_pid,
        %FileRef{kind: :buffer, display_name: "scratch.ex", buffer_pid: buffer_pid},
        "scratch.ex",
        2,
        nil,
        "context"
      )

    ask = InlineAsk.append_input(ask, "why?")

    state = %{
      shell_state: %TraditionalState{inline_asks: %{buffer_pid => ask}}
    }

    decorations = Render.merge_decorations(Decorations.new(), state, buffer_pid)

    assert Decorations.has_block_decorations?(decorations)
    [block] = decorations.block_decorations
    assert block.anchor_line == 2
    assert block.placement == :below
    assert block.height == :dynamic
    assert block.group == :inline_ask

    rendered = block.render.(80)

    text =
      rendered
      |> Enum.flat_map(& &1)
      |> Enum.map_join("", fn {segment, _face} -> segment <> "\n" end)

    assert text =~ "Ask about line 3 of scratch.ex"
    assert text =~ "why?"
  end

  test "merge_decorations leaves other buffers unchanged" do
    active_buffer = self()

    other_buffer =
      start_supervised!({Agent, fn -> :ok end}, id: {:inline_render_buffer, make_ref()})

    ask =
      InlineAsk.new(
        active_buffer,
        %FileRef{kind: :buffer, display_name: "scratch.ex", buffer_pid: active_buffer},
        "scratch.ex",
        0
      )

    state = %{shell_state: %TraditionalState{inline_asks: %{active_buffer => ask}}}

    decorations = Render.merge_decorations(Decorations.new(), state, other_buffer)

    refute Decorations.has_block_decorations?(decorations)
  end
end
