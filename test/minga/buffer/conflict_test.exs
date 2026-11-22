defmodule Minga.Buffer.ConflictTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Events

  @diff3 "<<<<<<< ours\ncurrent\n||||||| base\nancestor\n=======\nincoming\n>>>>>>> theirs"
  @empty_current "<<<<<<< ours\n=======\ntheirs\n>>>>>>> theirs"

  @tag :tmp_dir
  test "partial and final resolutions report their revision, clamp the cursor, and notify the edit path",
       %{tmp_dir: tmp_dir} do
    registry = Module.concat(__MODULE__, "Events#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    :ok = Events.subscribe(:buffer_changed, registry)

    path = Path.join(tmp_dir, "conflicted.txt")
    content = "header\n#{@diff3}\nseparator\n#{@empty_current}"
    File.write!(path, content)
    buffer = start_supervised!({Buffer, file_path: path, events_registry: registry})
    assert :ok = Buffer.move_to(buffer, {2, 3})

    assert %{
             version: original_version,
             cursor: {2, 3},
             entries: [%{start_line: 1, end_line: 7}, %{start_line: 9, end_line: 12}]
           } = Buffer.conflict_view(buffer)

    assert {:ok, %{version: partial_version, remaining: 1}} =
             Buffer.resolve_conflict(buffer, original_version, {:cursor, 2}, :both)

    assert partial_version > original_version
    assert Buffer.content(buffer) == "header\ncurrent\nincoming\nseparator\n#{@empty_current}"
    assert File.read!(path) == content

    assert_receive {:minga_event, :buffer_changed,
                    %Events.BufferChangedEvent{
                      buffer: ^buffer,
                      version: ^partial_version,
                      source: :user
                    }}

    assert %{
             version: ^partial_version,
             cursor: {2, 0},
             entries: [%{start_line: 4, end_line: 7} = last]
           } = Buffer.conflict_view(buffer)

    assert {:ok, %{version: final_version, remaining: 0}} =
             Buffer.resolve_conflict(buffer, partial_version, {:region, last}, :current)

    assert final_version > partial_version
    assert %{version: ^final_version, cursor: {3, 0}, entries: []} = Buffer.conflict_view(buffer)
    assert Buffer.content(buffer) == "header\ncurrent\nincoming\nseparator"
    assert File.read!(path) == content

    assert_receive {:minga_event, :buffer_changed,
                    %Events.BufferChangedEvent{
                      buffer: ^buffer,
                      version: ^final_version,
                      source: :user
                    }}

    assert {:error, :stale} = Buffer.save_if_version(buffer, partial_version)
    assert File.read!(path) == content
    assert :ok = Buffer.save_if_version(buffer, final_version)
    assert File.read!(path) == "header\ncurrent\nincoming\nseparator"
  end

  test "a stale selection cannot resolve a conflict with unchanged coordinates" do
    buffer = start_supervised!({Buffer, content: @diff3})
    assert %{version: stale_version, entries: [entry]} = Buffer.conflict_view(buffer)

    assert :ok = Buffer.move_to(buffer, {1, 0})
    assert :ok = Buffer.insert_text(buffer, "edited ")
    content = String.replace(@diff3, "\ncurrent\n", "\nedited current\n")
    assert %{version: version, entries: [^entry]} = after_edit = Buffer.conflict_view(buffer)

    assert {:error, :stale} =
             Buffer.resolve_conflict(buffer, stale_version, {:region, entry}, :incoming)

    assert {:error, :not_found} =
             Buffer.resolve_conflict(buffer, version, {:cursor, 7}, :incoming)

    assert {:error, :not_found} =
             Buffer.resolve_conflict(
               buffer,
               version,
               {:region, %{entry | end_line: 5}},
               :incoming
             )

    assert Buffer.conflict_view(buffer) == after_edit
    assert Buffer.content(buffer) == content

    assert {:ok, %{remaining: 0}} =
             Buffer.resolve_conflict(buffer, version, {:region, entry}, :incoming)

    assert Buffer.content(buffer) == "incoming"
  end

  test "read-only buffers reject resolution without changing the conflict or cursor" do
    buffer = start_supervised!({Buffer, content: @diff3, read_only: true})
    assert %{version: version, entries: [entry]} = view = Buffer.conflict_view(buffer)

    assert {:error, :read_only} =
             Buffer.resolve_conflict(buffer, version, {:region, entry}, :both)

    assert Buffer.conflict_view(buffer) == view
    assert Buffer.content(buffer) == @diff3
  end
end
