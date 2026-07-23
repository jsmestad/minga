defmodule MingaEditor.InlineEdit.RenderTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Project.FileRef
  alias MingaEditor.InlineEdit.Render
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.InlineEdit

  test "merge_decorations reads flattened render-pipeline shell state" do
    buffer_pid = self()

    edit =
      buffer_pid
      |> InlineEdit.new(
        %FileRef{kind: :buffer, display_name: "scratch.ex", buffer_pid: buffer_pid},
        "scratch.ex",
        {1, 2},
        "old text"
      )
      |> InlineEdit.proposed("new text")

    state = %{
      shell_runtime: %{state: TraditionalState.activate_inline_edit(%TraditionalState{}, edit)}
    }

    decorations = Render.merge_decorations(Decorations.new(), state, buffer_pid)

    assert Decorations.has_block_decorations?(decorations)
    [block] = decorations.block_decorations

    text =
      block.render.(80)
      |> Enum.flat_map(& &1)
      |> Enum.map_join("", fn {segment, _face} -> segment <> "\n" end)

    assert text =~ "- old text"
    assert text =~ "+ new text"
  end
end
