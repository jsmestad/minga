defmodule Minga.Buffer.UndoHistoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.UndoPatch
  alias Minga.Test.ProvenanceModel
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
        Enum.reduce(1..1100, world("", shadow: false), fn n, world ->
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

      assert {:ok, restore, history, %{reverted: 2}} =
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

      {:ok, restore, _history, %{reverted: 1}} =
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

      {:ok, restore, history, %{reverted: 1000}} =
        UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert restore.version == :advance
      assert Document.content(restore.document) == "task\n" <> String.duplicate("x", 100)
      assert [{@step_one, [{0, 5}]}] = UndoHistory.minga_changes(history, "task-1")

      assert history |> UndoHistory.provenance() |> Provenance.author_at(104) ==
               {:minga, :untasked}

      # The tasked step is never evicted and still reverts on its own.
      assert {:ok, _restore, _history, %{reverted: 1}} =
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

      # task-1 edited last; its older step reverts together with task-2's step that rewrote it, in one press.
      assert UndoHistory.next_reject(world.history) == {:minga, "task-1"}

      assert {:ok, restore, history,
              %{reverted: 2, total: 2, tasks: [{:minga, "task-2"}], held: nil}} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert Document.content(restore.document) == "axb\nq"
      assert UndoHistory.next_reject(history) == nil
    end

    test "8000 Minga steps rewriting one word stay fast though their tombstones pile up there" do
      {micros, world} =
        :timer.tc(fn ->
          Enum.reduce(1..8_000, world("let x = foo;\n", shadow: false), fn n, world ->
            old = if n == 1, do: 3, else: byte_size("w#{n - 1}")
            edit(world, {:minga, "task-1", "s#{n}"}, 8, old, "w#{n}")
          end)
        end)

      assert text(world) == "let x = w8000;\n"
      assert micros < 5_000_000
    end

    test "8000 of your retypes over a word Minga replaced stay fast" do
      world = edit(world("let x = foo;\n", shadow: false), @step_one, 8, 3, "bar")

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

      assert {:ok, restore, _history, %{reverted: 1}} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert Document.content(restore.document) == "foo, bar, baz\n"
    end

    # Round 5 R3: the step that rewrote your edit reverts first, so your edit comes back and can be undone.
    test "an edit of yours that a later step rewrote comes back when that step reverts, then holds the older step" do
      world = world("xay\n") |> edit(@step_one, 1, 1, "bcd") |> edit(:user, 2, 1, "Q")
      world = edit(world, @step_two, 2, 1, "Z")
      assert text(world) == "xbZdy\n"
      assert {:blocked, {:overlaps, @step_two}} = step(world, :undo)

      assert {:ok, restore, history, %{reverted: 1, total: 2, held: 2, dropped: []}} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      world = install(world, restore, history)
      assert text(world) == "xbQdy\n"
      world = undo!(world)
      assert text(reject_newest_task(world)) == "xay\n"
    end

    # A group of yours whose text a newer group of yours deleted has nothing visible; it reverts with the step.
    test "an edit of yours with no visible text left reverts with the step and leaves your undo" do
      world = world("xay\n") |> edit(@step_one, 1, 1, "bcd") |> edit(:user, 2, 1, "Q")
      world = edit(world, :user, 2, 1, "", at: @t0 + 10 * @window)
      assert text(world) == "xbdy\n"

      # Your deletion of "Q" consumed your replacement of "c", and the cover reached the step's change while "b" and
      # "d" are live: it marks the step, so that edit reverts with the step too, and both leave your undo.
      assert {:ok, restore, history, %{reverted: 1, dropped: [_first, _second]}} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert Document.content(restore.document) == "xay\n"
      assert UndoHistory.undo_count(history) == 0
    end

    test "an edit of yours inside Minga's change with text still visible holds the task" do
      world = world("xay\n") |> edit(@step_one, 1, 1, "bcd") |> edit(:user, 2, 1, "QR")
      world = edit(world, @step_two, 3, 1, "Z")
      assert text(world) == "xbQZdy\n"
      assert {:blocked, {:overlaps, @step_two}} = step(world, :undo)

      # Round 5 R3: the newer step reverts, giving back your R; your edit then holds the older step until you undo it.
      assert {:ok, restore, history, %{reverted: 1, total: 2, held: 2}} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      world = install(world, restore, history)
      assert text(world) == "xbQRdy\n"
      world = undo!(world)
      assert text(world) == "xbcdy\n"
      assert text(reject_newest_task(world)) == "xay\n"
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

      assert {:ok, _restore, _history, _summary} =
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

      # The newer step reverts and gives your Q back; your edit then holds the older step, and "ccc" stays deleted.
      assert {:ok, restore, _history, %{reverted: 1, held: 1}} =
               UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert Document.content(restore.document) == "XQZ bbb\n\n"
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

        {:done, world} = unwind(world)
        assert text(world) == "abc\ndef\n"
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
        {:done, world} = reject_all(world)
        %{task_ticks: ticks} = world.history
        assert ticks == %{}
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

        world = world(line, shadow: false) |> edit(@step_one, 0, byte_size(line) - 1, new_line)
        {before, [target | _rest]} = new_line |> String.split(" ") |> Enum.split(your_word)
        at = before |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum()
        removed = if partial, do: max(byte_size(target) - 1, 1), else: byte_size(target)
        world = edit(world, :user, at, removed, your_text)
        assert_rejects_exact_or_refused(world)
      end
    end

    # Compaction changes no outcome reachable at the moment it runs: the document, your undo, and every task's reject.
    # The property below checks every later outcome too.
    property "compaction slices reach 75% of the budget or leave no drafts, and change no outcome at that moment" do
      check all(
              commands <- StreamData.list_of(command(), max_length: 40),
              cut <- StreamData.integer(0..40),
              budget <- StreamData.integer(4..30),
              slice <- StreamData.integer(1..20),
              max_runs: runs(300)
            ) do
        slices_case(commands, cut, budget, slice)
      end

      IO.puts("\n[compaction] history slices run: #{Process.get(:slices, 0)}")
    end

    # Two histories where merges once straddled edits of yours: `u` waited for a merged class while the press waited
    # for your undo. Merges now wait until your edits after the class's oldest step are final, so both finish.
    test "merged steps never deadlock a press against your undo" do
      slices_case(
        [
          {:minga, 691, 1, "bb\n\n", 0},
          {:minga, 864, 1, "aba", 2},
          {:minga, 795, 2, "acca", 0},
          {:user, 255, 3, "cba", 2},
          {:user, 37, 1, "acc", 2},
          {:user, 726, 0, "\n\n", 1},
          {:minga, 538, 2, "\n", 1},
          {:user, 665, 1, "\nc", 0},
          {:minga, 357, 0, "a", 0},
          {:user, 783, 3, "ba", 0},
          {:user, 657, 0, "\naa", 2},
          {:user, 257, 3, "a\naa", 2},
          {:user, 388, 2, "", 0},
          {:user, 977, 3, "c", 1},
          {:user, 315, 1, "cc", 1},
          {:user, 32, 2, "a", 2},
          {:user, 417, 0, "aa", 2},
          {:user, 289, 2, "aacb", 0},
          {:user, 761, 3, "bab\n", 0},
          {:user, 642, 3, "b", 2},
          {:user, 407, 0, "ca", 1},
          {:agent, 521, 3, "b", 1},
          {:user, 226, 2, "", 1},
          {:agent, 223, 0, "c", 0},
          {:minga, 681, 3, "\n", 0}
        ],
        34,
        22,
        8
      )

      slices_case(
        [
          {:minga, 526, 0, "c", 2},
          {:user, 51, 1, "b\nb", 1},
          {:agent, 788, 1, "\naaa", 2},
          {:user, 238, 2, "", 1},
          {:minga, 236, 2, "bbc", 1},
          {:minga, 884, 0, "b\naa", 1},
          {:minga, 59, 2, "cc", 1},
          {:agent, 887, 1, "cbc\n", 1},
          {:user, 833, 1, "\n\n", 2},
          {:minga, 622, 3, "", 0},
          {:user, 218, 0, "abb", 0},
          {:minga, 389, 1, "b", 1},
          {:minga, 412, 2, "a", 1},
          {:agent, 904, 1, "aba\n", 2},
          {:agent, 579, 1, "bbc", 1},
          {:minga, 908, 2, "", 1},
          {:redo, 117, 3, "a\n", 0},
          {:undo, 91, 1, "b", 1},
          {:redo, 36, 1, "b\n\na", 2},
          {:minga, 320, 3, "c\nc", 1},
          {:minga, 5, 3, "\ncab", 1},
          {:minga, 680, 3, "a", 2},
          {:minga, 349, 0, "\n", 0},
          {:minga, 269, 1, "c", 1},
          {:user, 709, 3, "\nba\n", 0},
          {:user, 115, 3, "bb", 2},
          {:minga, 481, 0, "acaa", 1},
          {:undo, 491, 3, "a", 0},
          {:agent, 514, 1, "\n", 0}
        ],
        10,
        17,
        4
      )
    end

    # Compaction is invisible to everything after it: the same history with compaction off and with a small budget (so
    # slices and inline merges run) gives the same document and the same outcome of every u, redo, SPC a u and reject.
    property "compaction changes no later outcome of u, redo, SPC a u or a reject" do
      check all(
              commands <-
                StreamData.list_of(
                  StreamData.one_of([
                    command(),
                    StreamData.constant(:press),
                    StreamData.constant(:reject)
                  ]),
                  max_length: 40
                ),
              budget <- StreamData.integer(4..12),
              slice <- StreamData.integer(1..6),
              max_runs: runs(300)
            ) do
        plain = world("abc\ndef\n", run_budget: 1_000_000, shadow: false)
        compacted = world("abc\ndef\n", run_budget: budget, shadow: false)
        twin_run(commands, plain, compacted, slice, &twin_apply/2)
      end
    end

    # Addendum 4 F2's shape: budget 3, whole-character edits with emoji, two tasks, presses and your undo.
    property "compaction changes no later outcome on emoji text with two tasks and a tiny budget" do
      graphemes = ["a", "f", "o", "b", "r", "😀", "é", "\n"]

      check all(
              commands <-
                StreamData.list_of(
                  StreamData.one_of([
                    StreamData.tuple(
                      {StreamData.member_of([:user, :minga, :minga]), StreamData.integer(0..20),
                       StreamData.integer(0..6),
                       StreamData.list_of(StreamData.member_of(graphemes), max_length: 7),
                       StreamData.integer(0..3)}
                    ),
                    StreamData.constant(:press),
                    StreamData.constant(:undo)
                  ]),
                  max_length: 14
                ),
              max_runs: runs(400)
            ) do
        emoji_twins(commands)
      end

      IO.puts("\n[twins, emoji] merge differences: #{Process.get(:merge_differences, 0)}")
    end

    # Merge consequence 1, by hand. Task 0 writes "aaaa" (step 1). Task 1 writes seven a's before it (step 2). Task 0
    # writes "\no" over five a's, four of task 1's and one of its own (step 3), and task 1 deletes "oaaa", step 3's "o"
    # and the rest of step 1's a's (step 4). The press on task 1 reverts step 4, and step 2 with step 3, which rewrote
    # it. Without compaction that leaves step 1's "aaaa". With a budget of 3, step 1 was absorbed into step 3, so the
    # press takes it too and leaves "".
    test "a press that reverts a merged step takes its whole class" do
      emoji_twins([
        {:minga, 0, 0, ["a", "a", "a", "a"], 0},
        {:minga, 0, 0, ["a", "a", "a", "a", "a", "a", "a"], 1},
        {:minga, 15, 5, ["\n", "o"], 0},
        {:minga, 13, 4, [], 1},
        :press
      ])

      assert Process.get(:merge_differences) == 1
    end

    # Merge consequence 2, from round 5 case (b). Task 1's steps 2 and 4 are in one class, and your edit holds step 2.
    # Without compaction the press reverts steps 4 and 1; step 4's text was already gone under your edit. With
    # compaction the hold on step 2 holds the class, so step 4 stays. The document is the same, and press and u still
    # finish.
    test "a hold on any member of a merged class holds the class" do
      emoji_twins([
        {:minga, 0, 0, ["a"], 3},
        {:minga, 15, 0, ["a", "a", "a", "a", "é", "o"], 1},
        {:minga, 9, 5, ["é", "😀", "😀", "r"], 2},
        {:minga, 19, 6, ["a", "a", "\n"], 3},
        {:user, 13, 5, ["é"], 0},
        :press,
        :undo
      ])

      assert Process.get(:merge_differences) == 1
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

    # R3: with step groups that resume only uninterrupted and merges that never skip a group, every dependency points
    # from an older group to a newer one, after every edit, undo, redo, revert and compaction slice.
    property "the dependency graph stays acyclic after every operation" do
      check all(
              commands <- StreamData.list_of(command(), max_length: 40),
              budget <- StreamData.integer(4..20),
              max_runs: runs(300)
            ) do
        Enum.reduce(commands, world("abc\ndef\n", run_budget: budget), fn command, world ->
          world = command |> run(world) |> compact_fully(3)
          assert UnitModel.acyclic?(world.history)
          world
        end)
      end
    end

    # The void case found by the never-drop oracle: your replacement of "a" was undone and then discarded by your next
    # edit, so it never happened, and "Q" never stood for "a". Rejecting t1 brings "a" back.
    test "a later edit over text of a discarded undo step stands for nothing it replaced" do
      world =
        world("pab\n")
        |> edit(:user, 1, 1, "X")
        |> undo!()
        |> edit(:user, 1, 0, "m", at: @t0 + 2 * @window)
        |> edit({:minga, "t1", "s"}, 2, 1, "")
        |> edit(:user, 0, 2, "Q", at: @t0 + 4 * @window)
        |> edit({:minga, "t2", "s"}, 0, 1, "")

      assert text(world) == "b\n"
      assert UndoHistory.redo_count(world.history) == 0

      assert {:ok, restore, _history, _count} =
               UndoHistory.reject_task(world.history, {:minga, "t1"}, world.version, world.doc)

      assert Document.content(restore.document) == "ab\n"
    end

    # Addendum 4 F1: every recorded run boundary is a cut between code points, after every operation, on multi-byte,
    # combining and CJK text; deleted text is whole characters, so a revert never meets half a character.
    property "every run boundary is a code point cut, on multi-byte, combining and CJK text" do
      graphemes = ["ö", "é", "中", "丁", "e\u0301", "👍🏽", "👨‍👩‍👧", "a", " ", "\n"]

      check all(
              base <- StreamData.list_of(StreamData.member_of(graphemes), max_length: 8),
              commands <-
                StreamData.list_of(
                  StreamData.tuple(
                    {StreamData.member_of([:user, :user, :minga, :minga, :undo, :press]),
                     StreamData.integer(0..20), StreamData.integer(0..3),
                     StreamData.list_of(StreamData.member_of(graphemes), max_length: 3),
                     StreamData.integer(0..2)}
                  ),
                  max_length: 25
                ),
              budget <- StreamData.integer(4..40),
              max_runs: runs(200)
            ) do
        world = world(Enum.join(base), run_budget: budget)

        Enum.reduce(commands, world, fn command, world ->
          world = command |> grapheme_op(world) |> want_compaction() |> compact_fully(5)
          assert_code_point_cuts(world)
          world
        end)
      end
    end

    # Your edit between two steps of one task, touched by both, then compaction: the merge is refused, no component of
    # the merged graph holds an edit of yours (the shadow checks after every operation), and SPC a u with u always
    # finishes.
    property "your edit between two steps that both touched it never deadlocks SPC a u after compaction" do
      check all(
              rounds <-
                StreamData.list_of(
                  StreamData.tuple(
                    {StreamData.integer(0..20), StreamData.integer(1..3),
                     StreamData.integer(0..2),
                     StreamData.string([?x..?z], min_length: 1, max_length: 3),
                     StreamData.string([?A..?C], min_length: 1, max_length: 3),
                     StreamData.boolean()}
                  ),
                  min_length: 1,
                  max_length: 4
                ),
              budget <- StreamData.integer(1..12),
              max_runs: runs(200)
            ) do
        world =
          Enum.reduce(
            Enum.with_index(rounds),
            world("aaa bbb ccc\nddd eee\n", run_budget: budget),
            fn
              {{at, width, inside, yours, minga, other_spot?}, n}, world ->
                size = byte_size(text(world))
                start = rem(at, max(size - 4, 1))

                world =
                  edit(
                    world,
                    {:minga, "t", "s#{2 * n}"},
                    start,
                    min(width + 2, size - start),
                    "M#{minga}"
                  )

                mine_at = min(start + 1 + inside, byte_size(text(world)) - 1)
                world = edit(world, :user, mine_at, 1, yours, at: @t0 + (4 * n + 1) * @window)
                size = byte_size(text(world))
                theirs_at = min(mine_at + rem(inside, 2), size - 1)
                world = edit(world, {:minga, "t", "s#{2 * n + 1}"}, theirs_at, 1, minga)

                world =
                  if other_spot?,
                    do:
                      edit(
                        world,
                        {:minga, "t", "s#{2 * n + 1}"},
                        0,
                        min(3, byte_size(text(world))),
                        "QQ"
                      ),
                    else: world

                world |> want_compaction() |> compact_fully(5)
            end
          )

        {:done, world} = unwind(world)
        assert text(world) == "aaa bbb ccc\nddd eee\n"
      end
    end

    # The shrunk history for Addendum 3 item 3: compaction merged a step only across a stretch, and SPC a u used to
    # revert the newer half while the older half stayed applied. A merged class now reverts as one; the shadow checks
    # after every operation that merged steps never differ in applied or final state.
    test "SPC a u never reverts half of a merged class" do
      commands = [
        {:minga, 623, 1, "\nb\na", 1},
        {:minga, 119, 1, "c\nb\n", 1},
        {:user, 650, 3, "", 1},
        {:user, 352, 1, "c\n", 2},
        {:minga, 319, 2, "c\nac", 2},
        {:minga, 522, 3, "aa", 1},
        {:minga, 613, 2, "\n\nb", 2},
        {:undo, 663, 1, "b", 0},
        {:redo, 591, 1, "\nb", 0},
        {:undo, 282, 3, "\nc", 1},
        {:user, 114, 0, "", 1},
        {:user, 934, 0, "", 1},
        {:user, 782, 0, "bc", 1}
      ]

      world =
        Enum.reduce(commands, world("abc\ndef\n", run_budget: 18), fn command, world ->
          command |> run(world) |> want_compaction() |> compact_fully(15)
        end)

      {:done, world} = unwind(world)
      assert text(world) == "abc\ndef\n"
    end

    # Round 4's DL2 and the reused-step counterexample: a step that resumes after your edit opens a new group.
    test "a step resumed after your edit inside its change never deadlocks with your undo" do
      for second <- [@step_two, @step_one] do
        world =
          world("hello world\n") |> edit(@step_one, 6, 5, "there") |> edit(:user, 8, 3, "XYZ")

        world = edit(world, second, 8, 2, "ab")
        assert text(world) == "hello thabZ\n"

        {:ok, restore, history, summary} =
          UndoHistory.undo_agent_session(world.history, world.version, world.doc)

        assert summary.reverted == 1
        assert summary.held != nil

        world = install(world, restore, history)
        assert text(world) == "hello thXYZ\n"
        world = undo!(world)
        assert text(world) == "hello there\n"
        assert text(reject_newest_task(world)) == "hello world\n"
      end
    end

    # Found by the round-5 bug hunt: an edit that held an early step reverted with a later one in the same press.
    test "SPC a u names a holding edit that still exists after the press" do
      commands = [
        {:user, 0, 2, "aaa", 0},
        {:user, 0, 2, "b\n cb", 1},
        {:minga, 542, 7, "aa\n\nc ba", 2},
        {:user, 56, 3, "bcbb\na", 2},
        {:user, 616, 3, "", 2},
        {:user, 789, 7, "\n  ", 1},
        {:undo, 808, 3, "\n \n\n\n\na", 1},
        {:minga, 804, 1, "\n\nc aa", 1},
        {:user, 28, 2, " \nbbab\n\n", 1},
        {:undo, 552, 8, "aa", 1},
        {:user, 7, 0, "b\n\nb\n", 0},
        {:user, 72, 5, "ac\nc", 2},
        {:user, 481, 8, "b", 0},
        {:minga, 907, 1, "c\ncb\nca\n", 2},
        {:user, 631, 8, "", 0},
        {:minga, 296, 6, "b\nc b", 2},
        {:user, 375, 8, "a", 2},
        {:minga, 449, 8, "c\n ", 1},
        {:undo, 933, 0, "", 0},
        {:minga, 31, 7, "b \nbc ", 1},
        {:undo, 715, 1, "", 1},
        {:minga, 223, 3, "\n\nc", 2},
        {:redo, 265, 1, "a bc b\n", 1},
        {:undo, 520, 3, "c\ncbcbb", 0},
        {:user, 285, 5, "", 1}
      ]

      world = Enum.reduce(commands, world("ab cd ef\ngh ij\n", recording: :coarse), &run/2)
      {:done, world} = reject_all(world)
      %{task_ticks: ticks} = world.history
      assert ticks == %{}
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
        {:done, world} = reject_all(world)
        %{task_ticks: ticks} = world.history
        assert ticks == %{}
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # A buffer as the history sees it: history, document and version, edited like the buffer process does. The shadow is
  # the never-drop model replaying every provenance operation the history makes; see `shadow/1`.
  # The model costs O(n) per byte, so the long benchmarks run without it (`shadow: false`).
  defp world(text, opts \\ []) do
    {shadow?, opts} = Keyword.pop(opts, :shadow, true)
    history = UndoHistory.new(Document.new(text), opts)

    if shadow? do
      %{
        history: %{history | provenance: Provenance.start_trace(history.provenance)},
        doc: Document.new(text),
        version: 0,
        shadow: %{model: ProvenanceModel.new(text), merged: false, merges: []}
      }
    else
      %{history: history, doc: Document.new(text), version: 0, shadow: nil}
    end
  end

  # Steps a compaction merged never differ in applied or final state: they flip and finalize together, which reading a
  # change's group from its first made run relies on. A step merged and still holding runs of its own is in the class
  # of the step it merged into.
  defp assert_merged_steps_move_together(history, merges) do
    provenance = UndoHistory.provenance(history)

    for {old, new} <- merges,
        Provenance.group?(provenance, old),
        Provenance.group?(provenance, new) do
      assert new in UndoHistory.merge_class(history, old)
    end

    %{merges: links} = history

    for {group, _partners} <- links do
      class = UndoHistory.merge_class(history, group)
      assert Enum.all?(class, &Provenance.group?(provenance, &1))

      assert class |> Enum.map(&Provenance.applied?(provenance, &1)) |> Enum.uniq() |> length() ==
               1
    end

    Process.put(:merged_pairs, Process.get(:merged_pairs, 0) + length(merges))
  end

  # Replays what the history did into the never-drop model. Until a compaction merges two steps, the model's text is the
  # document after every operation.
  defp shadow(%{shadow: nil} = world), do: world

  defp shadow(world) do
    case Provenance.take_trace(world.history.provenance) do
      {nil, _provenance} ->
        %{world | shadow: nil}

      {operations, provenance} ->
        merges = for({:absorb, old, new} <- operations, do: {old, new}) ++ world.shadow.merges
        merged = world.shadow.merged or merges != []

        # Once two steps merged, a press may take the older half with it, so the model, which never merges, may stop
        # following the document; it is then left behind and only the invariants are checked.
        model =
          if world.shadow.model && not (merged and world.shadow.merged and stale_model?(world)),
            do: ProvenanceModel.replay(world.shadow.model, operations)

        assert_merged_steps_move_together(world.history, merges)
        assert UnitModel.held_components(world.history) == []

        if model && not merged, do: assert(ProvenanceModel.text(model) == text(world))
        Process.put(:shadowed, Process.get(:shadowed, 0) + length(operations))

        %{
          world
          | history: %{world.history | provenance: provenance},
            shadow: %{model: model, merged: merged, merges: merges}
        }
    end
  end

  defp stale_model?(%{shadow: %{model: model}} = world),
    do: ProvenanceModel.text(model) != text(world)

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
    shadow(%{world | history: history, doc: doc, version: world.version + 1})
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
    {:ok, restore, history, _summary} =
      UndoHistory.undo_agent_session(world.history, world.version, world.doc)

    install(world, restore, history)
  end

  defp install(world, restore, history) do
    version = if restore.version == :advance, do: world.version + 1, else: restore.version
    shadow(%{world | history: history, doc: restore.document, version: version})
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

  # Runs one history twice, without compaction and with it, and requires the same document and the same outcome after
  # every operation: whether u, redo, a reject or a press was refused and for which task, whether a press left a hold,
  # and which steps a press reverted, compared through the merges (a step absorbed completely counts as the step it
  # was absorbed into). Two differences are the contract of merging, and each is recognized by its mechanism:
  #
  # 1. A press that reverts a merged step takes its whole class: the steps the compacted press reverted beyond the
  #    plain one are members of a class it reverted, or groups that depend on such a member.
  # 2. A hold on any member holds the class: the steps the plain press reverted and the compacted one did not are in a
  #    class with a step the plain press left behind.
  #
  # After either, the compacted press must still be exact for its own record, keep your visible text, and repeated
  # presses and undos must finish; the two histories then differ for good and the comparison ends.
  defp twin_run(commands, plain, compacted, slice, apply) do
    compacted =
      compacted
      |> Map.update!(:history, fn history ->
        %{history | provenance: Provenance.start_trace(history.provenance)}
      end)
      |> Map.put(:absorbed, %{})

    Enum.reduce_while(commands, {plain, compacted}, fn command, {plain, compacted} ->
      {plain_before, compacted_before} = {plain, compacted}
      {plain_outcome, plain} = apply.(command, Map.delete(plain, :pressed))
      {compacted_outcome, compacted} = apply.(command, Map.delete(compacted, :pressed))
      compacted = compacted |> compact_fully(slice) |> note_absorbed()
      absorbed = compacted.absorbed
      reverted = pressed_steps(plain, absorbed)
      taken = pressed_steps(compacted, absorbed)

      if compacted_outcome == plain_outcome and text(compacted) == text(plain) and
           reverted == taken do
        {:cont, {plain, compacted}}
      else
        assert command == :press and
                 merge_difference?(
                   reverted,
                   taken,
                   {plain_before, plain},
                   compacted_before,
                   absorbed
                 ),
               "plain #{inspect(plain_outcome)}, compacted #{inspect(compacted_outcome)} on #{inspect(command)}"

        assert_press_guarantees(compacted_before)
        Process.put(:merge_differences, Process.get(:merge_differences, 0) + 1)
        {:halt, {plain, compacted}}
      end
    end)
  end

  defp merge_difference?(reverted, taken, {plain_before, plain}, compacted_before, absorbed) do
    %{merges: merges} = compacted_before.history
    finals = &MapSet.new(&1, fn group -> final_step(group, absorbed) end)
    class = &finals.(UndoHistory.merge_class(merges, final_step(&1, absorbed)))
    extra = MapSet.difference(taken, reverted)
    missing = MapSet.difference(reverted, taken)
    provenance = UndoHistory.provenance(compacted_before.history)

    takes_class? =
      MapSet.size(missing) == 0 and
        Enum.all?(extra, fn step ->
          Enum.any?(taken, fn member ->
            step in class.(member) or step in finals.(dependents_of(provenance, class.(member)))
          end)
        end)

    plain_groups = for {group, _key} <- plain_before.history.minga, do: group
    left_behind = finals.(plain_groups -- Map.get(plain, :pressed, []))

    held_class? =
      MapSet.size(extra) == 0 and
        Enum.all?(missing, fn step ->
          Enum.any?(class.(step), &(&1 in left_behind)) or step in left_behind
        end)

    takes_class? or held_class?
  end

  defp dependents_of(provenance, groups) do
    Enum.reduce(groups, MapSet.new(), fn group, found ->
      if Provenance.group?(provenance, group),
        do: Enum.into(Provenance.later_deleters_of(provenance, group), found),
        else: found
    end)
  end

  # A press after a merge difference: exact for its own record, keeps your visible text, and press with u finishes.
  defp assert_press_guarantees(world) do
    case press_reject(world) do
      {:ok, after_world, _held} -> unwind(after_world)
      _held_or_empty -> unwind(world)
    end
  end

  defp note_absorbed(world) do
    {operations, provenance} = Provenance.take_trace(world.history.provenance)
    absorbed = for {:absorb, old, new} <- operations || [], into: world.absorbed, do: {old, new}
    %{world | history: %{world.history | provenance: provenance}, absorbed: absorbed}
  end

  defp pressed_steps(world, absorbed),
    do: world |> Map.get(:pressed, []) |> MapSet.new(&final_step(&1, absorbed))

  # The step a group's text lives in after the merges: itself, or the step it was absorbed into, followed through.
  defp final_step(group, absorbed) do
    case absorbed do
      %{^group => into} -> final_step(into, absorbed)
      _not_absorbed -> group
    end
  end

  # One operation and what it decided, with steps named by task: compaction may rename a step, never its task.
  # A history of whole-grapheme edits, presses and undos, run with compaction off and with a budget of 3.
  defp emoji_twins(commands) do
    plain = world("", run_budget: 1_000_000, shadow: false)
    compacted = world("", run_budget: 3, shadow: false)

    apply = fn
      :undo, world -> twin_apply({:undo, 0, 0, "", 0}, world)
      :press, world -> twin_apply(:press, world)
      command, world -> {:edited, grapheme_op(command, world)}
    end

    twin_run(commands, plain, compacted, 5, apply)
  end

  defp slices_case(commands, cut, budget, slice) do
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

    {:done, world} = unwind(compacted)
    assert text(world) == "abc\ndef\n"
  end

  defp twin_apply(:press, world) do
    case UndoHistory.undo_agent_session(world.history, world.version, world.doc) do
      {:ok, restore, history, summary} ->
        # A merged step counts once, so the number of steps reverted is not compared; the text after it is.
        world =
          world
          |> install(restore, history)
          |> Map.put(:pressed, summary.groups)
          |> Map.put(:pressed_task, summary.task)

        {{:pressed, summary.held != nil}, world}

      {:blocked, overlap, task, _offset} ->
        {{:held, overlap, task}, world}

      other ->
        {other, world}
    end
  end

  defp twin_apply(:reject, world) do
    %{task_ticks: ticks} = world.history

    case ticks |> Map.keys() |> Enum.sort() do
      [] ->
        {:no_task, world}

      [task | _rest] ->
        case UndoHistory.reject_task(world.history, task, world.version, world.doc) do
          {:ok, restore, history, _count} -> {{:rejected, task}, install(world, restore, history)}
          {:blocked, {:overlaps, key}} -> {{:refused, task, task_name(key)}, world}
          other -> {other, world}
        end
    end
  end

  defp twin_apply({kind, _a, _b, _text, _n}, world) when kind in [:undo, :redo] do
    case step(world, kind) do
      {:ok, world, _restore} -> {{kind, :ok}, world}
      {:blocked, {:overlaps, key}} -> {{kind, :blocked, task_name(key)}, world}
      other -> {{kind, other}, world}
    end
  end

  defp twin_apply(command, world), do: {:edited, run(command, world)}

  defp task_name({:minga, task, _step}), do: task
  defp task_name(other), do: other

  # An edit, undo or press on whole graphemes, as the editor cuts text.
  defp grapheme_op({:undo, _a, _b, _text, _n}, world), do: step_or_keep(world, :undo)

  defp grapheme_op({:press, _a, _b, _text, _n}, world) do
    case UndoHistory.undo_agent_session(world.history, world.version, world.doc) do
      {:ok, restore, history, _summary} -> install(world, restore, history)
      _held_or_empty -> world
    end
  end

  defp grapheme_op({author, a, b, inserted, n}, world) do
    clusters = String.graphemes(text(world))
    offsets = clusters |> Enum.scan(0, &(byte_size(&1) + &2)) |> then(&[0 | &1])
    from = rem(a, length(offsets))
    to = min(from + b, length(offsets) - 1)
    start = Enum.at(offsets, from)
    removed = Enum.at(offsets, to) - start
    source = if author == :user, do: :user, else: {:minga, "task-#{rem(n, 2)}", "call-#{n}"}
    edit(world, source, start, removed, Enum.join(inserted), at: @t0 + world.version * @window)
  end

  defp assert_code_point_cuts(world) do
    content = text(world)

    cuts =
      content
      |> String.codepoints()
      |> Enum.scan(0, &(byte_size(&1) + &2))
      |> MapSet.new()
      |> MapSet.put(0)

    world.history
    |> UndoHistory.provenance()
    |> Provenance.runs()
    |> Enum.reduce(0, fn run, offset ->
      assert MapSet.member?(cuts, offset)

      if run.live do
        offset + run.bytes
      else
        assert String.valid?(run.text)
        offset
      end
    end)
  end

  defp step_or_keep(world, fun) do
    case step(world, fun) do
      {:ok, world, _restore} -> world
      _empty_or_blocked -> world
    end
  end

  # Presses SPC a u until Minga has no step left, undoing your newest edit whenever a press is held, as *Messages* tells
  # you to. Then undoes the rest of your edits. Every press is checked against the group-level model, and the whole
  # sequence must end within a bound: the termination guarantee.
  defp unwind(world) do
    world = drain(world, 400)
    %{task_ticks: ticks} = world.history
    assert ticks == %{}
    assert UnitModel.acyclic?(world.history)
    {:done, undo_all(world)}
  end

  defp drain(_world, 0), do: flunk("SPC a u and u did not finish")

  defp drain(world, fuel) do
    case press_reject(world) do
      {:ok, world, nil} -> drain(world, fuel - 1)
      {:ok, world, _held} -> drain(world, fuel - 1)
      :held -> world |> undo_newest() |> drain(fuel - 1)
      :empty -> world
    end
  end

  # When no task can revert a step, your newest edit can be undone: no Minga step is newer than the newest Minga step,
  # which is held by an edit of yours newer still.
  defp undo_newest(world) do
    case step(world, :undo) do
      {:ok, world, _restore} -> world
      other -> flunk("held, but your undo gave #{inspect(other)}")
    end
  end

  defp undo_all(world) do
    case step(world, :undo) do
      {:ok, world, _restore} -> undo_all(world)
      :empty -> world
      other -> flunk("with no Minga step left, your undo gave #{inspect(other)}")
    end
  end

  defp reject_all(world), do: {:done, drain(world, 400)}

  # One press of SPC a u: what it reverts is exact for the group-level model, the document equals the model's, and no
  # text you wrote that was visible goes.
  defp press_reject(world) do
    case UndoHistory.undo_agent_session(world.history, world.version, world.doc) do
      {:ok, restore, history, summary} ->
        assert UnitModel.exact_groups?(world.history, summary.groups)
        after_world = install(world, restore, history)

        assert text(after_world) ==
                 UnitModel.reverted_groups_text(world.history, text(world), summary.groups)

        assert your_text(world) |> subsequence?(your_text(after_world))
        assert UnitModel.acyclic?(history)

        Process.put(
          :multi_units,
          Process.get(:multi_units, 0) + if(match?([_, _ | _], summary.groups), do: 1, else: 0)
        )

        {:ok, after_world, summary.held}

      :empty ->
        :empty

      {:blocked, {:overlaps, :you}, _task, _offset} ->
        Process.put(:stuck, Process.get(:stuck, 0) + 1)
        :held
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
      world = shadow(%{world | history: history})

      if status == :more do
        compact_fully(world, slice)
      else
        %{run_budget: budget} = history
        # Drafts may remain whose merge is refused around an edit of yours; none is left to merge.
        assert result.runs <= div(budget * 3, 4) or
                 Provenance.compact_oldest(
                   history.provenance,
                   &UndoHistory.merge_class(history, &1)
                 ) ==
                   :none

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
