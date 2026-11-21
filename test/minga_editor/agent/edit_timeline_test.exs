defmodule MingaEditor.Agent.EditTimelineTest do
  use ExUnit.Case, async: true

  alias Minga.Git
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.FileChange

  describe "new/0" do
    test "creates empty timeline" do
      timeline = EditTimeline.new()
      assert timeline.entries == %{}
      assert timeline.cumulative_hunks == %{}
      assert timeline.viewing == %{}
    end
  end

  describe "record_edit/2" do
    test "records first edit cumulative hunks" do
      before = "before"
      after_ = "after1"

      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", before, after_))

      assert EditTimeline.cumulative_hunks(timeline, "lib/foo.ex") ==
               Git.diff_lines(String.split(before, "\n"), String.split(after_, "\n"))
    end

    test "does not overwrite the original projection on subsequent edits" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "before", "after1"))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc2", "after1", "after2"))

      latest_lines = String.split("after2", "\n")
      first_before_lines = String.split("before", "\n")

      assert reconstruct_first_before(timeline, "lib/foo.ex", latest_lines) == first_before_lines
    end

    test "an intervening human edit disables cumulative rollback without dropping entries" do
      path = "lib/foo.ex"

      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change(path, "tc1", "before\n", "agent\n"))
        |> EditTimeline.record_edit(file_change(path, "tc2", "human\nagent\n", "human\nnew\n"))
        |> EditTimeline.record_edit(file_change(path, "tc3", "human\nnew\n", "human\nlatest\n"))

      assert EditTimeline.discontinuous?(timeline, path)
      assert EditTimeline.cumulative_hunks(timeline, path) == []
      assert {:ok, "human\nlatest\n"} = EditTimeline.content_at(timeline, path, 2)
    end

    test "an edit to a recovered file keeps one row without claiming partial line totals" do
      path = "lib/recovered.ex"

      timeline =
        EditTimeline.new()
        |> EditTimeline.recover_files(%{path => 3})
        |> EditTimeline.record_edit(file_change(path, "tc4", "restored\n", "new edit\n"))

      assert [%{path: ^path, review_status: :counts_unavailable}] =
               EditTimeline.file_summaries(timeline)
    end

    test "records entries in order" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc2", "v1", "v2", "write_file"))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc3", "v2", "v3"))

      entries = EditTimeline.entries_for(timeline, "lib/foo.ex")
      assert Enum.count(entries) == 3
      assert Enum.map(entries, & &1.index) == [0, 1, 2]
      assert Enum.map(entries, & &1.tool_call_id) == ["tc1", "tc2", "tc3"]
      assert Enum.map(entries, & &1.tool_name) == ["edit_file", "write_file", "edit_file"]
    end

    test "tracks entries and hunk projections per file independently" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/a.ex", "tc1", "a0", "a1"))
        |> EditTimeline.record_edit(file_change("lib/b.ex", "tc2", "b0", "b1"))
        |> EditTimeline.record_edit(file_change("lib/a.ex", "tc3", "a1", "a2"))

      assert EditTimeline.entry_count(timeline, "lib/a.ex") == 2
      assert EditTimeline.entry_count(timeline, "lib/b.ex") == 1
      assert reconstruct_first_before(timeline, "lib/a.ex", ["a2"]) == ["a0"]
      assert reconstruct_first_before(timeline, "lib/b.ex", ["b1"]) == ["b0"]
    end

    test "stores empty cumulative hunks when latest content returns to baseline" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/a.ex", "tc1", "a0", "a1"))
        |> EditTimeline.record_edit(file_change("lib/b.ex", "tc2", "b0", "b1"))
        |> EditTimeline.record_edit(file_change("lib/a.ex", "tc3", "a1", "a0"))

      assert EditTimeline.cumulative_hunks(timeline, "lib/a.ex") == []

      assert [a_summary, _b_summary] = EditTimeline.file_summaries(timeline)
      assert a_summary.path == "lib/a.ex"
      assert a_summary.lines_added == 0
      assert a_summary.lines_removed == 0
    end

    test "reverse hunk order reconstructs the first baseline for separated edits" do
      before = "top\nold upper\nmiddle\nold lower\nbottom"
      after_first = "inserted\ntop\nnew upper\nmiddle\nold lower\nbottom"
      after_second = "inserted\ntop\nnew upper\nmiddle\nnew lower\nbottom\nextra"

      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", before, after_first))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc2", after_first, after_second))

      hunks = EditTimeline.cumulative_hunks(timeline, "lib/foo.ex")
      latest_lines = String.split(after_second, "\n")
      first_before_lines = String.split(before, "\n")

      refute Enum.reduce(hunks, latest_lines, &Git.revert_hunk(&2, &1)) == first_before_lines

      assert Enum.reduce(Enum.reverse(hunks), latest_lines, &Git.revert_hunk(&2, &1)) ==
               first_before_lines
    end

    test "file-backed entry snapshots are not read when recording chained edits or summaries" do
      after_a1 = oversize_content("a1")
      after_a2 = oversize_content("a2")
      after_b1 = oversize_content("b1")

      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/a.ex", "tc1", "a0", after_a1))
        |> EditTimeline.record_edit(file_change("lib/b.ex", "tc2", "b0", after_b1))

      [%{snapshot: {:file, path}} | _] = EditTimeline.entries_for(timeline, "lib/a.ex")
      File.rm!(path)

      timeline =
        EditTimeline.record_edit(timeline, file_change("lib/a.ex", "tc3", after_a1, after_a2))

      on_exit(fn -> EditTimeline.reset(timeline) end)

      assert reconstruct_first_before(timeline, "lib/a.ex", String.split(after_a2, "\n")) == [
               "a0"
             ]

      assert [%{path: "lib/a.ex"}, %{path: "lib/b.ex"}] = EditTimeline.file_summaries(timeline)
    end
  end

  describe "reproject/4" do
    test "replaces only the selected path cumulative hunks" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/a.ex", "tc1", "a0", "a1"))
        |> EditTimeline.record_edit(file_change("lib/b.ex", "tc2", "b0", "b1"))
        |> EditTimeline.set_viewing("lib/a.ex", 0)

      b_hunks = EditTimeline.cumulative_hunks(timeline, "lib/b.ex")

      timeline = EditTimeline.reproject(timeline, "lib/a.ex", ["a0"], ["a2"])

      assert EditTimeline.cumulative_hunks(timeline, "lib/a.ex") == Git.diff_lines(["a0"], ["a2"])
      assert EditTimeline.cumulative_hunks(timeline, "lib/b.ex") == b_hunks

      assert Enum.map(EditTimeline.entries_for(timeline, "lib/a.ex"), & &1.tool_call_id) == [
               "tc1"
             ]

      assert EditTimeline.viewing_index(timeline, "lib/a.ex") == 0
    end
  end

  describe "retained old_lines" do
    test "record_edit and reproject detach changed large old_lines from source binaries" do
      old_line = String.duplicate("x", 128)
      before_content = "prefix\n" <> old_line <> "\nsuffix"
      after_content = "prefix\nnew\nsuffix"
      original_lines = String.split(before_content, "\n")
      materialized_lines = String.split(after_content, "\n")
      input_old_line = Enum.at(original_lines, 1)

      assert input_old_line == old_line
      assert :binary.referenced_byte_size(input_old_line) > byte_size(input_old_line)

      cases = [
        record_edit: fn ->
          EditTimeline.new()
          |> EditTimeline.record_edit(
            file_change("lib/a.ex", "tc1", before_content, after_content)
          )
          |> EditTimeline.cumulative_hunks("lib/a.ex")
        end,
        reproject: fn ->
          EditTimeline.new()
          |> EditTimeline.reproject("lib/a.ex", original_lines, materialized_lines)
          |> EditTimeline.cumulative_hunks("lib/a.ex")
        end
      ]

      for {_path, get_hunks} <- cases, hunks = get_hunks.() do
        assert [%{old_lines: [stored]}] = hunks
        assert stored == old_line
        assert :binary.referenced_byte_size(stored) == byte_size(stored)
      end
    end
  end

  describe "content_at/3" do
    test "returns content at a specific index" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc2", "v1", "v2"))

      assert {:ok, "v1"} = EditTimeline.content_at(timeline, "lib/foo.ex", 0)
      assert {:ok, "v2"} = EditTimeline.content_at(timeline, "lib/foo.ex", 1)
    end

    test "returns error for invalid index" do
      timeline = EditTimeline.new()
      assert :error = EditTimeline.content_at(timeline, "lib/foo.ex", 0)
    end
  end

  describe "navigate_next/2" do
    test "moves from live to live with at_end when already at end" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))

      {_timeline, result} = EditTimeline.navigate_next(timeline, "lib/foo.ex")
      assert result == :at_end
    end

    test "moves forward through entries" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc2", "v1", "v2"))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc3", "v2", "v3"))

      timeline = EditTimeline.set_viewing(timeline, "lib/foo.ex", 0)

      {timeline, :moved} = EditTimeline.navigate_next(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == 1

      {timeline, :moved} = EditTimeline.navigate_next(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == 2

      {timeline, :at_end} = EditTimeline.navigate_next(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == nil
    end

    test "returns no_entries for empty path" do
      timeline = EditTimeline.new()
      {_timeline, :no_entries} = EditTimeline.navigate_next(timeline, "lib/nope.ex")
    end
  end

  describe "navigate_prev/2" do
    test "moves from live to last entry" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc2", "v1", "v2"))

      {timeline, :moved} = EditTimeline.navigate_prev(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == 1
    end

    test "moves backward through entries" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc2", "v1", "v2"))

      timeline = EditTimeline.set_viewing(timeline, "lib/foo.ex", 1)
      {timeline, :moved} = EditTimeline.navigate_prev(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == 0
    end

    test "returns at_baseline when at first entry" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))

      timeline = EditTimeline.set_viewing(timeline, "lib/foo.ex", 0)
      {_timeline, :at_baseline} = EditTimeline.navigate_prev(timeline, "lib/foo.ex")
    end

    test "returns no_entries for empty path" do
      timeline = EditTimeline.new()
      {_timeline, :no_entries} = EditTimeline.navigate_prev(timeline, "lib/nope.ex")
    end
  end

  describe "go_live/2" do
    test "clears viewing index" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))

      timeline = EditTimeline.set_viewing(timeline, "lib/foo.ex", 0)
      timeline = EditTimeline.go_live(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == nil
    end
  end

  describe "has_entries?/2" do
    test "returns false for paths with no entries" do
      refute EditTimeline.has_entries?(EditTimeline.new(), "lib/foo.ex")
    end

    test "returns true for paths with entries" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))

      assert EditTimeline.has_entries?(timeline, "lib/foo.ex")
    end
  end

  describe "adjacent_path/3" do
    test "wraps in first-seen order even if a file returns to its baseline" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("b", "tc1", "before", "after"))
        |> EditTimeline.record_edit(file_change("a", "tc2", "before", "after"))
        |> EditTimeline.record_edit(file_change("c", "tc3", "before", "after"))
        |> EditTimeline.record_edit(file_change("b", "tc4", "after", "before"))
        |> EditTimeline.reproject("unrecorded", ["before"], ["after"])

      for {selected, next, previous} <- [
            {"b", "a", "c"},
            {"a", "c", "b"},
            {"c", "b", "a"},
            {nil, "b", "c"},
            {"unrecorded", "b", "c"}
          ] do
        assert EditTimeline.adjacent_path(timeline, selected, :next) == next
        assert EditTimeline.adjacent_path(timeline, selected, :previous) == previous
      end
    end

    test "cycles first-seen live files and then sorted recovered-only files without duplicates" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.recover_files(%{"a" => 2, "d" => 1, "z" => 3})
        |> EditTimeline.record_edit(file_change("z", "tc1", "before", "after"))
        |> EditTimeline.record_edit(file_change("b", "tc2", "before", "after"))

      for {selected, next, previous} <- [
            {nil, "z", "d"},
            {"z", "b", "d"},
            {"b", "a", "z"},
            {"a", "d", "b"},
            {"d", "z", "a"},
            {"stale", "z", "d"}
          ] do
        assert EditTimeline.adjacent_path(timeline, selected, :next) == next
        assert EditTimeline.adjacent_path(timeline, selected, :previous) == previous
      end
    end

    test "cycles recovered files when there are no live entries" do
      timeline = EditTimeline.recover_files(EditTimeline.new(), %{"d" => 1, "a" => 2})

      assert EditTimeline.adjacent_path(timeline, nil, :next) == "a"
      assert EditTimeline.adjacent_path(timeline, nil, :previous) == "d"
      assert EditTimeline.adjacent_path(timeline, "d", :next) == "a"
      assert EditTimeline.adjacent_path(timeline, "a", :previous) == "d"
    end

    test "wraps to the same file until the timeline is reset" do
      timeline = EditTimeline.record_edit(EditTimeline.new(), file_change("a", "tc1", "0", "1"))
      cleared = EditTimeline.reset(timeline)

      for direction <- [:next, :previous] do
        assert EditTimeline.adjacent_path(timeline, "a", direction) == "a"
        assert EditTimeline.adjacent_path(cleared, "a", direction) == nil
      end
    end
  end

  describe "file_summaries/1" do
    test "offers Review for a single changed file" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/a.ex", "tc1", "old\n", "new\n"))

      assert [%{path: "lib/a.ex", entry_count: 1, lines_added: 1, lines_removed: 1}] =
               EditTimeline.file_summaries(timeline)
    end

    test "keeps first-seen file order and does not infer review selection from history navigation" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/b.ex", "tc1", "one\n", "one\ntwo\n"))
        |> EditTimeline.record_edit(file_change("lib/a.ex", "tc2", "old\n", "new\n"))
        |> EditTimeline.set_viewing("lib/a.ex", 0)

      assert [
               %{
                 path: "lib/b.ex",
                 entry_count: 1,
                 lines_added: 1,
                 lines_removed: 0,
                 review_status: :pending
               },
               %{
                 path: "lib/a.ex",
                 entry_count: 1,
                 lines_added: 1,
                 lines_removed: 1,
                 review_status: :pending
               }
             ] = EditTimeline.file_summaries(timeline)
    end
  end

  describe "reset/1" do
    test "cleans up memory-backed snapshots and clears timeline state" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc1", "v0", "v1"))
        |> EditTimeline.record_edit(file_change("lib/foo.ex", "tc2", "v1", "v2"))
        |> EditTimeline.set_viewing("lib/foo.ex", 0)

      reset = EditTimeline.reset(timeline)
      assert reset.entries == %{}
      assert reset.cumulative_hunks == %{}
      assert reset.viewing == %{}
      assert reset.generation != timeline.generation
    end

    test "cleans up file-backed entry snapshots" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(
          file_change("lib/foo.ex", "tc1", "v0", oversize_content("v1"))
        )

      [%{snapshot: {:file, path}}] = EditTimeline.entries_for(timeline, "lib/foo.ex")
      assert File.exists?(path)
      reset = EditTimeline.reset(timeline)
      assert reset.entries == %{}
      assert reset.generation != timeline.generation
      refute File.exists?(path)
    end
  end

  describe "stable GUI targets" do
    test "entry identity binds path, tool call and index, not viewing or review state" do
      path = "lib/foo.ex"

      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit(file_change(path, "tc1", "v0", "v1"))

      [entry] = EditTimeline.entries_for(timeline, path)
      id = EditTimeline.entry_id(path, entry)
      assert id == EditTimeline.entry_id(path, entry)
      assert id != EditTimeline.entry_id("lib/other.ex", entry)
      assert id != EditTimeline.entry_id(path, %{entry | tool_call_id: "tc2"})
      assert id != EditTimeline.entry_id(path, %{entry | index: 1})

      viewed = EditTimeline.set_viewing(timeline, path, 0)
      live = EditTimeline.go_live(viewed, path)
      reprojected = EditTimeline.reproject(live, path, ["v0"], ["v0"])
      assert reprojected.generation == timeline.generation
      assert [^entry] = EditTimeline.entries_for(reprojected, path)
      assert EditTimeline.entry_id(path, hd(EditTimeline.entries_for(reprojected, path))) == id
    end

    test "entry mutations and resets invalidate generations even when identities repeat" do
      path = "lib/foo.ex"
      empty = EditTimeline.new()
      first = EditTimeline.record_edit(empty, file_change(path, "tc1", "v0", "v1"))
      second = EditTimeline.record_edit(first, file_change(path, "tc2", "v1", "v2"))
      reset = EditTimeline.reset(second)
      repeated = EditTimeline.record_edit(reset, file_change(path, "tc1", "v0", "v1"))

      generations = Enum.map([empty, first, second, reset, repeated], & &1.generation)
      assert Enum.uniq(generations) == generations
      [entry] = EditTimeline.entries_for(first, path)
      [repeated_entry] = EditTimeline.entries_for(repeated, path)
      assert EditTimeline.entry_id(path, repeated_entry) == EditTimeline.entry_id(path, entry)
      assert hd(EditTimeline.entries_for(second, path)) == entry
    end
  end

  defp file_change(path, tool_call_id, before_content, after_content, tool_name \\ "edit_file") do
    %FileChange{
      path: path,
      before_content: before_content,
      after_content: after_content,
      tool_call_id: tool_call_id,
      tool_name: tool_name
    }
  end

  defp reconstruct_first_before(timeline, path, latest_lines) do
    timeline
    |> EditTimeline.cumulative_hunks(path)
    |> Enum.reverse()
    |> Enum.reduce(latest_lines, &Git.revert_hunk(&2, &1))
  end

  defp oversize_content(prefix) do
    prefix <> "\n" <> String.duplicate("x", Minga.Config.get(:agent_diff_size_threshold) + 1)
  end
end
