defmodule MingaEditor.Renderer.SearchHighlightTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Search.Match
  alias Minga.Mode.CommandState
  alias MingaEditor.Renderer.SearchHighlight
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState

  test "global substitute preview returns output-byte spans in buffer order" do
    workspace =
      SessionState.transition_mode(%SessionState{}, :command, CommandState.new("%s/x/é/g"))

    editor = %EditorState{workspace: workspace}

    assert {["αé é", "unchanged", "éé!"],
            [
              %Match{line: 10, col: 2, length: 2},
              %Match{line: 10, col: 5, length: 2},
              %Match{line: 12, col: 0, length: 2},
              %Match{line: 12, col: 2, length: 2}
            ]} =
             SearchHighlight.maybe_substitute_preview(editor, ["αx x", "unchanged", "xx!"], 10)
  end
end
