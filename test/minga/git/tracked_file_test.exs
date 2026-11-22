defmodule Minga.Git.TrackedFileTest do
  # Uses the real tracker lookup table and the globally configured test backend.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Git
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Stub
  alias Minga.Git.TrackedFile
  alias Minga.Git.Tracker

  @moduletag :tmp_dir

  test "captures current buffer text, cursor and version against the exact cached HEAD", %{
    tmp_dir: root
  } do
    path = "file.txt"
    base = "first\nbefore\ndeleted\nkeep\nold"
    revised = "first\nbefore\nkeep\nnew"
    {buffer, tracker} = track_buffer(root, path, base, base)

    assert Git.hunks(tracker) == []
    next_base = "changed HEAD\n"
    Stub.set_head(root, path, next_base)
    {^base, version} = Buffer.content_with_version(buffer)
    assert {:ok, edited_version} = Buffer.replace_content_if_version(buffer, version, revised)
    assert :ok = Buffer.move_to(buffer, {1, 2})

    assert {:ok,
            %TrackedFile{
              root: ^root,
              path: ^path,
              base: ^base,
              content: ^revised,
              version: ^edited_version,
              cursor: {1, 2},
              hunks: [%{type: :deleted} = deletion, %{type: :modified} = modification] = hunks
            }} = Git.tracked_file(buffer)

    assert Git.change_at(hunks, 1) == deletion
    assert Git.change_at(hunks, 2) == deletion
    assert Git.change_at(hunks, 3) == modification
    assert Git.neighbor_change_line(hunks, 0, :next) == 1
    assert Git.neighbor_change_line(hunks, 1, :next) == 3
    assert Git.neighbor_change_line(hunks, 3, :previous) == 1
    assert Git.neighbor_change_line(hunks, 1, :previous) == nil
    assert Git.revert_change(revised, deletion) == "first\nbefore\ndeleted\nkeep\nnew"
    assert Git.hunks(tracker) == []

    :ok = GitBuffer.invalidate_base(tracker, revised)

    assert {:ok, %TrackedFile{base: ^next_base, content: ^revised, version: ^edited_version}} =
             Git.tracked_file(buffer)
  end

  test "keeps an absent HEAD distinct from empty text for a new file", %{tmp_dir: root} do
    {buffer, _tracker} = track_buffer(root, "new.txt", nil, "new text\n")

    assert {:ok, %TrackedFile{base: nil, content: "new text\n", hunks: [added]}} =
             Git.tracked_file(buffer)

    assert added.type == :added
    assert Git.revert_change("new text\n", added) == ""
  end

  test "does not reuse the previous repository target after the file is retargeted", %{
    tmp_dir: root
  } do
    {buffer, _tracker} = track_buffer(root, "before.txt", "base", "updated")
    assert :ok = Buffer.retarget_path(buffer, Path.join(root, "after.txt"))
    assert Git.tracked_file(buffer) == :not_tracked
  end

  test "rejects a changed canonical target even before the tracker can rebind", %{tmp_dir: root} do
    {buffer, _tracker} = track_buffer(root, "alias.txt", "old HEAD\n", "old contents\n")
    alias_path = Buffer.file_path(buffer)
    target = Path.join(root, "new-target.txt")
    File.write!(target, "new contents\n")
    File.rm!(alias_path)
    File.ln_s!(target, alias_path)

    # This buffer's events are private: it still has the old mapping.
    assert :ok = Buffer.reload(buffer)
    assert Buffer.file_path(buffer) == alias_path
    assert Buffer.content(buffer) == "new contents\n"
    assert Git.tracked_file(buffer) == :not_tracked
  end

  test "returns not tracked for an unmapped buffer and not Git for a missing path" do
    assert Git.tracked_file(self()) == :not_tracked
    assert Git.root_for(nil) == :not_git
  end

  defp track_buffer(root, path, base, content) do
    registry = :"tracked_file_events_#{System.unique_integer([:positive])}"
    start_supervised!({Events, name: registry})
    file_path = Path.join(root, path)
    File.write!(file_path, content)
    if base != nil, do: Stub.set_head(root, path, base)

    buffer =
      start_supervised!({BufferProcess, file_path: file_path, events_registry: registry})

    tracker =
      start_supervised!(
        {GitBuffer, git_root: root, file_path: file_path, initial_content: content}
      )

    Tracker.put_mapping(buffer, tracker)

    on_exit(fn ->
      Tracker.remove_mapping(buffer)
      Stub.clear(root)
    end)

    {buffer, tracker}
  end
end
