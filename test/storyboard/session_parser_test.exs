defmodule Minga.Storyboard.SessionParserTest do
  @moduledoc """
  Every storyboard session runs the real tree-sitter parser (#4036): it starts highlighted, and an edit is parsed again, the way it is in the app.
  """

  use ExUnit.Case, async: true

  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Session

  @moduletag :storyboard

  test "a session starts with the parser's highlights applied" do
    session = Registry.drive("edit.plain")
    assert Session.highlight_span_count(session) > 0
    Session.stop(session)
  end

  test "an edit reaches the shared parser, which highlights the new text" do
    session = Registry.drive("edit.plain")
    original = session |> buffer_text() |> byte_size()
    assert highlighted_extent(session) <= original

    session = Session.press(session, "G o : o k esc")
    assert byte_size(buffer_text(session)) > original

    assert eventually(fn -> highlighted_extent(session) > original end),
           "the new line was never highlighted; the session's edits do not reach the shared parser"

    Session.stop(session)
  end

  defp buffer_text(session), do: Minga.Test.EditorCase.buffer_content(session.ctx)

  # The end of the last highlighted span, in bytes: it moves past the old text only after a parse of the edit.
  defp highlighted_extent(session) do
    state = Minga.Test.EditorCase.editor_state(session.ctx)
    spans = MingaEditor.HighlightSync.get_active_highlight(state).spans
    spans |> Tuple.to_list() |> Enum.map(& &1.end_byte) |> Enum.max(fn -> 0 end)
  end

  # The parser answers asynchronously; poll the observable state with a deadline instead of sleeping a fixed time.
  defp eventually(check, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        receive do
        after
          10 -> eventually(check, deadline)
        end
    end
  end
end
