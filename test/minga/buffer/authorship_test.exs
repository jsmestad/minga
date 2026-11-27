defmodule Minga.Buffer.AuthorshipTest do
  @moduledoc """
  A buffer reports who wrote every position, and your undo moves only your own edits, through the buffer process's public API.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory
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

  # Compaction runs in slices the buffer sends itself; wait until none is left.
  defp settle_compaction(buffer, attempts \\ 10_000)
  defp settle_compaction(_buffer, 0), do: flunk("compaction never settled")

  defp settle_compaction(buffer, attempts) do
    case :sys.get_state(buffer) do
      %{compaction_scheduled: true} -> settle_compaction(buffer, attempts - 1)
      _idle -> buffer
    end
  end

  defp minga_replace(buffer, content, source \\ @minga) do
    assert {:ok, _version} =
             BufferProcess.replace_content_if_version(
               buffer,
               BufferProcess.version(buffer),
               content,
               source
             )
  end

  test "a prepared decision cannot affect another buffer or a newer revision" do
    first = start("before\nlocal\n")
    second = start("before\nlocal\n")
    minga_replace(first, "after\nlocal\n")
    minga_replace(second, "after\nlocal\n")

    assert {:ok, initial, @task, 1} = Minga.Buffer.prepare_review(first, :latest)
    assert {:error, :stale_review} = Minga.Buffer.decide_review(second, initial, :reject)
    assert BufferProcess.content(second) == "after\nlocal\n"

    replace_at(first, {1, 5}, 0, "!")
    assert {:error, :stale_review} = Minga.Buffer.decide_review(first, initial, :reject)
    assert BufferProcess.content(first) == "after\nlocal!\n"

    assert {:ok, current, @task, 1} = Minga.Buffer.prepare_review(first, :latest)
    assert {:ok, [receipt]} = Minga.Buffer.decide_review(first, current, :reject)
    assert BufferProcess.content(first) == "before\nlocal!\n"
    assert :ok = Minga.Buffer.restore_review(first, receipt)
    assert BufferProcess.content(first) == "after\nlocal!\n"
  end

  test "a rejected unit cannot restore different work in another buffer" do
    first = start("old")
    second = start("old")
    minga_replace(first, "first")
    minga_replace(second, "second")
    assert {:ok, target, @task, 1} = Minga.Buffer.prepare_review(first, :latest)
    assert {:ok, [receipt]} = Minga.Buffer.decide_review(first, target, :reject)
    assert {:ok, other_target, @task, 1} = Minga.Buffer.prepare_review(second, :latest)
    assert {:ok, [other_receipt]} = Minga.Buffer.decide_review(second, other_target, :reject)

    assert {:error, :stale_review} = Minga.Buffer.restore_review(second, receipt)
    assert BufferProcess.content(second) == "old"
    assert :ok = Minga.Buffer.restore_review(second, other_receipt)
    assert BufferProcess.content(second) == "second"
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

  test "appended output has no author and survives undo of an earlier user edit" do
    buffer = start("")
    assert :ok = BufferProcess.insert_text(buffer, "typed")
    assert :ok = BufferProcess.append(buffer, " output")

    assert BufferProcess.author_at(buffer, {0, 0}) == :you
    assert BufferProcess.author_at(buffer, {0, 6}) == :unattributed
    assert :ok = BufferProcess.undo(buffer)
    assert BufferProcess.content(buffer) == " output"
    BufferProcess.undo(buffer)
    assert BufferProcess.content(buffer) == " output"
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

    test "SPC a u reverts every step of the latest task, with a newer task's step that rewrote one of them" do
      registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      :ok = Minga.Events.subscribe(:log_message, registry)

      buffer =
        start_supervised!({BufferProcess, content: "axb\nq", events_registry: registry},
          id: make_ref()
        )

      replace_at(buffer, {0, 1}, 1, "y", step("t1", "s1"))
      replace_at(buffer, {0, 1}, 1, "w", step("t2", "s1"))
      replace_at(buffer, {1, 0}, 1, "Q", step("t1", "s2"))

      assert {:ok, 2} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "axb\nq"

      assert_receive {:minga_event, :log_message,
                      %{
                        text:
                          "Reverted Minga task t1, with Minga task t2, in this buffer (2 step(s))"
                      }}

      assert BufferProcess.undo_agent_session(buffer) == :empty
    end

    test "a task rewriting its own text past the run budget is compacted off the edit path, and reverts exactly" do
      registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      :ok = Minga.Events.subscribe(:log_message, registry)
      original = Enum.map_join(1..40, fn n -> "value_#{n} = beta\n" end)

      buffer =
        start_supervised!(
          {BufferProcess, content: original, events_registry: registry, history_run_budget: 60},
          id: make_ref()
        )

      for round <- 1..6 do
        minga_replace(
          buffer,
          String.replace(BufferProcess.content(buffer), ~r/beta\d*/, "beta#{round}"),
          step("t", "s#{round}")
        )
      end

      assert_receive {:minga_event, :log_message,
                      %{text: "Compacted Minga's history in " <> compacted}}

      assert compacted =~ "task t step s1 into task t step s2"
      %{undo_history: history} = :sys.get_state(buffer)
      provenance = UndoHistory.provenance(history)
      assert Provenance.run_count(provenance) <= 45 or Provenance.draft_count(provenance) == 0

      assert {:ok, _steps} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == original
    end

    test "steps merged while recording, past twice the budget, are named in *Messages* too" do
      registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      :ok = Minga.Events.subscribe(:log_message, registry)
      original = Enum.map_join(1..40, fn n -> "value_#{n} = beta\n" end)

      buffer =
        start_supervised!(
          {BufferProcess, content: original, events_registry: registry, history_run_budget: 10},
          id: make_ref()
        )

      for round <- 1..2 do
        minga_replace(
          buffer,
          String.replace(BufferProcess.content(buffer), ~r/beta\d*/, "beta#{round}"),
          step("t", "s#{round}")
        )
      end

      assert_receive {:minga_event, :log_message,
                      %{text: "Compacted Minga's history in " <> compacted}}

      assert compacted =~ "while recording: merged task t step s1 into task t step s2"
    end

    test "SPC a u reverts what it can, names the line of your edit that holds the rest, and names an edit it drops" do
      registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      :ok = Minga.Events.subscribe(:log_message, registry)

      buffer =
        start_supervised!({BufferProcess, content: "top\nxay\n", events_registry: registry},
          id: make_ref()
        )

      replace_at(buffer, {1, 1}, 1, "bcd", step("t", "s1"))
      replace_at(buffer, {1, 2}, 1, "QR")
      replace_at(buffer, {1, 3}, 1, "Z", step("t", "s2"))

      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "top\nxbQRdy\n"

      assert_receive {:minga_event, :log_message,
                      %{text: "Reverted 1 of 2 steps of Minga task t in " <> rest}}

      assert rest =~ "your edit near line 2 holds the rest; undo it (u), then SPC a u again"

      assert :ok = BufferProcess.undo(buffer)
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "top\nxay\n"

      # Your edit inside the change that your own next edit removed has nothing visible: it goes with the step.
      replace_at(buffer, {1, 1}, 1, "bcd", step("t", "s3"))
      replace_at(buffer, {1, 2}, 1, "Q")
      replace_at(buffer, {1, 2}, 1, "")
      assert BufferProcess.content(buffer) == "top\nxbdy\n"
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "top\nxay\n"

      assert_receive {:minga_event, :log_message,
                      %{text: "Dropped your edit near line 2 of " <> _}}
    end

    # Check 5: a large file where Minga rewrites scattered lines and adds one at the top around a word you typed.
    test "on a 12000-line file, scattered Minga rewrites and a new top line keep your word and its undo" do
      lines = for n <- 1..12_000, do: "    value_#{n} = compute(alpha_#{n}, beta, gamma)\n"
      buffer = start(Enum.join(lines))
      replace_at(buffer, {6000, 4}, 0, "mine ")
      content = BufferProcess.content(buffer)

      rewritten =
        content
        |> String.split("\n")
        |> Enum.with_index()
        |> Enum.map_join("\n", fn {line, n} ->
          if rem(n, 120) == 7, do: String.replace(line, "beta", "BETA"), else: line
        end)

      minga_replace(buffer, "# header\n" <> rewritten, step("t", "s1"))

      assert BufferProcess.author_at(buffer, {6001, 5}) == :you
      assert BufferProcess.author_at(buffer, {6001, 12}) == :unattributed
      assert BufferProcess.author_at(buffer, {8, 40}) == :unattributed
      assert BufferProcess.author_at(buffer, {8, 33}) == {:minga, "t"}
      assert :ok = BufferProcess.undo(buffer)
      refute BufferProcess.content(buffer) =~ "mine "
    end

    # Check 5, reversed: your formatter changes the line count over Minga's unreviewed text.
    test "your formatter over unreviewed Minga text keeps Minga's unchanged words" do
      buffer = start("a = 1\nb = 2\n")
      minga_replace(buffer, "a = 1\nalpha beta gamma delta\nb = 2\n", step("t", "s1"))

      assert :ok =
               BufferProcess.replace_content(
                 buffer,
                 "a = 1\nalpha beta\ngamma delta\nb = 2\n",
                 :lsp
               )

      assert BufferProcess.author_at(buffer, {1, 0}) == {:minga, "t"}
      assert BufferProcess.author_at(buffer, {2, 0}) == {:minga, "t"}
      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "a = 1\nalpha beta gamma delta\nb = 2\n"
    end

    # Round 5 R2, CH1 and CH2: two steps of one task over one spot, then your retype of the result.
    test "retyping what two steps of a task wrote over one word rejects to your text alone" do
      for {original, start, width, first, second, mine, expected} <- [
            {"abc\n", 1, 1, "X", "Y", "Z", "aZc\n"},
            {"call(foo)\n", 5, 3, "bar", "baz", "qux", "call(qux)\n"}
          ] do
        buffer = start(original)
        replace_at(buffer, {0, start}, width, first, step("t1", "s1"))
        replace_at(buffer, {0, start}, byte_size(first), second, step("t1", "s2"))
        replace_at(buffer, {0, start}, byte_size(second), mine)
        assert {:ok, 2} = BufferProcess.undo_agent_session(buffer)
        assert BufferProcess.content(buffer) == expected
      end
    end

    # Round 5 R2 by change identity (Addendum 2): each edit records what it replaced, so a consumed replacement covers
    # exactly that, and a partly consumed one refuses the reject until your edit is undone.
    test "deleting what one step wrote over its own earlier text rejects to the text before the step" do
      buffer = start("ab\n")
      replace_at(buffer, {0, 0}, 1, "X", step("t", "s1"))
      replace_at(buffer, {0, 0}, 1, "Y", step("t", "s1"))
      replace_at(buffer, {0, 0}, 1, "")
      assert BufferProcess.content(buffer) == "b\n"
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "b\n"
    end

    test "two edits of one step stay apart: deleting the first one's text keeps the second one's deletion" do
      buffer = start("ab\n")
      replace_at(buffer, {0, 0}, 1, "X", step("t1", "s1"))
      replace_at(buffer, {0, 1}, 1, "", step("t1", "s1"))
      replace_at(buffer, {0, 0}, 1, "")
      assert BufferProcess.content(buffer) == "\n"
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "b\n"
    end

    test "CV1: another task's deletion of one replacement reverts on its own, whatever you did to the other" do
      buffer = start("ab\n")
      replace_at(buffer, {0, 0}, 1, "X", step("t1", "c1"))
      replace_at(buffer, {0, 1}, 1, "Y", step("t1", "c1"))
      replace_at(buffer, {0, 1}, 1, "", step("t2", "c1"))
      replace_at(buffer, {0, 0}, 1, "")
      assert BufferProcess.content(buffer) == "\n"
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "Y\n"
    end

    # Partial CH2: your "q" consumed the second step's "z" but only part of the first step's "bar". The second step
    # reverts; the first is held by your edit until you undo it, then reverts exactly.
    test "retyping only the second step's letter holds the first step until you undo it, then rejects exactly" do
      buffer = start("call(foo)\n")
      replace_at(buffer, {0, 5}, 3, "bar", step("t1", "s1"))
      replace_at(buffer, {0, 5}, 3, "baz", step("t1", "s2"))
      replace_at(buffer, {0, 7}, 1, "q")
      assert BufferProcess.content(buffer) == "call(baq)\n"

      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "call(baq)\n"
      assert {:blocked, _overlap} = BufferProcess.undo_agent_session(buffer)
      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "call(bar)\n"
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "call(foo)\n"
    end

    # The hybrid rule for merge classes: your edit sits between two steps of one task, touched by both. Compaction must
    # not merge those steps, or the class would be held by your edit while the newer step blocks your undo of it.
    test "compaction never merges steps of one task around your edit that both touched" do
      buffer =
        start_supervised!({BufferProcess, content: "aaa bbb\n", history_run_budget: 1},
          id: make_ref()
        )

      minga_replace(buffer, "AAA BBB\n", step("t1", "s1"))
      replace_at(buffer, {0, 4}, 2, "xy")
      minga_replace(buffer, "QQQ ZyB\n", step("t1", "s2"))
      settle_compaction(buffer)
      %{undo_history: history} = :sys.get_state(buffer)
      assert Provenance.draft_count(UndoHistory.provenance(history)) > 0

      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "AAA xyB\n"
      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "AAA BBB\n"
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "aaa bbb\n"
    end

    # Merge consequence 2, from Addendum 4 F2: without compaction a press reverts step s1 and stops where your edit
    # holds s4. With a budget of 3, s4 is merged into s1 before your edits, so your edit holds the class: the press
    # reports the hold and stays on task t1 instead of moving on to t2.
    test "F2: a press stays on the task your edit holds, whether or not compaction merged its steps" do
      for {opts, expected_result, expected_text, expected_message} <- [
            {[], {:ok, 1}, "afbarb",
             ~r/^1 of 2 steps of Minga task t1 .*your edit near line 1 holds the rest; undo it/},
            {[history_run_budget: 3], {:blocked, {:overlaps, :you}}, "afb",
             ~r/^0 steps of Minga task t1 .*your edit near line 1 holds them; undo it/}
          ] do
        registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
        start_supervised!({Registry, keys: :duplicate, name: registry}, id: make_ref())
        :ok = Minga.Events.subscribe(:log_message, registry)

        buffer =
          start_supervised!({BufferProcess, [content: "", events_registry: registry] ++ opts},
            id: make_ref()
          )

        at =
          &Minga.Buffer.Position.from_point(
            Minga.Buffer.Document.new(BufferProcess.content(buffer)),
            &1
          )

        replace_at(buffer, at.(0), 0, "afooa", step("t2", "s1"))
        replace_at(buffer, at.(5), 0, "😀")
        replace_at(buffer, at.(3), 6, "barbarb", step("t1", "s4"))
        replace_at(buffer, at.(7), 3, "", step("t1", "s1"))
        :ok = BufferProcess.break_undo_coalescing(buffer)
        replace_at(buffer, at.(4), 1, "")
        replace_at(buffer, at.(2), 3, "")
        settle_compaction(buffer)
        assert BufferProcess.content(buffer) == "afb"
        assert BufferProcess.undo_agent_session(buffer) == expected_result
        assert BufferProcess.content(buffer) == expected_text
        assert_receive {:minga_event, :log_message, %{text: "Reverted " <> message}}
        assert message =~ expected_message
      end
    end

    # The press's one exception: it leaves a task your edit holds only when your next undo is itself blocked by a later
    # Minga step. Here your "e", typed inside b1's replacement, holds b1, while a1 deleted your newer "y", so `u` must
    # wait for a1; staying on task b would leave neither the press nor `u` able to move.
    test "a press moves past a task your edit holds when your next undo waits for another task's step" do
      buffer = start("q\n")
      replace_at(buffer, {0, 0}, 1, "BCD", step("b", "b1"))
      replace_at(buffer, {0, 1}, 1, "e")
      :ok = BufferProcess.break_undo_coalescing(buffer)
      replace_at(buffer, {0, 3}, 0, "y")
      :ok = BufferProcess.break_undo_coalescing(buffer)
      replace_at(buffer, {0, 3}, 1, "", step("a", "a1"))
      replace_at(buffer, {0, 3}, 0, "Z", step("b", "b2"))
      assert BufferProcess.content(buffer) == "BeDZ\n"

      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "BeD\n"
      assert {:blocked, {:overlaps, {:minga, "a", "a1"}}} = BufferProcess.undo(buffer)
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "BeDy\n"
      assert :ok = BufferProcess.undo(buffer)
      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "BCD\n"
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "q\n"
    end

    # Round 5b: a deletion slides only by grapheme clusters as Unicode defines them, so regional-indicator flags and
    # conjoining Hangul jamo stay whole; the reject never leaves a lone code point that never existed.
    test "a deletion next to Minga's look-alike cluster never splits a flag or a jamo syllable" do
      for {base, minga} <- [
            {"\u{1F1EB}\u{1F1F7}", "\u{1F1EB}\u{1F1EE}"},
            {"\u{1F1FA}\u{1F1F8}", "\u{1F1FA}\u{1F1E6}"},
            {"\u{1F1EB}\u{1F1F7}", "\u{1F1EB}"},
            {"\u1100\u1161", "\u1100\u1162"},
            {"1\uFE0F\u20E3", "2\uFE0F\u20E3"}
          ] do
        buffer = start(base <> "X\n")
        replace_at(buffer, {0, byte_size(base)}, 0, minga, step("t", "s"))
        replace_at(buffer, {0, 0}, byte_size(base), "")
        assert BufferProcess.content(buffer) == minga <> "X\n"
        assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
        assert BufferProcess.content(buffer) == "X\n", "#{inspect(base)} before #{inspect(minga)}"
        assert :ok = BufferProcess.undo(buffer)
        assert BufferProcess.content(buffer) == base <> "X\n"
      end
    end

    # Addendum 4 F1: a deletion slides only to a place both its ends are cuts the editor can make, never across bytes of
    # a code point or into a grapheme cluster.
    test "SL1 to SL3: a deletion next to Minga's multi-byte text slides only by whole characters" do
      for {original, at, minga, delete, after_delete, expected} <- [
            {"öX\n", 2, "é", 2, "éX\n", "X\n"},
            {"中X\n", 3, "丁", 3, "丁X\n", "X\n"},
            # The same cluster twice: your deletion takes Minga's copy, whole, so the reject leaves yours.
            {"e\u0301X\n", 3, "e\u0301", 3, "e\u0301X\n", "e\u0301X\n"}
          ] do
        buffer = start(original)
        replace_at(buffer, {0, at}, 0, minga, step("t", "s"))
        replace_at(buffer, {0, 0}, delete, "")
        assert BufferProcess.content(buffer) == after_delete
        assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
        assert BufferProcess.content(buffer) == expected
      end
    end

    test "SL3 mirror: Minga deletes the character before your é; the reject brings it back and your undo works" do
      buffer = start("öX\n")
      replace_at(buffer, {0, 2}, 0, "é")
      replace_at(buffer, {0, 0}, 2, "", step("t", "s"))
      assert BufferProcess.content(buffer) == "éX\n"
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "öéX\n"
      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "öX\n"
    end

    test "SL4: the task stays revertable after your deletion leaves your undo stack" do
      buffer = start("öX\nzz\n")
      replace_at(buffer, {0, 2}, 0, "é", step("t", "s"))
      replace_at(buffer, {0, 0}, 2, "")
      for _ <- 1..1001, do: replace_at(buffer, {1, 0}, 0, "y")
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) |> String.split("\n") |> hd() == "X"
      replace_at(buffer, {1, 0}, 0, "q", step("t2", "s"))
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert :empty = BufferProcess.undo_agent_session(buffer)
    end

    # Round 5 R1, SL1 to SL3: a deletion beside an identical byte takes the other author's copy, in any change list.
    test "your :s over Minga's duplicate parens takes Minga's copies, so SPC a u leaves your text" do
      buffer = start("f(a)\nf(a)\n")
      replace_at(buffer, {0, 1}, 0, "(", step("t", "c1"))
      replace_at(buffer, {1, 1}, 0, "(", step("t", "c1"))

      :ok =
        BufferProcess.replace_content(
          buffer,
          String.replace(BufferProcess.content(buffer), "((", "(")
        )

      assert {:ok, _steps} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "f(a)\nf(a)\n"
    end

    test "your change elsewhere on the line does not stop the deletion taking Minga's paren" do
      buffer = start("f(a) x\n")
      replace_at(buffer, {0, 1}, 0, "(", step("t", "c1"))
      :ok = BufferProcess.replace_content(buffer, "f(a) y\n")
      assert {:ok, _steps} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "f(a) y\n"
    end

    test "Minga's change deleting one of two parens takes yours, so your undo waits and the reject is exact" do
      buffer = start("f(a) x\n")
      replace_at(buffer, {0, 1}, 0, "(")
      minga_replace(buffer, "f(a) y\n", step("t", "c1"))
      assert {:blocked, _reason} = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "f(a) y\n"
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "f((a) x\n"
      assert :ok = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "f(a) x\n"
    end

    # Round 5 R1, AN2: the edit tool adds a one-byte suffix on every line; your :s replaces the suffixed word.
    test "SPC a u after your :s over Minga's one-byte insertions changes nothing" do
      original = Enum.map_join(1..8, fn n -> "v#{n} = f(beta) # #{n}\n" end)
      buffer = start(original)
      minga_replace(buffer, String.replace(original, "beta", "beta7"), step("t", "c1"))

      :ok =
        BufferProcess.replace_content(
          buffer,
          String.replace(BufferProcess.content(buffer), "beta7", "BETA")
        )

      before = BufferProcess.content(buffer)
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == before
    end

    # Round 5, R1's documented limit: one line past the word budget has no alignment inside it, so Minga's edit of its
    # ends takes the whole line, your word included. Your undo is then blocked, and the reject is exact.
    test "a line past the word budget is one change: your word in it goes to Minga, and the reject brings it back" do
      words = Enum.map_join(1..700, " ", &"word#{&1}")
      buffer = start("# Title\n" <> words <> "\n")
      middle = byte_size(Enum.map_join(1..350, " ", &"word#{&1}"))
      replace_at(buffer, {1, middle}, 0, " MINE")
      mine = BufferProcess.content(buffer)
      identity = {:buffer, "/long"}
      expected = Minga.Buffer.FileMutation.revision(mine, BufferProcess.version(buffer), identity)
      pairs = [{"word1 ", "WORD1 "}, {"word700\n", "WORD700\n"}]

      assert {:ok, _receipt} =
               BufferProcess.conditional_mutate(
                 buffer,
                 expected,
                 {:edit, pairs},
                 identity,
                 step("t", "c1")
               )

      assert BufferProcess.author_at(buffer, {1, middle + 2}) == {:minga, "t"}
      assert {:blocked, _reason} = BufferProcess.undo(buffer)
      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == mine
    end

    # Round 3's L1: a long prose line where Minga edits the first and last words around a word of yours.
    test "your word in a long line keeps its author and its undo when Minga edits the line's ends" do
      for count <- [60, 100] do
        words = Enum.map_join(1..count, " ", &"word#{&1}")
        buffer = start("# Title\n" <> words <> "\n")
        middle = byte_size(Enum.map_join(1..div(count, 2), " ", &"word#{&1}"))
        replace_at(buffer, {1, middle}, 0, " MINE")
        content = BufferProcess.content(buffer)
        identity = {:buffer, "/long"}

        expected =
          Minga.Buffer.FileMutation.revision(content, BufferProcess.version(buffer), identity)

        pairs = [{"word1 ", "WORD1 "}, {"word#{count}\n", "WORD#{count}\n"}]

        assert {:ok, _receipt} =
                 BufferProcess.conditional_mutate(
                   buffer,
                   expected,
                   {:edit, pairs},
                   identity,
                   step("t", "c1")
                 )

        assert BufferProcess.author_at(buffer, {1, middle + 2}) == :you
        assert :ok = BufferProcess.undo(buffer)
        refute BufferProcess.content(buffer) =~ "MINE"
      end
    end

    test "retyping one of two words a Minga step changed on a line rejects to the other word's original" do
      buffer = start("call(foo, bar, baz)\nnext\n")
      content = BufferProcess.content(buffer)
      identity = {:buffer, "/words"}

      expected =
        Minga.Buffer.FileMutation.revision(content, BufferProcess.version(buffer), identity)

      assert {:ok, _receipt} =
               BufferProcess.conditional_mutate(
                 buffer,
                 expected,
                 {:edit, [{"foo", "FOO"}, {"baz", "BAZ"}]},
                 identity,
                 step("t", "call-1")
               )

      replace_at(buffer, {0, 15}, 3, "qux")
      assert BufferProcess.content(buffer) == "call(FOO, bar, qux)\nnext\n"
      assert BufferProcess.author_at(buffer, {0, 9}) == :unattributed

      assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
      assert BufferProcess.content(buffer) == "call(foo, bar, qux)\nnext\n"
    end

    test "adjacent replacements reject the same whether one step or two made them" do
      for {position, length, text, expected} <- [
            {{0, 1}, 1, "", "a"},
            {{0, 1}, 1, "z", "az"},
            {{0, 0}, 1, "", "b"},
            {{0, 0}, 1, "z", "zb"}
          ] do
        results =
          for steps <- [["s", "s"], ["s1", "s2"]] do
            buffer = start("ab")
            replace_at(buffer, {0, 0}, 1, "A", step("t", Enum.at(steps, 0)))
            replace_at(buffer, {0, 1}, 1, "B", step("t", Enum.at(steps, 1)))
            replace_at(buffer, position, length, text)
            assert {:ok, _steps} = BufferProcess.undo_agent_session(buffer)
            BufferProcess.content(buffer)
          end

        assert results == [expected, expected]
      end
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

    test "reindenting more lines than any cap, by :s or by shift_lines, leaves Minga's text Minga's" do
      lines = 4_200
      base = Enum.map_join(1..lines, fn i -> "x#{i} = #{i}\n" end)

      for reindent <- [:replace_content, :shift_lines] do
        buffer = start(base)
        replace_at(buffer, {2_100, 0}, 1, "M", step("t", "s"))

        case reindent do
          :replace_content ->
            indented =
              buffer
              |> BufferProcess.content()
              |> String.split("\n", trim: true)
              |> Enum.map_join(&("  " <> &1 <> "\n"))

            assert :ok = BufferProcess.replace_content(buffer, indented)

          :shift_lines ->
            assert :ok = BufferProcess.shift_lines(buffer, 0, lines - 1, {:indent, "  "})
        end

        assert BufferProcess.author_at(buffer, {2_100, 2}) == {:minga, "t"}
        assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)

        assert buffer |> BufferProcess.content() |> String.split("\n") |> Enum.at(2_100) ==
                 "  x2101 = 2101"
      end
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

    # A reload makes your edit permanent, so no undo reaches it: the press must not tell you to press u.
    test "a task held by an edit a reload made permanent says it cannot be reverted exactly", %{
      tmp_dir: dir
    } do
      registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      path = Path.join(dir, "file.txt")
      File.write!(path, "l1\nfoo bar\n")

      buffer =
        start_supervised!({BufferProcess, file_path: path, events_registry: registry},
          id: make_ref()
        )

      replace_at(buffer, {1, 0}, 7, "FOO BAR", step("t", "s"))
      replace_at(buffer, {1, 1}, 2, "")
      assert :ok = BufferProcess.save(buffer)
      assert :ok = BufferProcess.reload(buffer)
      :ok = Minga.Events.subscribe(:log_message, registry)

      assert {:blocked, {:overlaps, :you}} = BufferProcess.undo_agent_session(buffer)

      assert_receive {:minga_event, :log_message,
                      %{text: "Reverted 0 steps of Minga task t in " <> rest}}

      assert rest =~ "an edit near line 2 that is no longer in your undo history holds them"
      refute rest =~ "(u)"
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

    # The buffer process never crashes on broken history bookkeeping: undo, redo, SPC a u and a compaction slice reset
    # the history and refuse, and the text stays.
    test "an undo, redo, SPC a u or compaction slice that raises resets the history instead of crashing the buffer" do
      registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      :ok = Minga.Events.subscribe(:log_message, registry)

      buffer =
        start_supervised!({BufferProcess, content: "hello", events_registry: registry},
          id: make_ref()
        )

      replace_at(buffer, {0, 0}, 1, "J")

      :sys.replace_state(
        buffer,
        &%{&1 | undo_history: %{&1.undo_history | undo_entries: [:broken]}}
      )

      assert {:error, :history_reset} = BufferProcess.undo(buffer)
      assert BufferProcess.content(buffer) == "Jello"

      assert_receive {:minga_event, :log_message,
                      %{level: :error, text: "Undo history and authorship" <> _}}

      :sys.replace_state(
        buffer,
        &%{&1 | undo_history: %{&1.undo_history | redo_entries: [:broken]}}
      )

      assert {:error, :history_reset} = BufferProcess.redo(buffer)

      assert_receive {:minga_event, :log_message,
                      %{level: :error, text: "Undo history and authorship" <> _}}

      :sys.replace_state(buffer, fn state ->
        history = state.undo_history

        broken = %{
          history
          | groups_by_task: %{{:minga, "t"} => MapSet.new([999])},
            pending_groups: %{999 => {:minga, "t", "s"}},
            task_ticks: %{{:minga, "t"} => 1}
        }

        %{state | undo_history: broken}
      end)

      assert {:error, :history_reset} = BufferProcess.undo_agent_session(buffer)

      assert_receive {:minga_event, :log_message,
                      %{level: :error, text: "Undo history and authorship" <> _}}

      :sys.replace_state(buffer, fn state ->
        history = state.undo_history
        broken = %{history.provenance | drafts: :broken}
        %{state | undo_history: %{history | provenance: broken, compaction_wanted: true}}
      end)

      send(buffer, :compact_history)
      assert BufferProcess.content(buffer) == "Jello"

      assert_receive {:minga_event, :log_message,
                      %{level: :error, text: "Undo history and authorship" <> _}}

      assert :ok = BufferProcess.insert_text(buffer, "x")
      assert BufferProcess.content(buffer) == "Jxello"
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
