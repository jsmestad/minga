defmodule Minga.Buffer.AttributedEditsTest do
  @moduledoc """
  Every path that lets Minga edit an open buffer records the edit as one step with one change per changed region, attributed to Minga's author key.

  Each test edits a buffer through one entry path and a twin buffer through the whole-buffer replacement the path used before, then checks that the user sees no difference: content, cursor, version, dirty state, decorations, and the change event, before and after undo and redo.
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
    assert_attributed_like_whole(buffer, twin, 3)
  end

  test "a fork publication (merge_fork) records the fork's latest Minga step", ctx do
    {parent, twin} = start_pair(ctx, @old)
    fork = start_supervised!({Fork, parent: parent, content: @old})
    earlier = EditSource.minga("task-1", "call-0")

    mutate_fork(fork, "ALPHA\n" <> binary_part(@old, 6, byte_size(@old) - 6), earlier)
    mutate_fork(fork, @new, @minga)

    assert {:ok, @new} = Fork.publish(fork)

    replace_whole(twin, @new)
    assert_attributed_like_whole(parent, twin, 3)
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

    replace_whole(twin, @new)
    assert_attributed_like_whole(parent, twin, 3)
  end

  test "an agent workspace edit on a live buffer (replace_content_if_version) records three changes",
       ctx do
    {buffer, twin} = start_pair(ctx, @old)
    version = BufferProcess.version(buffer)

    assert {:ok, _version} =
             BufferProcess.replace_content_if_version(buffer, version, @new, @minga)

    replace_whole(twin, @new)
    assert_attributed_like_whole(buffer, twin, 3)
  end

  test "find_and_replace records its single change under the author key", ctx do
    {buffer, _twin} = start_pair(ctx, @old)

    assert {:ok, _message} = BufferProcess.find_and_replace(buffer, "beta", "BETA", @minga)
    assert BufferProcess.content(buffer) == String.replace(@old, "beta", "BETA")
    assert {[_one_change], @minga} = last_entry(buffer)

    assert_receive {:minga_event, :buffer_changed,
                    %BufferChangedEvent{buffer: ^buffer, source: @minga}}
  end

  test "an unattributed fork publishes under the legacy :agent source", ctx do
    {parent, _twin} = start_pair(ctx, @old)
    fork = start_supervised!({Fork, parent: parent, content: @old})
    assert :ok = Fork.replace_content(fork, @new)

    assert {:ok, @new} = Fork.publish(fork)
    assert {[_, _, _], :agent} = last_entry(parent)
  end

  test "the user's review edits on a fork never become its author", ctx do
    {parent, _twin} = start_pair(ctx, @old)
    fork = start_supervised!({Fork, parent: parent, content: @old})
    mutate_fork(fork, @new, @minga)
    mutate_fork(fork, @new <> "reviewed\n", :user)

    assert {:ok, _merged} = Fork.publish(fork)
    assert {_changes, @minga} = last_entry(parent)
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

  defp assert_attributed_like_whole(buffer, twin, change_count) do
    assert {changes, @minga} = last_entry(buffer)
    assert length(changes) == change_count
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

    for step <- [&BufferProcess.undo/1, &BufferProcess.redo/1] do
      assert :ok = step.(buffer)
      assert :ok = step.(twin)
      assert observable(buffer) == observable(twin)
    end
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

  # The newest undo entry is the edit record under test: its per-change patches and source.
  defp last_entry(buffer) do
    %{undo_history: %{undo_entries: [{_version, patches, source} | _]}} = :sys.get_state(buffer)
    {patches, source}
  end
end
