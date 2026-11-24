defmodule Minga.Buffer.UndoHistoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.UndoPatch

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

      assert {:ok, restore, history, 2} =
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

      {:ok, restore, _history, 1} =
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

      {:ok, restore, history, 1000} =
        UndoHistory.undo_agent_session(world.history, world.version, world.doc)

      assert restore.version == :advance
      assert Document.content(restore.document) == "task\n" <> String.duplicate("x", 100)
      assert [{@step_one, [{0, 5}]}] = UndoHistory.minga_changes(history, "task-1")

      assert history |> UndoHistory.provenance() |> Provenance.author_at(104) ==
               {:minga, :untasked}

      # The tasked step is never evicted and still reverts on its own.
      assert {:ok, _restore, _history, 1} =
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

    test "a task is blocked by a newer task that rewrote its text, and reverts after it" do
      world =
        world("axb\nq")
        |> edit(@step_one, 1, 1, "y")
        |> edit(@other_task, 1, 1, "w")
        |> edit(@step_two, 4, 1, "Q")

      assert UndoHistory.undo_agent_session(world.history, world.version, world.doc) ==
               {:blocked, {:overlaps, @other_task}}

      {:ok, restore, history, 1} =
        UndoHistory.reject_task(world.history, {:minga, "task-2"}, world.version, world.doc)

      world = install(world, restore, history)
      assert text(world) == "ayb\nQ"
      assert text(reject_newest_task(world)) == "axb\nq"
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
      check all(commands <- StreamData.list_of(command(), max_length: 40), max_runs: 200) do
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

    property "rejecting Minga's steps and undoing all of yours restores the original" do
      check all(commands <- StreamData.list_of(command(), max_length: 40), max_runs: 200) do
        world = Enum.reduce(commands, world("abc\ndef\n"), &run/2)
        assert text(unwind(world)) == "abc\ndef\n"
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  # A buffer as the history sees it: history, document and version, edited like the buffer process does.
  defp world(text),
    do: %{history: UndoHistory.new(Document.new(text)), doc: Document.new(text), version: 0}

  defp edit(world, source, start, removed_bytes, inserted, opts \\ []) do
    at = Keyword.get(opts, :at, @t0)
    removed = binary_part(Document.content(world.doc), start, removed_bytes)
    patch = UndoPatch.replacement(start, removed, inserted, Document.cursor(world.doc))

    history =
      if Keyword.get(opts, :force, false),
        do: UndoHistory.record_edit_force(world.history, world.version, patch, source, at),
        else: UndoHistory.record_edit(world.history, world.version, patch, source, at)

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
    {:ok, restore, history, _count} =
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

  # Undoes everything you did, rejecting the task that blocks you whenever one does.
  defp unwind(world) do
    case step(world, :undo) do
      {:ok, world, _restore} -> unwind(world)
      {:blocked, {:overlaps, key}} -> world |> reject!(task_of(key)) |> unwind()
      :empty -> reject_all(world)
    end
  end

  defp reject_all(world) do
    case UndoHistory.undo_agent_session(world.history, world.version, world.doc) do
      :empty -> world
      {:ok, restore, history, _count} -> reject_all(install(world, restore, history))
      {:blocked, {:overlaps, key}} -> world |> reject!(task_of(key)) |> reject_all()
    end
  end

  # Rejects a task, first rejecting any newer task that blocks it.
  defp reject!(world, task) do
    case UndoHistory.reject_task(world.history, task, world.version, world.doc) do
      {:ok, restore, history, _count} -> install(world, restore, history)
      {:blocked, {:overlaps, key}} -> world |> reject!(task_of(key)) |> reject!(task)
    end
  end

  defp task_of({:untasked, _n}), do: {:minga, :untasked}
  defp task_of({:minga, task, _step}), do: {:minga, task}

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
end
