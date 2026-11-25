defmodule Minga.Buffer.UndoHistoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.UndoPatch
  alias Minga.Test.UndoUnitModel, as: UnitModel

  # Recording calls take a monotonic timestamp, so tests drive the coalescing clock instead of sleeping.
  @t0 1_000
  @window UndoHistory.coalesce_ms()

  @step_one {:minga, "task-1", "call-1"}
  @step_two {:minga, "task-1", "call-2"}
  @other_task {:minga, "task-2", "call-9"}

  describe "your groups" do
    test "same-source edits inside the window coalesce, at signed monotonic times" do
      for {first, second} <- [{@t0, @t0 + @window - 1}, {-@t0, -@t0}] do
        world =
          world("") |> edit(:user, 0, 0, "a", at: first) |> edit(:user, 1, 0, "b", at: second)

        assert UndoHistory.undo_count(world.history) == 1
        assert {:ok, world, %{version: 0}} = step(world, :undo)
        assert text(world) == ""
      end
    end

    test "an edit at or after the window boundary starts a new group" do
      world = world("") |> edit(:user, 0, 0, "a") |> edit(:user, 1, 0, "b", at: @t0 + @window)
      assert UndoHistory.undo_count(world.history) == 2
    end

    test "the window is measured from the last recorded edit, not the first" do
      world =
        world("")
        |> edit(:user, 0, 0, "a")
        |> edit(:user, 1, 0, "b", at: @t0 + @window - 1)
        |> edit(:user, 2, 0, "c", at: @t0 + 2 * @window - 2)

      assert UndoHistory.undo_count(world.history) == 1
    end

    test "break_coalescing, a different source, or a Minga edit in between starts a new group" do
      broken = edit(world(""), :user, 0, 0, "a")
      broken = %{broken | history: UndoHistory.break_coalescing(broken.history)}
      assert UndoHistory.undo_count(edit(broken, :user, 1, 0, "b").history) == 2

      sources = world("") |> edit(:user, 0, 0, "a") |> edit(:lsp, 1, 0, "b", at: @t0 + 1)
      assert UndoHistory.undo_count(sources.history) == 2
      assert UndoHistory.last_undo_source(sources.history) == :lsp

      interleaved =
        world("")
        |> edit(:user, 0, 0, "a")
        |> edit(@step_one, 1, 0, "M", at: @t0 + 1)
        |> edit(:user, 2, 0, "b", at: @t0 + 2)

      assert UndoHistory.undo_count(interleaved.history) == 2
    end

    test "a forced group still anchors the coalescing window for following edits" do
      world =
        world("") |> edit(:user, 0, 0, "a", force: true) |> edit(:user, 1, 0, "b", at: @t0 + 1)

      assert UndoHistory.undo_count(world.history) == 1
    end

    test "a batch is one group" do
      document = Document.new("abc")

      patches = [
        UndoPatch.replacement(0, "a", "A", {0, 0}),
        UndoPatch.replacement(2, "c", "C", {0, 0})
      ]

      history = UndoHistory.record_edit_batch(UndoHistory.new(document), 0, patches, :lsp, @t0)

      assert UndoHistory.undo_count(history) == 1
      assert {:ok, restore, _history} = UndoHistory.undo(history, 1, Document.new("AbC"))
      assert Document.content(restore.document) == "abc"
    end

    test "only your last 1000 groups stay undoable, and older text keeps its author" do
      world =
        Enum.reduce(1..1100, world(""), fn n, world ->
          edit(world, :user, 0, 0, "x", at: @t0 + n * @window)
        end)

      assert UndoHistory.undo_count(world.history) == 1000
      assert author_at(world, 1099) == :you

      assert world.history |> UndoHistory.provenance() |> Provenance.runs() |> Enum.count() <=
               1001
    end

    test "your new edit replaces your redo stack" do
      world = world("") |> edit(:user, 0, 0, "a") |> undo!()
      assert UndoHistory.redo_count(world.history) == 1

      world = edit(world, :user, 0, 0, "b")
      assert UndoHistory.redo_count(world.history) == 0
      assert text(world) == "b"
    end
  end

  describe "undo/3 and redo/3" do
    test "undo and redo with nothing in between restore the exact versions" do
      world = edit(world("before"), :lsp, 0, 6, "after")

      assert {:ok, world, restore} = step(world, :undo)
      assert {restore.version, restore.source, text(world)} == {0, :lsp, "before"}
      assert UndoHistory.last_redo_source(world.history) == :lsp

      assert {:ok, world, restore} = step(world, :redo)
      assert {restore.version, text(world)} == {1, "after"}
      assert UndoHistory.undo_count(world.history) == 1
      assert UndoHistory.redo_count(world.history) == 0
    end

    test "empty history cannot undo or redo" do
      world = world("current")
      assert step(world, :undo) == :empty
      assert step(world, :redo) == :empty
    end

    test "your u never undoes Minga's edit, even when it is the newest change" do
      world = world("one\n") |> edit(:user, 4, 0, "two\n") |> edit(@step_one, 8, 0, "three\n")

      assert UndoHistory.undo_count(world.history) == 1
      assert {:ok, world, restore} = step(world, :undo)
      assert text(world) == "one\nthree\n"
      assert restore.version == :advance
      assert step(world, :undo) == :empty
    end

    test "Minga's edit above your text does not break your undo or redo" do
      world =
        world("line one\nline two\n")
        |> edit(:user, 9, 4, "LINE")
        |> edit(@step_one, 0, 0, "minga\n")

      world = undo!(world)
      assert text(world) == "minga\nline one\nline two\n"

      world = redo!(world)
      assert text(world) == "minga\nline one\nLINE two\n"
    end

    test "interleaved edits: each undo or reject touches only its own author's text" do
      world = world(Enum.map_join(1..14, fn n -> "line #{n}\n" end))
      world = edit(world, @step_one, offset_of(world, "line 10\n"), 7, "LINE 10")
      world = edit(world, :user, offset_of(world, "line 12\n"), 7, "mine 12")

      undone = undo!(world)
      assert text(undone) =~ "LINE 10\n"
      assert text(undone) =~ "line 12\n"

      rejected = reject_newest_task(world)
      assert text(rejected) =~ "line 10\n"
      assert text(rejected) =~ "mine 12\n"
    end

    test "text you type inside a Minga change is yours to undo" do
      world = world("") |> edit(@step_one, 0, 0, "minga") |> edit(:user, 2, 0, "me")

      assert author_at(world, 2) == :you
      assert author_at(world, 0) == {:minga, "task-1"}
      assert text(undo!(world)) == "minga"
    end

    test "undo that would cross text Minga later rewrote is blocked and changes nothing" do
      world = world("") |> edit(:user, 0, 0, "hello world") |> edit(@step_two, 6, 5, "there")

      assert step(world, :undo) == {:blocked, {:overlaps, @step_two}}
      assert UndoHistory.undo_count(world.history) == 1
      assert UndoHistory.redo_count(world.history) == 0

      world = reject_newest_task(world)
      assert text(world) == "hello world"
      assert text(undo!(world)) == ""
    end

    test "an earlier Minga step inside text you later deleted does not block your undo" do
      world =
        world("aaa bbb ccc\nzzz\n")
        |> edit(@step_one, 4, 3, "BBB")
        |> edit(:user, 0, 12, "")

      assert text(world) == "zzz\n"
      assert text(undo!(world)) == "aaa BBB ccc\nzzz\n"
    end

    test "redo that would cross text Minga rewrote since the undo is blocked" do
      world = world("abc") |> edit(:user, 1, 1, "") |> undo!() |> edit(@step_one, 0, 3, "xyz")

      assert step(world, :redo) == {:blocked, {:overlaps, @step_one}}
    end

    test "Minga's edits never clear your redo stack" do
      world =
        world("") |> edit(:user, 0, 0, "mine") |> undo!() |> edit(@step_one, 0, 0, "minga")

      assert UndoHistory.redo_count(world.history) == 1
      # The undone text sits where it was; Minga's insertion went after it.
      assert text(redo!(world)) == "mineminga"
    end
  end

  describe "Minga's history" do
    test "each step of a task is its own group and reports the regions it touched" do
      world =
        world("aaa\nbbb\nccc\n")
        |> edit(@step_one, 0, 3, "AAA")
        |> edit(@step_one, 8, 3, "CCC")
        |> edit(@step_two, 4, 0, "new\n")
        |> edit(@other_task, 0, 0, "x")

      assert UndoHistory.minga_changes(world.history, "task-1") == [
               {@step_one, [{1, 4}, {13, 16}]},
               {@step_two, [{5, 9}]}
             ]

      assert UndoHistory.undo_count(world.history) == 0
    end

    test "undo_agent_session reverts every step of the newest task and keeps other tasks" do
      world =
        world("base\n")
        |> edit(:user, 0, 0, "mine ")
        |> edit(@step_one, 10, 0, "one\n")
        |> edit(@other_task, 0, 0, "other ")
        |> edit(@step_two, 20, 0, "two\n")

      assert {:ok, restore, history, 2, _tasks, []} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert restore.version == :advance
      assert Document.content(restore.document) == "other mine base\n"
      assert UndoHistory.minga_changes(history, "task-1") == []
      assert UndoHistory.undo_count(history) == 1
    end

    test "rejecting a task right after its steps returns to the version before them" do
      world = world("one\n") |> edit(:user, 0, 0, "x") |> edit(@step_one, 4, 0, "two\n")
      world = edit(world, @step_two, 0, 0, "zero\n")

      rejected = reject_newest_task(world)
      assert {text(rejected), rejected.version} == {"xone\n", 1}
      assert {:ok, undone, %{version: 0}} = step(rejected, :undo)
      assert text(undone) == "one\n"
    end

    test "rejecting a task after other changes takes a new version" do
      world = world("one\n") |> edit(@step_one, 4, 0, "two\n") |> edit(:user, 0, 0, "x")

      {:ok, restore, _history, 1, _tasks, []} =
        UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert restore.version == :advance
    end

    test "agent edits without a task are Minga's untasked text, not yours, and revert together" do
      world = world("") |> edit(:agent, 0, 0, "agent") |> edit(:agent, 5, 0, " more")

      assert author_at(world, 0) == {:minga, :untasked}
      assert step(world, :undo) == :empty
      assert text(reject_newest_task(world)) == ""
    end

    test "untasked agent edits keep their last 1000 groups, and older ones stay as permanent text" do
      world = edit(world(""), @step_one, 0, 0, "task\n")

      world =
        Enum.reduce(1..1100, world, fn n, world ->
          edit(world, :agent, byte_size(text(world)), 0, "x", at: @t0 + n)
        end)

      provenance = UndoHistory.provenance(world.history)
      assert provenance |> Provenance.runs() |> Enum.count() <= 1002
      assert Provenance.author_at(provenance, 5) == {:minga, :untasked}

      {:ok, restore, history, 1000, [{:minga, :untasked}], []} =
        UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert restore.version == :advance
      assert Document.content(restore.document) == "task\n" <> String.duplicate("x", 100)
      assert [{@step_one, [{0, 5}]}] = UndoHistory.minga_changes(history, "task-1")

      assert history |> UndoHistory.provenance() |> Provenance.author_at(104) ==
               {:minga, :untasked}

      # The tasked step is never evicted and still reverts on its own.
      assert {:ok, _restore, _history, 1, [{:minga, "task-1"}], []} =
               UndoHistory.undo_agent_session(history, world.version + 1, restore.document)
    end

    test "evicting an agent edit that rewrote your text removes your blocked steps instead of unblocking them" do
      world =
        world("foo\n") |> edit(:user, 0, 3, "bar") |> edit(:user, 3, 0, "!", at: @t0 + @window)

      world = world |> undo!() |> edit(:agent, 0, 3, "baz")
      assert step(world, :undo) == {:blocked, {:overlaps, {:untasked, 1}}}

      world =
        Enum.reduce(1..1000, world, fn n, world ->
          edit(world, :agent, byte_size(text(world)), 0, "x", at: @t0 + n)
        end)

      assert text(world) == "baz\n" <> String.duplicate("x", 1000)
      assert step(world, :undo) == :empty

      # Your undone "!" was not blocked, so it stays redoable.
      assert text(redo!(world)) == "baz!\n" <> String.duplicate("x", 1000)
    end

    test "evicting an agent edit that rewrote your undone text removes your blocked redo" do
      world = world("foo\n") |> edit(:user, 0, 3, "bar") |> undo!() |> edit(:agent, 0, 3, "qux")
      assert step(world, :redo) == {:blocked, {:overlaps, {:untasked, 1}}}

      world =
        Enum.reduce(1..1000, world, fn n, world ->
          edit(world, :agent, byte_size(text(world)), 0, "x", at: @t0 + n)
        end)

      assert step(world, :redo) == :empty
      assert text(world) == "qux\n" <> String.duplicate("x", 1000)
    end

    test "a Minga step outlives more than 1000 of your groups" do
      world = edit(world("base\n"), @step_one, 0, 0, "minga ")

      world =
        Enum.reduce(1..1100, world, fn n, world ->
          edit(world, :user, byte_size(text(world)), 0, "x", at: @t0 + n * @window)
        end)

      assert UndoHistory.undo_count(world.history) == 1000
      assert [{@step_one, [{0, 6}]}] = UndoHistory.minga_changes(world.history, "task-1")
      assert text(reject_newest_task(world)) == "base\n" <> String.duplicate("x", 1100)
    end

    test "a task is blocked by a newer task that rewrote its text, so the newer one reverts first" do
      world =
        world("axb\nq")
        |> edit(@step_one, 1, 1, "y")
        |> edit(@other_task, 1, 1, "w")
        |> edit(@step_two, 4, 1, "Q")

      assert UndoHistory.reject_task(world.history, {:minga, "task-1"}, world.version, world.doc) ==
               {:blocked, {:overlaps, @other_task}}

      # task-1 edited last, but task-2 blocks it, so the next revert is task-2's.
      assert UndoHistory.next_reject(world.history) == [{:minga, "task-2"}]
      world = reject_newest_task(world)
      assert text(world) == "ayb\nQ"
      assert UndoHistory.next_reject(world.history) == [{:minga, "task-1"}]
      world = reject_newest_task(world)
      assert text(world) == "axb\nq"
      assert UndoHistory.next_reject(world.history) == nil
    end

    test "8000 Minga steps rewriting one word stay fast though their tombstones pile up there" do
      {micros, world} =
        :timer.tc(fn ->
          Enum.reduce(1..8_000, world("let x = foo;\n"), fn n, world ->
            old = if n == 1, do: 3, else: byte_size("w#{n - 1}")
            edit(world, {:minga, "task-1", "s#{n}"}, 8, old, "w#{n}")
          end)
        end)

      assert text(world) == "let x = w8000;\n"
      assert micros < 5_000_000
    end

    test "8000 of your retypes over a word Minga replaced stay fast" do
      world = edit(world("let x = foo;\n"), @step_one, 8, 3, "bar")

      {micros, world} =
        :timer.tc(fn ->
          Enum.reduce(1..8_000, world, fn n, world ->
            old = if n == 1, do: 3, else: byte_size("v#{n - 1}")
            edit(world, :user, 8, old, "v#{n}", at: @t0 + n * @window)
          end)
        end)

      assert text(world) == "let x = v8000;\n"
      assert micros < 5_000_000
    end

    test "reload keeps Minga's steps and records the disk change as unattributed" do
      world = world("one\ntwo\n") |> edit(:user, 0, 0, "my ") |> edit(@step_one, 7, 3, "TWO")
      disk = Document.new("my one\nTWO\nthree\n")
      history = UndoHistory.reload(world.history, world.doc, disk)

      assert UndoHistory.undo_count(history) == 0
      assert [{@step_one, [{7, 10}]}] = UndoHistory.minga_changes(history, "task-1")
      provenance = UndoHistory.provenance(history)
      assert Provenance.author_at(provenance, 0) == :you
      assert Provenance.author_at(provenance, 7) == {:minga, "task-1"}
      assert Provenance.author_at(provenance, 11) == :unattributed
    end

    # N6 at both granularities: a word-precise recording keeps the reject exact; a coarse one refuses it.
    test "retyping one of two words Minga changed rejects exactly when recorded per word" do
      world =
        world("foo, bar, baz\n") |> edit(@step_one, 0, 3, "FOO") |> edit(@step_one, 10, 3, "BAZ")

      world = edit(world, :user, 10, 3, "qux")

      assert {:ok, restore, _history, 1} =
               UndoHistory.reject_task(
                 world.history,
                 {:minga, "task-1"},
                 world.version,
                 world.doc
               )

      assert Document.content(restore.document) == "foo, bar, qux\n"
    end

    test "retyping one of two words inside one coarse Minga change refuses the reject until you undo it" do
      world =
        world("foo, bar, baz\n", recording: :coarse) |> edit(@step_one, 0, 13, "FOO, bar, BAZ")

      world = edit(world, :user, 10, 3, "qux")

      assert UndoHistory.reject_task(world.history, {:minga, "task-1"}, world.version, world.doc) ==
               {:blocked, {:overlaps, :you}}

      assert {:blocked, {:overlaps, :you}, {:minga, "task-1"}, 10} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      world = undo!(world)

      assert {:ok, restore, _history, 1, [{:minga, "task-1"}], []} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert Document.content(restore.document) == "foo, bar, baz\n"
    end

    test "an edit of yours inside Minga's change that Minga then rewrote whole is dropped with the task" do
      world = world("xay\n") |> edit(@step_one, 1, 1, "bcd") |> edit(:user, 2, 1, "Q")
      world = edit(world, @step_two, 2, 1, "Z")
      assert text(world) == "xbZdy\n"
      assert {:blocked, {:overlaps, @step_two}} = step(world, :undo)

      assert {:ok, restore, history, 2, [{:minga, "task-1"}], [1]} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert Document.content(restore.document) == "xay\n"
      assert UndoHistory.undo_count(history) == 0
    end

    test "an edit of yours inside Minga's change with text still visible holds the task" do
      world = world("xay\n") |> edit(@step_one, 1, 1, "bcd") |> edit(:user, 2, 1, "QR")
      world = edit(world, @step_two, 3, 1, "Z")
      assert text(world) == "xbQZdy\n"
      assert {:blocked, {:overlaps, @step_two}} = step(world, :undo)

      assert {:blocked, {:overlaps, :you}, {:minga, "task-1"}, 2} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert UndoHistory.next_reject(world.history) == nil
    end

    # Review findings on round 4, as regressions.
    test "compaction never lets through a reject a third group's deletion between the merged steps blocks" do
      commands = [
        {:user, 0, 3, "a", 0},
        {:minga, 305, 2, "\naca", 0},
        {:minga, 822, 2, "cb", 1},
        {:minga, 643, 1, "\nc", 2},
        {:minga, 995, 3, "", 2},
        {:user, 990, 3, "abbc", 2},
        {:minga, 651, 2, "a", 2},
        {:minga, 74, 1, "", 1},
        {:minga, 475, 1, "", 0},
        {:agent, 618, 1, "ac", 2}
      ]

      plain = Enum.reduce(commands, world("abc\ndef\n", run_budget: 20), &run/2)
      compacted = plain |> want_compaction() |> compact_fully(19)
      assert reject_text(compacted, {:minga, "task-0"}) == reject_text(plain, {:minga, "task-0"})
    end

    test "a permanent mark holds the task it marks without crashing SPC a u" do
      world = world("foo bar\n", recording: :coarse) |> edit(@step_one, 0, 7, "FOO BAR")
      world = edit(world, :agent, 0, 2, "q")

      world =
        Enum.reduce(1..1000, world, fn n, world ->
          edit(world, :agent, byte_size(text(world)), 0, "x", at: @t0 + n)
        end)

      assert {:ok, _restore, _history, _count, [{:minga, :untasked}], []} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      world = reject_newest_task(world)

      assert {:blocked, {:overlaps, :you}, {:minga, "task-1"}, _offset} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)
    end

    test "SPC a u never brings back text you deleted outside the task's change" do
      world = world("aaa bbb\nccc\n") |> edit(@step_one, 0, 3, "XYZ")

      patches = [
        UndoPatch.replacement(8, "ccc", "", {0, 0}),
        UndoPatch.replacement(1, "Y", "Q", {0, 0})
      ]

      history = UndoHistory.record_edit_batch(world.history, world.version, patches, :lsp, @t0)
      {:ok, doc} = Document.splice_byte_range(world.doc, 1, 1, "Q", {0, 0})
      {:ok, doc} = Document.splice_byte_range(doc, 8, 3, "", {0, 0})
      world = %{world | history: history, doc: doc, version: world.version + 1}
      world = edit(world, @step_two, 1, 1, "W")
      assert text(world) == "XWZ bbb\n\n"

      assert {:blocked, {:overlaps, :you}, {:minga, "task-1"}, _offset} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)
    end

    test "a held task names the line of the permanent edit that holds it" do
      world = world("l1\nl2\nfoo bar\n", recording: :coarse) |> edit(@step_one, 6, 7, "FOO BAR")
      world = edit(world, :user, 7, 2, "")
      history = UndoHistory.reload(world.history, world.doc, world.doc)

      assert {:blocked, {:overlaps, :you}, {:minga, "task-1"}, offset} =
               UndoHistory.undo_agent_session(history, world.version, world.doc)

      assert offset >= 6
    end

    # Round 5 R1: AN1, your :s over Minga's one-byte insertions, and the slider cases.
    test "your edit over Minga's short insertions leaves no Minga byte behind to delete elsewhere" do
      lines =
        for n <- 1..10, do: "    value_#{n} = compute(alpha_#{n}, beta, gamma) # note #{n}\n"

      c0 = Enum.join(lines)
      c1 = String.replace(c0, "beta", "beta7")
      c2 = String.replace(c1, "beta7", "BETA")
      history = UndoHistory.new(Document.new(c0))

      history =
        UndoHistory.record_edit_batch(
          history,
          1,
          UndoPatch.changes(Document.new(c0), Document.new(c1)),
          @step_one,
          @t0
        )

      history =
        UndoHistory.record_edit_batch(
          history,
          2,
          UndoPatch.changes(Document.new(c1), Document.new(c2)),
          :user,
          @t0
        )

      refute history
             |> UndoHistory.provenance()
             |> Provenance.spans(0, byte_size(c2))
             |> Enum.any?(&match?({_f, _t, {:minga, _}, _k}, &1))

      assert {:ok, restore, _history, 1} =
               UndoHistory.reject_task(history, {:minga, "task-1"}, 3, Document.new(c2))

      assert Document.content(restore.document) == c2
      assert {:ok, restore, _history} = UndoHistory.undo(history, 3, Document.new(c2))
      assert Document.content(restore.document) == c1
    end

    for {name, minga_at} <- [{"before", 1}, {"after", 2}] do
      test "deleting one of two parens takes Minga's copy when Minga's is #{name} the base one" do
        world = world("f(a)\n") |> edit(@step_one, unquote(minga_at), 0, "(")
        assert text(world) == "f((a)\n"
        world = edit(world, :user, 1, 1, "")
        assert text(world) == "f(a)\n"

        case UndoHistory.reject_task(world.history, {:minga, "task-1"}, world.version, world.doc) do
          {:ok, restore, _history, _count} ->
            assert Document.content(restore.document) == "f(a)\n"

          {:blocked, _reason} ->
            :ok
        end

        assert {:ok, world, _restore} = step(world, :undo)
        assert text(world) == "f((a)\n"
      end
    end

    test "Minga deleting one of two parens takes yours, so your undo is blocked and the reject is exact" do
      world = world("f(a)\n") |> edit(:user, 1, 0, "(")
      world = edit(world, @step_one, 2, 1, "")
      assert text(world) == "f(a)\n"
      assert {:blocked, {:overlaps, @step_one}} = step(world, :undo)

      assert {:ok, restore, _history, 1} =
               UndoHistory.reject_task(
                 world.history,
                 {:minga, "task-1"},
                 world.version,
                 world.doc
               )

      assert Document.content(restore.document) == "f((a)\n"
    end

    test "undo_agent_session is :empty without Minga steps" do
      assert UndoHistory.undo_agent_session(UndoHistory.new(), 0, Document.new("")) == :empty
    end
  end

  describe "record_untracked/2 and reset/2" do
    test "untracked text is unattributed and breaks exact version restores" do
      world = edit(world(""), :user, 0, 0, "typed")
      history = UndoHistory.record_untracked(world.history, [{5, "", " log"}])
      {:ok, doc} = Document.splice_byte_range(world.doc, 5, 0, " log", {0, 0})
      world = %{world | history: history, doc: doc, version: world.version + 1}

      assert author_at(world, 6) == :unattributed
      assert {:ok, world, %{version: :advance}} = step(world, :undo)
      assert text(world) == " log"
    end

    test "reset forgets history and authorship" do
      world = world("") |> edit(:user, 0, 0, "a") |> edit(@step_one, 1, 0, "b")
      history = UndoHistory.reset(world.history, Document.new("fresh"))

      assert UndoHistory.undo_count(history) == 0
      assert UndoHistory.minga_changes(history, "task-1") == []
      assert history |> UndoHistory.provenance() |> Provenance.author_at(0) == :unattributed
    end
  end

  describe "interleaved histories" do
    property "your u never changes text Minga wrote, and redo only removes Minga text you deleted" do
      check all(commands <- StreamData.list_of(command(), max_length: 40), max_runs: runs(200)) do
        Enum.reduce(commands, world("abc\ndef\n"), fn command, world ->
          before = live_minga_runs(world)
          world = run(command, world)
          removed = MapSet.difference(before, live_minga_runs(world))

          case elem(command, 0) do
            :undo -> assert removed == MapSet.new()
            :redo -> assert Enum.all?(removed, &deleted_by_you?(world, &1))
            _edit -> :ok
          end

          assert Provenance.size(UndoHistory.provenance(world.history)) == byte_size(text(world))
          world
        end)
      end
    end

    property "SPC a u reverts what the model accepts, keeps your visible text, and with undo restores the original" do
      check all(commands <- StreamData.list_of(command(), max_length: 40), max_runs: runs(200)) do
        world = Enum.reduce(commands, world("abc\ndef\n"), &run/2)

        case unwind(world) do
          {:done, world} -> assert text(world) == "abc\ndef\n"
          {:stuck, world} -> assert UnitModel.revertable_units(world.history) == MapSet.new()
        end
      end

      IO.puts(
        "\n[units] multi-node units reverted: #{Process.get(:multi_units, 0)}, stuck runs: #{Process.get(:stuck, 0)}"
      )
    end

    property "with coarse recording, rejecting any task is exact or refused, and SPC a u matches the model" do
      check all(
              commands <- StreamData.list_of(coarse_command(), max_length: 30),
              max_runs: runs(300)
            ) do
        world = Enum.reduce(commands, world("ab cd ef\ngh ij\n", recording: :coarse), &run/2)
        assert_rejects_exact_or_refused(world)
        {_done_or_stuck, world} = reject_all(world)
        assert UnitModel.revertable_units(world.history) == MapSet.new()
      end
    end

    # Past the 512-word cap a long line is recorded as one change even when precise.
    property "a Minga rewrite of a line longer than the word cap, edited inside by you, rejects exactly or is refused" do
      words = for n <- 1..600, do: "w#{n}"

      check all(
              rewritten <-
                StreamData.list_of(StreamData.integer(0..599), min_length: 2, max_length: 6),
              your_word <- StreamData.integer(0..599),
              your_text <- StreamData.string(?x..?z, min_length: 1, max_length: 3),
              partial <- StreamData.boolean(),
              max_runs: runs(25)
            ) do
        line = Enum.join(words, " ") <> "\n"

        new_line =
          words
          |> Enum.with_index()
          |> Enum.map_join(" ", fn {w, i} -> if i in rewritten, do: String.upcase(w), else: w end)

        world = world(line) |> edit(@step_one, 0, byte_size(line) - 1, new_line)
        {before, [target | _rest]} = new_line |> String.split(" ") |> Enum.split(your_word)
        at = before |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum()
        removed = if partial, do: max(byte_size(target) - 1, 1), else: byte_size(target)
        world = edit(world, :user, at, removed, your_text)
        assert_rejects_exact_or_refused(world)
      end
    end

    # Compaction changes no outcome reachable at the moment it runs: the document, your undo, and every task's reject.
    # Later edits may resolve differently, because the merged step's replacement now spans the absorbed one; the
    # compacted world then keeps every invariant on its own (the model checks in `unwind/1`).
    property "compaction slices reach 75% of the budget or leave no drafts, and change no outcome at that moment" do
      check all(
              commands <- StreamData.list_of(command(), max_length: 40),
              cut <- StreamData.integer(0..40),
              budget <- StreamData.integer(4..30),
              slice <- StreamData.integer(1..20),
              max_runs: runs(300)
            ) do
        {before, rest} = Enum.split(commands, cut)
        plain = Enum.reduce(before, world("abc\ndef\n", run_budget: budget), &run/2)
        compacted = plain |> want_compaction() |> compact_fully(slice)

        assert text(compacted) == text(plain)
        assert outcome(step(compacted, :undo)) == outcome(step(plain, :undo))
        %{task_ticks: ticks} = plain.history

        for {task, _tick} <- ticks do
          assert reject_text(compacted, task) == reject_text(plain, task)
        end

        compacted =
          Enum.reduce(rest, compacted, fn command, world ->
            command |> run(world) |> compact_fully(slice)
          end)

        case unwind(compacted) do
          {:done, world} -> assert text(world) == "abc\ndef\n"
          {:stuck, world} -> assert UnitModel.revertable_units(world.history) == MapSet.new()
        end
      end

      IO.puts("\n[compaction] history slices run: #{Process.get(:slices, 0)}")
    end

    # The final review: steps that arrive faster than slices run left merged runs that no later slice could reach.
    test "compaction lagging several steps behind still folds a task's whole chain of drafts" do
      lines = for n <- 1..20, do: "value_#{n} = beta\n"

      lagging =
        Enum.reduce(1..8, world(Enum.join(lines), run_budget: 30), fn round, world ->
          content = text(world)

          world =
            edit(
              world,
              {:minga, "task-1", "s#{round}"},
              0,
              byte_size(content),
              String.replace(content, ~r/beta\d*/, "beta#{round}")
            )

          case UndoHistory.compact_slice(want_compaction(world).history, 5) do
            {_status, history, _slice} -> %{world | history: history}
          end
        end)

      settled = lagging |> want_compaction() |> compact_fully(500)
      provenance = UndoHistory.provenance(settled.history)
      assert Provenance.draft_count(provenance) == 0
      assert Provenance.run_count(provenance) <= 3 * length(lines) + 1
    end

    test "compaction reports a history still over budget once, when no drafts are left" do
      world =
        Enum.reduce(1..6, world("a\nb\nc\n", run_budget: 4), fn n, world ->
          edit(world, {:minga, "task-#{n}", "call"}, 0, 1, "x#{n}")
        end)

      assert UndoHistory.compaction_wanted?(world.history)
      assert {:over_budget, history, %{drafts: 0}} = UndoHistory.compact_slice(world.history, 100)
      refute UndoHistory.compaction_wanted?(history)
      assert {:done, _history, _slice} = UndoHistory.compact_slice(history, 100)
    end

    # R1: another author's bytes keep their identity only where an alignment proves them unchanged. Ground truth comes
    # from applying known edits to bytes with known identity. With every byte distinct, a byte credited to Minga must be
    # one of Minga's that survived, and the reject removes exactly the bytes credited to Minga or is refused.
    property "with distinct bytes, Minga keeps only bytes it wrote that survived, and the reject removes exactly those" do
      check all(
              {base, minga_pieces, your_edits} <- distinct_scenario(),
              max_runs: runs(400)
            ) do
        assert_identity_kept(base, minga_pieces, your_edits, :distinct)
      end
    end

    # With few distinct bytes the alignment may choose among equal bytes, but never more Minga bytes than survived, and
    # when none survived the reject changes nothing (round 4's stray `7`).
    property "with repeated bytes, Minga never keeps more bytes than survived, and the reject removes only those" do
      check all(
              base <- StreamData.string([?a, ?7, ?(, ?), ?\s, ?\n], min_length: 1, max_length: 16),
              minga_pieces <-
                StreamData.list_of(
                  StreamData.tuple(
                    {StreamData.integer(0..20),
                     StreamData.string([?a, ?7, ?(, ?)], min_length: 1, max_length: 3)}
                  ),
                  min_length: 1,
                  max_length: 3
                ),
              your_edits <-
                StreamData.list_of(
                  StreamData.tuple(
                    {StreamData.integer(0..40), StreamData.integer(0..3),
                     StreamData.string([?a, ?7, ?(, ?), ?B], max_length: 3)}
                  ),
                  max_length: 4
                ),
              max_runs: runs(600)
            ) do
        assert_identity_kept(base, minga_pieces, your_edits, :repeated)
      end
    end

    property "repeated SPC a u leaves only tasks your visible edits hold" do
      check all(commands <- StreamData.list_of(command(), max_length: 40), max_runs: runs(200)) do
        world = Enum.reduce(commands, world("abc\ndef\n"), &run/2)
        {_done_or_stuck, world} = reject_all(world)
        assert UnitModel.revertable_units(world.history) == MapSet.new()
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # A buffer as the history sees it: history, document and version, edited like the buffer process does.
  defp world(text, opts \\ []),
    do: %{history: UndoHistory.new(Document.new(text), opts), doc: Document.new(text), version: 0}

  defp edit(world, source, start, removed_bytes, inserted, opts \\ []) do
    at = Keyword.get(opts, :at, @t0)
    removed = binary_part(Document.content(world.doc), start, removed_bytes)
    patch = UndoPatch.replacement(start, removed, inserted, Document.cursor(world.doc))

    # As the buffer process does, the recording sees the document from before the edit.
    before = UndoHistory.before_change(world.history, world.doc)

    history =
      if Keyword.get(opts, :force, false),
        do: UndoHistory.record_edit_force(before, world.version, patch, source, at),
        else: UndoHistory.record_edit(before, world.version, patch, source, at)

    history = UndoHistory.before_change(history, nil)

    {:ok, doc} = Document.splice_byte_range(world.doc, start, removed_bytes, inserted, {0, 0})
    %{world | history: history, doc: doc, version: world.version + 1}
  end

  defp step(world, :undo),
    do: settle(world, UndoHistory.undo(world.history, world.version, world.doc))

  defp step(world, :redo),
    do: settle(world, UndoHistory.redo(world.history, world.version, world.doc))

  defp settle(world, {:ok, restore, history}),
    do: {:ok, install(world, restore, history), restore}

  defp settle(_world, other), do: other

  defp undo!(world), do: world |> step(:undo) |> elem(1)
  defp redo!(world), do: world |> step(:redo) |> elem(1)

  defp reject_newest_task(world) do
    {:ok, restore, history, _count, _tasks, _dropped} =
      UndoHistory.undo_agent_session(world.history, world.version, world.doc)

    install(world, restore, history)
  end

  defp install(world, restore, history) do
    version = if restore.version == :advance, do: world.version + 1, else: restore.version
    %{world | history: history, doc: restore.document, version: version}
  end

  defp text(world), do: Document.content(world.doc)

  defp offset_of(world, needle), do: world |> text() |> :binary.match(needle) |> elem(0)

  defp author_at(world, offset),
    do: world.history |> UndoHistory.provenance() |> Provenance.author_at(offset)

  defp command do
    StreamData.tuple({
      StreamData.member_of([:user, :user, :minga, :minga, :agent, :undo, :redo]),
      StreamData.integer(0..1_000),
      StreamData.integer(0..3),
      StreamData.string([?a..?c, ?\n], max_length: 4),
      StreamData.integer(0..2)
    })
  end

  defp run({:undo, _a, _b, _text, _n}, world), do: step_or_keep(world, :undo)
  defp run({:redo, _a, _b, _text, _n}, world), do: step_or_keep(world, :redo)

  defp run({author, a, b, inserted, n}, world) do
    size = byte_size(text(world))
    start = rem(a, size + 1)
    removed = min(b, size - start)

    source =
      case author do
        :user -> :user
        :agent -> :agent
        :minga -> {:minga, "task-#{rem(n, 2)}", "call-#{n}"}
      end

    # Spaced past the coalescing window, so every edit of yours is a group of its own.
    edit(world, source, start, removed, inserted, at: @t0 + world.version * @window)
  end

  defp step_or_keep(world, fun) do
    case step(world, fun) do
      {:ok, world, _restore} -> world
      _empty_or_blocked -> world
    end
  end

  # Undoes everything you did; whenever Minga blocks your undo, reverts the next unit instead. Stops when neither can
  # make progress, which only an edit of yours with visible text inside a change Minga rewrote can cause.
  defp unwind(world) do
    case step(world, :undo) do
      {:ok, world, _restore} ->
        unwind(world)

      {:blocked, {:overlaps, _key}} ->
        case press_reject(world) do
          {:ok, world} -> unwind(world)
          :stuck -> {:stuck, world}
        end

      :empty ->
        reject_all(world)
    end
  end

  defp reject_all(world) do
    case press_reject(world) do
      {:ok, world} -> reject_all(world)
      :empty -> {:done, world}
      :stuck -> {:stuck, world}
    end
  end

  # One press of SPC a u: it reverts a unit the brute-force model accepts, never removes visible text you wrote, or
  # changes nothing exactly when the model finds no revertable unit.
  defp press_reject(world) do
    accepted = UnitModel.revertable_units(world.history)

    case UndoHistory.undo_agent_session(world.history, world.version, world.doc) do
      {:ok, restore, history, _count, _tasks, _dropped} ->
        unit = UndoHistory.next_reject(world.history)
        assert MapSet.new(unit) in accepted, "#{inspect(unit)} not in #{inspect(accepted)}"
        after_world = install(world, restore, history)
        assert text(after_world) == UnitModel.reverted_text(world.history, text(world), unit)
        assert your_text(world) |> subsequence?(your_text(after_world))

        Process.put(
          :multi_units,
          Process.get(:multi_units, 0) + if(match?([_, _ | _], unit), do: 1, else: 0)
        )

        {:ok, after_world}

      :empty ->
        :empty

      {:blocked, {:overlaps, :you}, _task, _offset} ->
        assert accepted == MapSet.new()
        Process.put(:stuck, Process.get(:stuck, 0) + 1)
        :stuck
    end
  end

  # Rejecting any single task either reverts exactly what the model's visibility rule says, for a task the model calls
  # exact on its own, or is refused while the model says it is not.
  defp assert_rejects_exact_or_refused(world) do
    %{task_ticks: ticks} = world.history

    for {task, _tick} <- ticks do
      case UndoHistory.reject_task(world.history, task, world.version, world.doc) do
        {:ok, restore, _history, _count} ->
          assert UnitModel.exact?(world.history, [task])

          assert Document.content(restore.document) ==
                   UnitModel.reverted_text(world.history, text(world), [task])

        {:blocked, {:overlaps, _key}} ->
          refute UnitModel.exact?(world.history, [task])
      end
    end
  end

  defp coarse_command do
    StreamData.tuple({
      StreamData.member_of([:user, :user, :minga, :minga, :agent, :undo, :redo]),
      StreamData.integer(0..1_000),
      StreamData.integer(0..8),
      StreamData.string([?a..?c, ?\s, ?\n], max_length: 8),
      StreamData.integer(0..2)
    })
  end

  # Asks for compaction whatever the budget says, as a Minga step over budget would.
  defp want_compaction(world) do
    %{history: history} = world
    %{world | history: %{history | compaction_wanted: true}}
  end

  # Outcomes as far as compaction promises: the same text, or a refusal.
  defp outcome({:ok, world, _restore}), do: {:ok, text(world)}
  defp outcome(other), do: blocked_task(other)

  defp reject_text(world, task) do
    case UndoHistory.reject_task(world.history, task, world.version, world.doc) do
      {:ok, restore, _history, _count} -> {:ok, Document.content(restore.document)}
      other -> blocked_task(other)
    end
  end

  # A refusal stays a refusal; compaction may change which step or group it names first.
  defp blocked_task({:blocked, {:overlaps, _key}}), do: :blocked
  defp blocked_task(other), do: other

  # Distinct printable bytes: a base, Minga's insertions, and your edits, each byte used once.
  defp distinct_scenario do
    gen all(
          shuffled <- StreamData.constant(Enum.to_list(?!..?~)) |> StreamData.map(&Enum.shuffle/1),
          base_size <- StreamData.integer(1..12),
          minga_sizes <-
            StreamData.list_of(StreamData.integer(1..3), min_length: 1, max_length: 3),
          minga_at <- StreamData.list_of(StreamData.integer(0..30), length: 3),
          edits <-
            StreamData.list_of(
              StreamData.tuple(
                {StreamData.integer(0..40), StreamData.integer(0..3), StreamData.integer(0..3)}
              ),
              max_length: 4
            )
        ) do
      {base, rest} = Enum.split(shuffled, base_size)

      {minga_pieces, rest} =
        minga_sizes
        |> Enum.zip(minga_at)
        |> Enum.map_reduce(rest, fn {size, at}, rest ->
          {piece, rest} = Enum.split(rest, size)
          {{at, List.to_string(piece)}, rest}
        end)

      {your_edits, _rest} =
        Enum.map_reduce(edits, rest, fn {at, removed, inserted}, rest ->
          {piece, rest} = Enum.split(rest, inserted)
          {{at, removed, List.to_string(piece)}, rest}
        end)

      {List.to_string(base), minga_pieces, your_edits}
    end
  end

  # The text alone cannot tell which copy of equal bytes went where removed and inserted bytes share a value, or a
  # change's bytes equal the surviving byte on either side. Only histories without that pin Minga's count.
  defp ambiguous?(old, new) do
    kept = MapSet.new(for {_b, _who, id} <- new, is_integer(id), do: id)
    old_hunks = hunks(old, &MapSet.member?(kept, elem(&1, 2)))
    new_hunks = hunks(new, &is_integer(elem(&1, 2)))

    removed_values = MapSet.new(for {removed, _n} <- old_hunks, {b, _who, _id} <- removed, do: b)

    inserted_values =
      MapSet.new(for {inserted, _n} <- new_hunks, {b, _who, _id} <- inserted, do: b)

    # A removed byte equal to an inserted one anywhere gives the text two equally long alignments.
    not MapSet.disjoint?(removed_values, inserted_values) or
      Enum.zip(old_hunks, new_hunks)
      |> Enum.any?(fn {{removed, old_neighbours}, {inserted, new_neighbours}} ->
        values = Enum.map(removed ++ inserted, &elem(&1, 0))
        neighbours = Enum.map(old_neighbours ++ new_neighbours, &elem(&1, 0))
        values != [] and (Enum.any?(neighbours, &(&1 in values)) or values != Enum.uniq(values))
      end)
  end

  # The bytes between consecutive kept bytes, with those kept neighbours, one entry per gap including both ends.
  defp hunks(bytes, kept?) do
    {gaps, current, previous} =
      Enum.reduce(bytes, {[], [], nil}, fn byte, {gaps, current, previous} ->
        if kept?.(byte),
          do:
            {[{Enum.reverse(current), Enum.reject([previous, byte], &is_nil/1)} | gaps], [], byte},
          else: {gaps, [byte | current], previous}
      end)

    Enum.reverse([{Enum.reverse(current), Enum.reject([previous], &is_nil/1)} | gaps])
  end

  defp assert_identity_kept(base, minga_pieces, your_edits, kind) do
    # Bytes as {byte, author} through Minga's insertions, recorded one by one, then your edits, recorded as one patch.
    {world, bytes} =
      Enum.reduce(minga_pieces, {world(base), for(<<b <- base>>, do: {b, :base})}, fn {at, piece},
                                                                                      {world,
                                                                                       bytes} ->
        at = rem(at, length(bytes) + 1)

        {edit(world, @step_one, at, 0, piece),
         List.insert_at(bytes, at, Enum.map(:binary.bin_to_list(piece), &{&1, :minga}))
         |> List.flatten()}
      end)

    old = Enum.with_index(bytes, fn {b, who}, id -> {b, who, id} end)

    bytes =
      Enum.reduce(Enum.with_index(your_edits), old, fn {{at, removed, inserted}, n}, bytes ->
        at = rem(at, length(bytes) + 1)
        {before, rest} = Enum.split(bytes, at)
        mine = Enum.map(:binary.bin_to_list(inserted), &{&1, :you, {:new, n}})
        before ++ mine ++ Enum.drop(rest, removed)
      end)

    ambiguous? = ambiguous?(old, bytes)
    bytes = Enum.map(bytes, fn {b, who, _id} -> {b, who} end)
    new_text = for {b, _who} <- bytes, into: <<>>, do: <<b>>
    world = edit(world, :user, 0, byte_size(text(world)), new_text)
    assert text(world) == new_text
    surviving = for {b, :minga} <- bytes, do: b
    spans = Provenance.spans(UndoHistory.provenance(world.history), 0, byte_size(new_text))

    credited =
      for {from, to, {:minga, _task}, _key} <- spans, offset <- from..(to - 1)//1, do: offset

    credited_bytes = Enum.map(credited, &:binary.at(new_text, &1))

    case kind do
      :distinct -> assert MapSet.subset?(MapSet.new(credited_bytes), MapSet.new(surviving))
      :repeated -> if not ambiguous?, do: assert(length(credited) <= length(surviving))
    end

    case UndoHistory.reject_task(world.history, {:minga, "task-1"}, world.version, world.doc) do
      {:ok, restore, _history, _count} ->
        credited = MapSet.new(credited)

        expected =
          for {b, offset} <- Enum.with_index(:binary.bin_to_list(new_text)),
              not MapSet.member?(credited, offset),
              into: <<>>,
              do: <<b>>

        assert Document.content(restore.document) == expected

      {:blocked, _reason} ->
        :ok

      :empty ->
        :ok
    end
  end

  # Runs compaction slices until the history says it is done, checking P6 at the end.
  defp compact_fully(world, slice) do
    if UndoHistory.compaction_wanted?(world.history) do
      {status, history, result} = UndoHistory.compact_slice(world.history, slice)
      Process.put(:slices, Process.get(:slices, 0) + 1)
      world = %{world | history: history}

      if status == :more do
        compact_fully(world, slice)
      else
        %{run_budget: budget} = history
        assert result.runs <= div(budget * 3, 4) or result.drafts == 0
        world
      end
    else
      world
    end
  end

  defp your_text(world) do
    provenance = UndoHistory.provenance(world.history)

    for {from, to, :you, _key} <- Provenance.spans(provenance, 0, byte_size(text(world))),
        into: <<>>,
        do: binary_part(text(world), from, to - from)
  end

  defp subsequence?(<<>>, _text), do: true
  defp subsequence?(_needle, <<>>), do: false
  defp subsequence?(<<c, rest::binary>>, <<c, more::binary>>), do: subsequence?(rest, more)
  defp subsequence?(needle, <<_c, more::binary>>), do: subsequence?(needle, more)

  defp deleted_by_you?(world, {id, _bytes}) do
    provenance = UndoHistory.provenance(world.history)
    run = Enum.find(Provenance.runs(provenance), &(&1.id == id))

    Enum.any?(
      run.deletions,
      &(Provenance.applied?(provenance, &1) and Provenance.group_key(provenance, &1) == nil)
    )
  end

  defp live_minga_runs(world) do
    for run <- Provenance.runs(UndoHistory.provenance(world.history)),
        run.live,
        match?({:minga, _task}, run.author),
        into: MapSet.new(),
        do: {run.id, run.bytes}
  end

  # PROPERTY_RUNS scales every property here, for the high-count runs a review asks for.
  defp runs(count), do: count * String.to_integer(System.get_env("PROPERTY_RUNS", "1"))
end
