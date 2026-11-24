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

  defp start(content),
    do: start_supervised!({BufferProcess, content: content}, id: make_ref())

  # Replaces `length` bytes at `position` as one edit by `source`, the way a tool's byte-range edit does.
  defp replace_at(buffer, position, length, text, source \\ EditSource.user()) do
    version = BufferProcess.version(buffer)

    assert {:ok, _version} =
             BufferProcess.replace_byte_range_if_version(
               buffer,
               version,
               position,
               length,
               text,
               source
             )
  end

  defp step(task, step), do: EditSource.minga(task, step)

  defp minga_replace(buffer, content, source \\ @minga) do
    assert {:ok, _version} =
             BufferProcess.replace_content_if_version(
               buffer,
               BufferProcess.version(buffer),
               content,
               source
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
             [@task, :unattributed],
             [:you, :unattributed],
             []
           ]

    assert BufferProcess.line_authors(buffer, 1, 1) == [[@task, :unattributed]]
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

    # Only the changed bytes change author; each newline stays as the file had it.
    assert BufferProcess.line_authors(buffer, 0, 3) == [
             [:you, :unattributed],
             [@task, :unattributed],
             [:you, :unattributed]
           ]

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

  describe "rejecting a task after you rewrote its replacement" do
    test "your replacement of exactly Minga's text keeps what Minga replaced deleted" do
      buffer = start("axb")
      replace_at(buffer, {0, 1}, 1, "y", step("t1", "s1"))
      replace_at(buffer, {0, 1}, 1, "z")

      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "azb"
      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "axb"
    end

    test "a replacement one byte wider on either side also keeps it deleted" do
      for {position, length, expected} <- [{{0, 1}, 2, "az"}, {{0, 0}, 2, "zb"}] do
        buffer = start("axb")
        replace_at(buffer, {0, 1}, 1, "y", step("t1", "s1"))
        replace_at(buffer, position, length, "z")

        assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
        assert BufferProcess.content(buffer) == expected
      end
    end

    test "your :s on a line Minga extended does not duplicate the line on reject" do
      buffer = start("x = 1\ny = 2\n")
      minga_replace(buffer, "x = 1 # TODO\ny = 2\n")
      assert :ok = BufferProcess.replace_content(buffer, "z = 1 # TODO\ny = 2\n")

      assert BufferProcess.author_at(buffer, {0, 8}) == @task
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "z = 1\ny = 2\n"
    end

    test "a task whose text a newer task rewrote is blocked until the newer one is reverted" do
      buffer = start("axb\nq")
      replace_at(buffer, {0, 1}, 1, "y", step("t1", "s1"))
      replace_at(buffer, {0, 1}, 1, "w", step("t2", "s1"))
      replace_at(buffer, {1, 0}, 1, "Q", step("t1", "s2"))

      assert BufferProcess.undo_agent_session(buffer) ==
               {:blocked, {:overlaps, {:minga, "t2", "s1"}}}

      assert BufferProcess.content(buffer) == "awb\nQ"
    end

    test "deleting all of Minga's insertion leaves nothing for the reject to bring back" do
      buffer = start("a b")
      replace_at(buffer, {0, 1}, 0, "XYZ", step("t1", "s1"))
      replace_at(buffer, {0, 1}, 3, "")

      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "a b"
      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "a b"
    end
  end

  describe "only bytes that changed change author" do
    test "Minga's edit elsewhere on your line leaves your text yours and your undo free" do
      buffer = start("def run(x), do: x\nend\n")
      assert :ok = BufferProcess.move_to(buffer, {0, 17})
      assert :ok = BufferProcess.insert_text(buffer, " # keep me")
      content = BufferProcess.content(buffer)
      identity = {:buffer, "/edit"}

      expected =
        Minga.Buffer.FileMutation.revision(content, BufferProcess.version(buffer), identity)

      assert {:ok, _receipt} =
               BufferProcess.conditional_mutate(
                 buffer,
                 expected,
                 {:edit, [{"run(x)", "run(y)"}]},
                 identity,
                 step("t", "call-1")
               )

      assert BufferProcess.author_at(buffer, {0, 20}) == :you
      assert BufferProcess.author_at(buffer, {0, 4}) == :unattributed
      assert BufferProcess.author_at(buffer, {0, 8}) == {:minga, "t"}
      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "def run(y), do: x\nend\n"
    end

    test "indenting lines Minga changed keeps Minga's text Minga's, so the reject still removes it" do
      buffer = start("a\nb\nc\n")
      replace_at(buffer, {1, 0}, 1, "B", step("t", "s"))
      assert :ok = BufferProcess.shift_lines(buffer, 0, 2, {:indent, "  "})

      assert BufferProcess.line_authors(buffer, 0, 3) == [
               [:you, :unattributed],
               [:you, {:minga, "t"}, :unattributed],
               [:you, :unattributed]
             ]

      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "  a\n  b\n  c\n"
    end

    test "a large :%s past the line diff budget leaves Minga's line Minga's" do
      lines = 1_200

      base =
        Enum.map_join(1..lines, fn i ->
          if rem(i, 2) == 0, do: "foo #{i}\n", else: "bar #{i}\n"
        end)

      buffer = start(base)
      replace_at(buffer, {600, 0}, 3, "MINGA", step("t", "s"))

      assert :ok =
               BufferProcess.replace_content(
                 buffer,
                 String.replace(BufferProcess.content(buffer), "foo", "qux")
               )

      assert BufferProcess.author_at(buffer, {600, 0}) == {:minga, "t"}
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      content = BufferProcess.content(buffer)
      assert content =~ "bar 601\n"
      refute content =~ "MINGA"
      assert length(String.split(content, "\n")) == lines + 1
    end
  end

  describe "SPC a u" do
    test "reverts the task that edited most recently, not the one that opened its step last" do
      buffer = start("a\nb\nc\n")
      minga_replace(buffer, "A\nb\nc\n", step("t1", "s1"))
      minga_replace(buffer, "A\nB\nc\n", step("t2", "s1"))
      minga_replace(buffer, "A\nB\nC\n", step("t1", "s1"))

      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "a\nB\nc\n"
    end
  end

  describe "positions" do
    test "author_at returns nil for a line or column past the end" do
      buffer = start("ab\ncd")

      assert BufferProcess.author_at(buffer, {0, 2}) == :unattributed
      assert BufferProcess.author_at(buffer, {0, 3}) == nil
      assert BufferProcess.author_at(buffer, {1, 2}) == nil
      assert BufferProcess.author_at(buffer, {99, 0}) == nil
    end
  end

  describe "version after an interleaved undo" do
    test "undoing your edit after a Minga edit takes a new version instead of an old one" do
      buffer = start("one\n")
      assert :ok = BufferProcess.insert_text(buffer, "x")
      minga_replace(buffer, "xone\ntwo\n")
      before = BufferProcess.version(buffer)

      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "one\ntwo\n"
      assert BufferProcess.version(buffer) > before
    end
  end

  describe "reload" do
    @describetag :tmp_dir

    test "reloading keeps Minga's unreviewed steps and their authorship", %{tmp_dir: dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "one\ntwo\nthree\n")
      buffer = start_supervised!({BufferProcess, file_path: path}, id: make_ref())
      replace_at(buffer, {1, 0}, 3, "TWO", step("t", "s"))
      assert :ok = BufferProcess.save(buffer)
      changes = BufferProcess.minga_changes(buffer, "t")

      assert :ok = BufferProcess.reload(buffer)
      assert BufferProcess.minga_changes(buffer, "t") == changes

      File.write!(path, "ONE\nTWO\nthree\n")
      assert :ok = BufferProcess.reload(buffer)
      assert BufferProcess.content(buffer) == "ONE\nTWO\nthree\n"
      assert BufferProcess.author_at(buffer, {1, 0}) == {:minga, "t"}
      assert BufferProcess.author_at(buffer, {0, 0}) == :unattributed
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "ONE\ntwo\nthree\n"
    end
  end

  describe "a history out of step with its document" do
    test "resets authorship, says so in *Messages*, and keeps the buffer and its text" do
      registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      :ok = Minga.Events.subscribe(:log_message, registry)

      buffer =
        start_supervised!({BufferProcess, content: "hello", events_registry: registry},
          id: make_ref()
        )

      :sys.replace_state(buffer, fn state ->
        %{
          state
          | undo_history: Minga.Buffer.UndoHistory.new(Minga.Buffer.Document.new("wrong size"))
        }
      end)

      assert :ok = BufferProcess.insert_text(buffer, "x")
      assert BufferProcess.content(buffer) == "xhello"
      assert BufferProcess.author_at(buffer, {0, 1}) == :unattributed

      assert_receive {:minga_event, :log_message, %{level: :error, text: text}}
      assert text =~ "were reset after an internal error"
    end
  end

  property "authorship stays in step with the document through the public edit paths" do
    registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    :ok = Minga.Events.subscribe(:log_message, registry)

    check all(commands <- StreamData.list_of(command(), max_length: 30), max_runs: 40) do
      buffer =
        start_supervised!({BufferProcess, content: "abc\nd\u00e9f\n", events_registry: registry},
          id: {:authorship, System.unique_integer([:positive])}
        )

      for command <- commands do
        run(buffer, command)
        assert_in_step(buffer)
      end

      # The history never had to be rebuilt: the safety net stays unused in normal use.
      refute_received {:minga_event, :log_message, %{level: :error}}
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
