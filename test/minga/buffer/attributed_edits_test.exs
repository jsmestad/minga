defmodule Minga.Buffer.AttributedEditsTest do
  @moduledoc """
  Every path that lets Minga edit an open buffer records the edit as one step with one change per changed region, attributed to Minga's author key.

  Each test edits a buffer through one entry path and a twin buffer through the whole-buffer replacement the path used before, then checks that the user sees no difference: content, cursor, version, dirty state, decorations, and the change event. Then it checks that the step is Minga's: your undo leaves it in place, and reverting the task restores the text from before it.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.EditSource
  alias Minga.Buffer.FileMutation
  alias Minga.Buffer.Fork
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Events
  alias Minga.Events.BufferChangedEvent

  @minga EditSource.minga("task-1", "call-1")

  # Three changed regions separated by unchanged lines, and a cursor on an unchanged line.
  @old "alpha\nkeep one\nbeta\nkeep two\ngamma\nkeep three\n"
  @new "ALPHA\nkeep one\nbeta 1\nbeta 2\nkeep two\nkeep three\n"
  @cursor {3, 4}

  setup do
    registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    :ok = Events.subscribe(:buffer_changed, registry)
    %{registry: registry}
  end

  test "conditional_mutate records three changes in one Minga step", ctx do
    {buffer, twin} = start_pair(ctx, @old)
    identity = {:buffer, "/attributed"}
    {content, version} = BufferProcess.content_with_version(buffer)
    expected = FileMutation.revision(content, version, identity)

    assert {:ok, %FileMutation.Receipt{after: @new}} =
             BufferProcess.conditional_mutate(
               buffer,
               expected,
               {:replace, @new},
               identity,
               @minga
             )

    replace_whole(twin, @new)
    assert_attributed_like_whole(buffer, twin, 3, @old)
  end

  test "a fork publication (merge_fork) records the fork's latest Minga step", ctx do
    {parent, twin} = start_pair(ctx, @old)
    fork = start_supervised!({Fork, parent: parent, content: @old})
    earlier = EditSource.minga("task-1", "call-0")

    mutate_fork(fork, "ALPHA\n" <> binary_part(@old, 6, byte_size(@old) - 6), earlier)
    mutate_fork(fork, @new, @minga)

    assert {:ok, @new} = Fork.publish(fork)

    replace_whole(twin, @new)
    assert_attributed_like_whole(parent, twin, 3, @old)
  end

  test "a merged fork keeps both original writers across a parent-only insertion" do
    original = "a\nspacer\nb\n"
    parent = start_supervised!({BufferProcess, content: original})
    fork = start_supervised!({Fork, parent: parent, content: original})
    later = EditSource.minga("task-2", "call-2")
    mutate_fork(fork, "αζ\nspacer\nb\n", @minga)
    mutate_fork(fork, "αβ\nspacer\nB\n", later)

    assert {_, [{0, 2, {@minga, first_at}}, {2, 2, {^later, second_at}} | _]} =
             Fork.staged_content(fork)

    assert :ok = BufferProcess.replace_content(parent, "human\n" <> original, :user)
    assert {:ok, "human\nαβ\nspacer\nB\n"} = Fork.publish(fork)
    version = BufferProcess.version(parent)

    assert BufferProcess.attribution_at(parent, {0, 0}, version) == nil

    assert BufferProcess.attribution_at(parent, {1, 0}, version) ==
             {{:minga, "task-1"}, @minga, first_at, :unreviewed}

    assert BufferProcess.attribution_at(parent, {1, 2}, version) ==
             {{:minga, "task-2"}, later, second_at, :unreviewed}

    assert {:ok, 1} = BufferProcess.undo_agent_session(parent)
    assert BufferProcess.content(parent) == "human\n" <> original
  end

  test "a multiline splice preserves an independent parent edit inside the rewritten text" do
    original = "left\nold\nright"
    parent = start_supervised!({BufferProcess, content: original})
    fork = start_supervised!({Fork, parent: parent, content: original})
    identity = {:fork, "/retained-line-in-splice"}
    expected = FileMutation.revision(original, 0, identity)

    assert {:ok, _} =
             Fork.conditional_mutate(
               fork,
               expected,
               {:edit, [{"left\nold", "left\nNEW"}]},
               identity,
               @minga
             )

    assert :ok = BufferProcess.replace_content(parent, "LEFT\nold\nright", :user)
    assert {:ok, "LEFT\nNEW\nright"} = Fork.publish(fork)
    version = BufferProcess.version(parent)

    assert nil == BufferProcess.attribution_at(parent, {0, 0}, version)

    assert {{:minga, "task-1"}, @minga, _, :unreviewed} =
             BufferProcess.attribution_at(parent, {1, 0}, version)

    assert {:ok, target, {:minga, "task-1"}, _} = Minga.Buffer.prepare_review(parent, :latest)
    assert {:ok, [{:rejected, _}]} = Minga.Buffer.decide_review(parent, target, :reject)
    assert BufferProcess.content(parent) == "LEFT\nold\nright"
  end

  test "appending a duplicate line does not move the parent's earlier writer to the new copy" do
    parent = start_supervised!({BufferProcess, content: "base"})
    assert {:ok, version} = BufferProcess.replace_content_if_version(parent, 0, "x", @minga)

    assert {{:minga, "task-1"}, @minga, first_at, :unreviewed} =
             BufferProcess.attribution_at(parent, {0, 0}, version)

    fork = start_supervised!({Fork, parent: parent, content: "x"})
    identity = {:fork, "/repeat-at-eof"}
    later = EditSource.minga("task-2", "append")
    expected = FileMutation.revision("x", 0, identity)

    assert {:ok, _} =
             Fork.conditional_mutate(fork, expected, {:edit, [{"", "x"}]}, identity, later)

    assert {"x\nx", [{1, 2, {^later, second_at}}]} = Fork.staged_content(fork)
    assert {:ok, "x\nx"} = Fork.publish(fork)
    version = BufferProcess.version(parent)

    assert BufferProcess.attribution_at(parent, {0, 0}, version) ==
             {{:minga, "task-1"}, @minga, first_at, :unreviewed}

    assert BufferProcess.attribution_at(parent, {1, 0}, version) ==
             {{:minga, "task-2"}, later, second_at, :unreviewed}

    assert {:ok, 1} = BufferProcess.undo_agent_session(parent)
    assert BufferProcess.content(parent) == "x"
  end

  test "a divergent parent keeps its earlier writer on the original copy of an appended duplicate" do
    original = "header\nspacer\nx"
    parent = start_supervised!({BufferProcess, content: "header\nspacer\nz"})
    assert {:ok, version} = BufferProcess.replace_content_if_version(parent, 0, original, @minga)

    assert {{:minga, "task-1"}, @minga, first_at, :unreviewed} =
             BufferProcess.attribution_at(parent, {2, 0}, version)

    fork = start_supervised!({Fork, parent: parent, content: original})
    identity = {:fork, "/duplicate-divergent-parent"}
    later = EditSource.minga("task-2", "append")
    expected = FileMutation.revision(original, 0, identity)

    assert {:ok, _} =
             Fork.conditional_mutate(fork, expected, {:edit, [{"", "x"}]}, identity, later)

    assert {_, [{_, 2, {^later, second_at}}]} = Fork.staged_content(fork)
    diverged = "human\nspacer\nx"
    assert :ok = BufferProcess.replace_content(parent, diverged, :user)
    assert {:ok, "human\nspacer\nx\nx"} = Fork.publish(fork)
    version = BufferProcess.version(parent)

    assert BufferProcess.attribution_at(parent, {2, 0}, version) ==
             {{:minga, "task-1"}, @minga, first_at, :unreviewed}

    assert BufferProcess.attribution_at(parent, {3, 0}, version) ==
             {{:minga, "task-2"}, later, second_at, :unreviewed}

    assert {:ok, 1} = BufferProcess.undo_agent_session(parent)
    assert BufferProcess.content(parent) == diverged
  end

  test "deleting the first of two equal rows blocks its user's Undo after merging" do
    parent = start_supervised!({BufferProcess, content: "start\nz\nx\nend"})
    original = "start\nx\nx\nend"
    assert :ok = BufferProcess.replace_content(parent, original, :user)
    fork = start_supervised!({Fork, parent: parent, content: original})
    identity = {:fork, "/delete-first-copy"}
    expected = FileMutation.revision(original, 0, identity)

    assert {:ok, _} =
             Fork.conditional_mutate(
               fork,
               expected,
               {:edit, [{"start\nx\n", "start\n"}]},
               identity,
               @minga
             )

    independent = EditSource.minga("independent", "edit-tail")
    version = BufferProcess.version(parent)

    assert {:ok, _} =
             BufferProcess.replace_content_if_version(
               parent,
               version,
               "start\nx\nx\nparent",
               independent
             )

    assert {:ok, "start\nx\nparent"} = Fork.publish(fork)
    assert BufferProcess.undo(parent) == {:blocked, {:overlaps, @minga}}
    assert BufferProcess.content(parent) == "start\nx\nparent"
  end

  for {decision, tail} <- [accepted: "fork", rejected: "human"] do
    test "#{decision} conflict keeps Undo for the inherited part of the line" do
      parent = start_supervised!({BufferProcess, content: "old tail\nkeep"})
      original = "mine tail\nkeep"
      assert :ok = BufferProcess.replace_content(parent, original, :user)
      fork = start_supervised!({Fork, parent: parent, content: original})
      mutate_fork(fork, "mine fork\nkeep", @minga)
      independent = EditSource.minga("independent", "edit-tail")
      version = BufferProcess.version(parent)

      assert {:ok, _} =
               BufferProcess.replace_content_if_version(
                 parent,
                 version,
                 "mine human\nkeep",
                 independent
               )

      assert {:ok, revision, _} = Fork.conflict_snapshot(fork)
      expected = "mine " <> unquote(tail) <> "\nkeep"

      assert {:ok, ^expected} =
               Fork.publish_resolution(fork, revision, [unquote(decision)], fn _, _ -> :ok end)

      assert :ok = BufferProcess.undo(parent)
      assert BufferProcess.content(parent) == "old " <> unquote(tail) <> "\nkeep"
    end
  end

  test "the selected append retains the inserted separator's writer across a rejected conflict" do
    original = "head\nlast"
    parent = start_supervised!({BufferProcess, content: original})
    fork = start_supervised!({Fork, parent: parent, content: original})
    identity = {:fork, "/selected-append"}
    expected = FileMutation.revision(original, 0, identity)

    assert {:ok, _} =
             Fork.conditional_mutate(fork, expected, {:edit, [{"", "added"}]}, identity, @minga)

    assert {"head\nlast\nadded", [{9, 6, {@minga, written_at}}]} = Fork.staged_content(fork)
    later = EditSource.minga("task-2", "edit-head")
    mutate_fork(fork, "fork\nlast\nadded", later)
    assert :ok = BufferProcess.replace_content(parent, "user\nlast", :user)
    assert {:ok, revision, _} = Fork.conflict_snapshot(fork)
    test_pid = self()

    assert {:ok, "user\nlast\nadded"} =
             Fork.publish_resolution(fork, revision, [:rejected], fn _, selected ->
               send(test_pid, {:staged, selected})
               :ok
             end)

    assert_received {:staged, {"head\nlast\nadded", origins}}

    assert Enum.any?(origins, fn {start, count, origin} ->
             start <= 9 and 9 < start + count and origin == {@minga, written_at}
           end)

    assert BufferProcess.attribution_at(parent, {1, 4}, BufferProcess.version(parent)) ==
             {{:minga, "task-1"}, @minga, written_at, :unreviewed}
  end

  test "a resolved fork (install_fork_resolution) records the fork's Minga step", ctx do
    {parent, twin} = start_pair(ctx, @old)
    fork = start_supervised!({Fork, parent: parent, content: @old})
    mutate_fork(fork, @new, @minga)

    # The human also rewrote the first line, so the first region conflicts.
    human = "human\n" <> binary_part(@old, 6, byte_size(@old) - 6)

    for buffer <- [parent, twin] do
      assert :ok = BufferProcess.replace_content(buffer, human, :user)
      assert :ok = BufferProcess.move_to(buffer, @cursor)
    end

    assert {:ok, revision, regions} = Fork.conflict_snapshot(fork)
    decisions = for {:conflict, fork, parent, _} <- regions, fork != parent, do: :accepted

    assert {:ok, @new} =
             Fork.publish_resolution(fork, revision, decisions, fn _ancestor, _selected ->
               :ok
             end)

    # Minga rewrote the line you had changed, so your undo of that change is refused.
    assert BufferProcess.undo(parent) == {:blocked, {:overlaps, @minga}}

    replace_whole(twin, @new)
    assert_attributed_like_whole(parent, twin, 3, human)
  end

  test "an agent workspace edit on a live buffer (replace_content_if_version) records three changes",
       ctx do
    {buffer, twin} = start_pair(ctx, @old)
    version = BufferProcess.version(buffer)

    assert {:ok, _version} =
             BufferProcess.replace_content_if_version(buffer, version, @new, @minga)

    replace_whole(twin, @new)
    assert_attributed_like_whole(buffer, twin, 3, @old)
  end

  test "find_and_replace records its single change under the author key", ctx do
    {buffer, _twin} = start_pair(ctx, @old)

    assert {:ok, _message} = BufferProcess.find_and_replace(buffer, "beta", "BETA", @minga)
    assert BufferProcess.content(buffer) == String.replace(@old, "beta", "BETA")
    assert [{@minga, [_one_change]}] = BufferProcess.minga_changes(buffer, "task-1")
    assert BufferProcess.author_at(buffer, {2, 0}) == {:minga, "task-1"}

    assert_receive {:minga_event, :buffer_changed,
                    %BufferChangedEvent{buffer: ^buffer, source: @minga}}
  end

  test "an unattributed fork publishes under the legacy :agent source", ctx do
    {parent, _twin} = start_pair(ctx, @old)
    fork = start_supervised!({Fork, parent: parent, content: @old})
    assert :ok = Fork.replace_content(fork, @new)

    assert {:ok, @new} = Fork.publish(fork)
    assert BufferProcess.author_at(parent, {0, 0}) == {:minga, :untasked}

    # The publication is not yours to undo, and it reverts as an agent edit.
    assert :ok = BufferProcess.undo(parent)
    assert BufferProcess.content(parent) == @new
    assert {:ok, 1} = BufferProcess.undo_agent_session(parent)
    assert BufferProcess.content(parent) == @old
  end

  test "the user's review edits on a fork never become its author", ctx do
    {parent, _twin} = start_pair(ctx, @old)
    fork = start_supervised!({Fork, parent: parent, content: @old})
    mutate_fork(fork, @new, @minga)
    mutate_fork(fork, @new <> "reviewed\n", :user)

    assert {:ok, _merged} = Fork.publish(fork)
    assert [{@minga, _regions}] = BufferProcess.minga_changes(parent, "task-1")
    assert BufferProcess.author_at(parent, {0, 0}) == {:minga, "task-1"}
  end

  # Starts the buffer under test and a twin with the same content, cursor and a decoration.
  defp start_pair(ctx, content) do
    for id <- [:attributed, :whole] do
      buffer =
        start_supervised!(
          {BufferProcess, content: content, events_registry: ctx.registry},
          id: id
        )

      assert :ok = BufferProcess.move_to(buffer, @cursor)

      :ok =
        BufferProcess.batch_decorations(buffer, fn decorations ->
          {_id, decorations} =
            Decorations.add_highlight(decorations, {0, 0}, {0, 3}, style: Face.new(fg: 0xFF0000))

          decorations
        end)

      buffer
    end
    |> List.to_tuple()
  end

  # The whole-buffer replacement every Minga entry path used before per-change recording.
  defp replace_whole(twin, content) do
    assert {:ok, _version} =
             BufferProcess.replace_content_if_version(
               twin,
               BufferProcess.version(twin),
               content,
               :user
             )
  end

  defp mutate_fork(fork, content, source) do
    {current, version} = Fork.content_with_version(fork)
    identity = {:fork, "/attributed"}
    expected = FileMutation.revision(current, version, identity)

    assert {:ok, _receipt} =
             Fork.conditional_mutate(fork, expected, {:replace, content}, identity, source)
  end

  defp assert_attributed_like_whole(buffer, twin, change_count, before) do
    assert [{@minga, regions}] = BufferProcess.minga_changes(buffer, "task-1")
    assert length(regions) == change_count
    assert observable(buffer) == observable(twin)

    # Both edits announce a full resync at the same version; only the source differs.
    version = BufferProcess.version(buffer)

    assert_receive {:minga_event, :buffer_changed,
                    %BufferChangedEvent{
                      buffer: ^buffer,
                      source: @minga,
                      delta: nil,
                      version: ^version
                    }}

    assert_receive {:minga_event, :buffer_changed,
                    %BufferChangedEvent{
                      buffer: ^twin,
                      source: :user,
                      delta: nil,
                      version: ^version
                    }}

    # Your undo never takes Minga's step back; reverting the task does, and keeps the cursor line.
    after_step = BufferProcess.content(buffer)
    assert BufferProcess.undo(buffer) in [:ok, {:blocked, {:overlaps, @minga}}]
    assert BufferProcess.content(buffer) == after_step

    assert {:ok, 1} = BufferProcess.undo_agent_session(buffer)
    assert BufferProcess.content(buffer) == before
    assert BufferProcess.minga_changes(buffer, "task-1") == []
  end

  defp observable(buffer) do
    %{
      content: BufferProcess.content(buffer),
      cursor: BufferProcess.cursor(buffer),
      version: BufferProcess.version(buffer),
      dirty: BufferProcess.dirty?(buffer),
      decorations: Decorations.empty?(BufferProcess.decorations(buffer))
    }
  end
end
