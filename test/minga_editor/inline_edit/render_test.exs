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
      InlineEdit.new(
        buffer_pid,
        %FileRef{kind: :buffer, display_name: "scratch.ex", buffer_pid: buffer_pid},
        "scratch.ex",
        {1, 2},
        "old text"
      )

    state = %{
      shell_runtime: %{state: TraditionalState.activate_inline_edit(%TraditionalState{}, edit)}
    }

    decorations = Render.merge_decorations(Decorations.new(), state, buffer_pid)

    assert Decorations.has_block_decorations?(decorations)
  end
end
