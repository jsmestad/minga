defmodule MingaEditor.Renderer.SearchHighlightTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Editing.Search.Match
  alias Minga.Mode.CommandState
  alias Minga.Mode.SubstituteConfirmState
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.Renderer.SearchHighlight
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Theme

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

  test "advancing confirmation repaints the current match without changing visible matches" do
    lines = ["x", " x"]
    first = Match.new(0, 0, 1)
    second = Match.new(1, 1, 1)
    matches = [first, second]
    mode_state = SubstituteConfirmState.new(matches, "x", "y", Enum.join(lines, "\n"))
    workspace = SessionState.transition_mode(%SessionState{}, :substitute_confirm, mode_state)
    editor = %EditorState{workspace: workspace}

    base = Decorations.new()
    colors = %Theme.Search{current_bg: 0xFF6C6B, highlight_bg: 0xECBE7B, highlight_fg: 0x282C34}
    assert SearchHighlight.search_matches_for_lines(editor, lines, 0) == matches
    current = SearchHighlight.current_confirm_match(editor)
    assert current == first
    key = SearchHighlight.composition_key(editor)

    {before_decorations, cache} =
      ContentHelpers.merge_search_decorations(base, matches, current, colors, nil)

    assert background(before_decorations, 0) == colors.current_bg
    assert background(before_decorations, 1) == colors.highlight_bg

    next = SubstituteConfirmState.skip(mode_state)
    workspace = SessionState.transition_mode(workspace, :substitute_confirm, next)
    editor = %{editor | workspace: workspace}

    assert SearchHighlight.search_matches_for_lines(editor, lines, 0) == matches
    current = SearchHighlight.current_confirm_match(editor)
    assert current == second
    refute SearchHighlight.composition_key(editor) == key

    {after_decorations, _cache} =
      ContentHelpers.merge_search_decorations(base, matches, current, colors, cache)

    assert background(after_decorations, 0) == colors.highlight_bg
    assert background(after_decorations, 1) == colors.current_bg

    editor = %{editor | workspace: SessionState.transition_mode(workspace, :normal, next)}
    assert SearchHighlight.current_confirm_match(editor) == nil
  end

  defp background(decorations, line) do
    [highlight] = Decorations.highlights_for_line(decorations, line)
    highlight.style.bg
  end
end
