defmodule Minga.Buffer.AuthorshipTest do
  @moduledoc """
  A buffer reports who wrote every position, and your undo moves only your own edits, through the buffer process's public API.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess

  @minga EditSource.minga("task-1", "call-1")
  @task {:minga, "task-1"}

  defp start(content), do: start_supervised!({BufferProcess, content: content})

  defp minga_replace(buffer, content) do
    assert {:ok, _version} =
             BufferProcess.replace_content_if_version(
               buffer,
               BufferProcess.version(buffer),
               content,
               @minga
             )
  end

  test "text that predates tracking is unattributed, and nothing is past the end" do
    buffer = start("one\ntwo")

    assert BufferProcess.author_at(buffer, {0, 0}) == :unattributed
    assert BufferProcess.author_at(buffer, {1, 2}) == :unattributed
    assert BufferProcess.author_at(buffer, {1, 3}) == nil
  end

  test "every position reports you, Minga in its task, or unattributed" do
    buffer = start("alpha\nbeta\ngamma\n")
    minga_replace(buffer, "alpha\nBETA\ngamma\n")
    assert :ok = BufferProcess.move_to(buffer, {2, 0})
    assert :ok = BufferProcess.insert_text(buffer, "my ")

    assert BufferProcess.author_at(buffer, {0, 0}) == :unattributed
    assert BufferProcess.author_at(buffer, {1, 0}) == @task
    assert BufferProcess.author_at(buffer, {2, 0}) == :you

    assert BufferProcess.line_authors(buffer, 0, 10) == [
             [:unattributed],
             [@task],
             [:you, :unattributed],
             []
           ]

    assert BufferProcess.line_authors(buffer, 1, 1) == [[@task]]
  end

  test "Minga edits line 10 and you edit line 12: undo and reject each touch only their own text" do
    buffer = start(Enum.map_join(1..14, fn n -> "line #{n}\n" end))
    minga_replace(buffer, String.replace(BufferProcess.content(buffer), "line 10\n", "LINE 10\n"))
    assert :ok = BufferProcess.move_to(buffer, {11, 0})
    assert :ok = BufferProcess.apply_edit(buffer, 11, 0, 11, 3, "mine")

    assert :ok = BufferProcess.undo(buffer)
    assert BufferProcess.content(buffer) =~ "LINE 10\nline 11\nline 12\n"

    assert :ok = BufferProcess.redo(buffer)
    assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
    assert BufferProcess.content(buffer) =~ "line 10\nline 11\nmine 12\n"
  end

  test "text you type inside a Minga change belongs to you and survives its reject" do
    buffer = start("")
    minga_replace(buffer, "minga writes this\n")
    assert :ok = BufferProcess.move_to(buffer, {0, 6})
    assert :ok = BufferProcess.insert_text(buffer, "and you ")

    assert BufferProcess.author_at(buffer, {0, 6}) == :you

    assert [{@minga, [{{0, 0}, {0, 6}}, {{0, 14}, {1, 0}}]}] =
             BufferProcess.minga_changes(buffer, "task-1")

    assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
    assert BufferProcess.content(buffer) == "and you "
  end

  test "rejecting Minga's edit on a clean buffer leaves it clean" do
    buffer = start("saved\n")
    minga_replace(buffer, "saved\nminga\n")
    assert BufferProcess.dirty?(buffer)

    assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
    assert BufferProcess.content(buffer) == "saved\n"
    refute BufferProcess.dirty?(buffer)
  end

  test "your whole-buffer replacement keeps the authors of lines it left alone" do
    buffer = start("foo\nline\nfoo\n")
    minga_replace(buffer, "foo\nAGENT\nfoo\n")
    assert :ok = BufferProcess.replace_content(buffer, "bar\nAGENT\nbar\n")

    assert BufferProcess.line_authors(buffer, 0, 3) == [[:you], [@task], [:you]]
    assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
    assert BufferProcess.content(buffer) == "bar\nline\nbar\n"
  end

  test "a blocked undo changes neither the document nor either history" do
    buffer = start("")
    assert :ok = BufferProcess.insert_text(buffer, "hello world")
    minga_replace(buffer, "hello there")
    version = BufferProcess.version(buffer)

    assert BufferProcess.undo(buffer) == {:blocked, {:overlaps, @minga}}
    assert BufferProcess.content(buffer) == "hello there"
    assert BufferProcess.version(buffer) == version
    assert BufferProcess.last_undo_source(buffer) == :user
    assert [{@minga, _regions}] = BufferProcess.minga_changes(buffer, "task-1")
  end

  test "log text appended to a bounded buffer is unattributed, and trimming forgets your text" do
    buffer = start("")
    assert :ok = BufferProcess.insert_text(buffer, "typed")
    assert :ok = BufferProcess.bounded_append(buffer, "\nlog line", 10, 1_000)
    assert :ok = BufferProcess.bounded_append(buffer, "\nmore", 2, 1_000)

    assert BufferProcess.content(buffer) == "log line\nmore"
    assert BufferProcess.line_authors(buffer, 0, 2) == [[:unattributed], [:unattributed]]
  end

  property "authorship stays in step with the document through the public edit paths" do
    check all(commands <- StreamData.list_of(command(), max_length: 30), max_runs: 40) do
      buffer =
        start_supervised!({BufferProcess, content: "abc\ndef\n"},
          id: {:authorship, System.unique_integer([:positive])}
        )

      for command <- commands do
        run(buffer, command)
        assert_in_step(buffer)
      end
    end
  end

  defp command do
    StreamData.tuple({
      StreamData.member_of([
        :insert,
        :delete,
        :minga,
        :undo,
        :redo,
        :append,
        :lines,
        :reject,
        :replace,
        :bounded_append,
        :shift,
        :lsp_edits,
        :find_replace,
        :snapshot
      ]),
      StreamData.integer(0..100),
      StreamData.string([?a..?c, ?\n], max_length: 4)
    })
  end

  defp run(buffer, {:insert, n, text}) do
    move_somewhere(buffer, n)
    BufferProcess.insert_text(buffer, text)
  end

  defp run(buffer, {:delete, n, _text}) do
    move_somewhere(buffer, n)
    BufferProcess.delete_before(buffer)
  end

  defp run(buffer, {:minga, n, text}) do
    content = BufferProcess.content(buffer)
    at = rem(n, byte_size(content) + 1)
    new = binary_part(content, 0, at) <> text <> binary_part(content, at, byte_size(content) - at)
    source = EditSource.minga("task-#{rem(n, 2)}", "call-#{rem(n, 3)}")
    BufferProcess.replace_content_if_version(buffer, BufferProcess.version(buffer), new, source)
  end

  defp run(buffer, {:undo, _n, _text}), do: BufferProcess.undo(buffer)
  defp run(buffer, {:redo, _n, _text}), do: BufferProcess.redo(buffer)
  defp run(buffer, {:append, _n, text}), do: BufferProcess.append(buffer, text)
  defp run(buffer, {:reject, _n, _text}), do: BufferProcess.undo_agent_session(buffer)

  defp run(buffer, {:lines, n, _text}) do
    line = rem(n, BufferProcess.line_count(buffer))
    BufferProcess.delete_lines(buffer, line, line)
  end

  defp run(buffer, {:replace, _n, text}), do: BufferProcess.replace_content(buffer, text)

  defp run(buffer, {:bounded_append, n, text}),
    do: BufferProcess.bounded_append(buffer, text, 3 + rem(n, 4), 40)

  defp run(buffer, {:shift, n, _text}) do
    line = rem(n, BufferProcess.line_count(buffer))
    shift = if rem(n, 2) == 0, do: {:indent, "  "}, else: {:dedent, 2}
    BufferProcess.shift_lines(buffer, line, line, shift)
  end

  defp run(buffer, {:lsp_edits, n, text}) do
    line = rem(n, BufferProcess.line_count(buffer))
    BufferProcess.apply_edits(buffer, [{{line, 0}, {line, rem(n, 3)}, text}])
  end

  defp run(buffer, {:find_replace, n, text}) do
    needle = Enum.at(["a", "b", "c\n"], rem(n, 3))
    source = if rem(n, 2) == 0, do: :user, else: @minga
    BufferProcess.find_and_replace(buffer, needle, text, source)
  end

  defp run(buffer, {:snapshot, _n, text}) do
    snapshot = BufferProcess.snapshot(buffer)
    BufferProcess.commit_snapshot(buffer, Minga.Buffer.Document.insert_text(snapshot, text))
  end

  defp move_somewhere(buffer, n) do
    line = rem(n, BufferProcess.line_count(buffer))
    BufferProcess.move_to(buffer, {line, rem(n, 3)})
  end

  # A byte past the end has no author, and every byte before it has one.
  # Every line that holds bytes reports at least one author.
  defp assert_in_step(buffer) do
    content = BufferProcess.content(buffer)
    lines = String.split(content, "\n")
    last = length(lines) - 1
    [last_text | _earlier] = Enum.reverse(lines)

    assert BufferProcess.author_at(buffer, {last, byte_size(last_text)}) == nil

    authors = BufferProcess.line_authors(buffer, 0, length(lines))
    assert length(authors) == length(lines)

    for {{line, authors}, index} <- lines |> Enum.zip(authors) |> Enum.with_index() do
      holds_bytes? = index < last or line != ""
      assert authors != [] == holds_bytes?
    end
  end
end
