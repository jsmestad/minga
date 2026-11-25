defmodule MingaEditor.FoldRangesFrameTest do
  @moduledoc """
  Fold ranges arrive from the parser after a parse's highlights. When they arrive with no key press, the editor still commits a frame whose gutter shows the fold marks (#4314).
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Test.HeadlessPort

  test "fold ranges that arrive with no input reach the gutter in a frame of their own" do
    ctx = start_editor("defmodule A do\n  def f, do: 1\nend\n")
    buffer = editor_state(ctx).workspace.buffers.active

    ref = HeadlessPort.prepare_await(ctx.port)
    send(ctx.editor, {:minga_highlight, {:fold_ranges, buffer, [{0, 2}]}})

    assert {:ok, frame} = HeadlessPort.collect_frame(ref)
    # The gutter is resident: the frame carries the entries that changed since the last commit.
    marks =
      for %{resident: {_state, _epoch, _total, overrides}} <- Map.values(frame.gutters),
          entry <- Map.values(overrides),
          do: {entry.buf_line, entry.display_type}

    assert {0, :fold_open} in marks
  end
end
