defmodule MingaEditor.Agent.EditTimelineTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.EditTimeline

  describe "new/0" do
    test "creates empty timeline" do
      timeline = EditTimeline.new()
      assert timeline.entries == %{}
      assert timeline.baselines == %{}
      assert timeline.viewing == %{}
    end
  end

  describe "record_edit/6" do
    test "records baseline on first edit" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "before", "after1")

      assert {:ok, "before"} = EditTimeline.baseline_content(timeline, "lib/foo.ex")
    end

    test "does not overwrite baseline on subsequent edits" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "before", "after1")
        |> EditTimeline.record_edit("lib/foo.ex", "tc2", "edit_file", "after1", "after2")

      assert {:ok, "before"} = EditTimeline.baseline_content(timeline, "lib/foo.ex")
    end

    test "records entries in order" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")
        |> EditTimeline.record_edit("lib/foo.ex", "tc2", "write_file", "v1", "v2")
        |> EditTimeline.record_edit("lib/foo.ex", "tc3", "edit_file", "v2", "v3")

      entries = EditTimeline.entries_for(timeline, "lib/foo.ex")
      assert length(entries) == 3
      assert Enum.map(entries, & &1.index) == [0, 1, 2]
      assert Enum.map(entries, & &1.tool_call_id) == ["tc1", "tc2", "tc3"]
      assert Enum.map(entries, & &1.tool_name) == ["edit_file", "write_file", "edit_file"]
    end

    test "tracks entries per file independently" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/a.ex", "tc1", "edit_file", "a0", "a1")
        |> EditTimeline.record_edit("lib/b.ex", "tc2", "edit_file", "b0", "b1")
        |> EditTimeline.record_edit("lib/a.ex", "tc3", "edit_file", "a1", "a2")

      assert EditTimeline.entry_count(timeline, "lib/a.ex") == 2
      assert EditTimeline.entry_count(timeline, "lib/b.ex") == 1
    end
  end

  describe "content_at/3" do
    test "returns content at a specific index" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")
        |> EditTimeline.record_edit("lib/foo.ex", "tc2", "edit_file", "v1", "v2")

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
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")

      {_timeline, result} = EditTimeline.navigate_next(timeline, "lib/foo.ex")
      assert result == :at_end
    end

    test "moves forward through entries" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")
        |> EditTimeline.record_edit("lib/foo.ex", "tc2", "edit_file", "v1", "v2")
        |> EditTimeline.record_edit("lib/foo.ex", "tc3", "edit_file", "v2", "v3")

      # Start viewing at index 0
      timeline = %{timeline | viewing: %{"lib/foo.ex" => 0}}

      {timeline, :moved} = EditTimeline.navigate_next(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == 1

      {timeline, :moved} = EditTimeline.navigate_next(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == 2

      # At last entry, goes live
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
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")
        |> EditTimeline.record_edit("lib/foo.ex", "tc2", "edit_file", "v1", "v2")

      {timeline, :moved} = EditTimeline.navigate_prev(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == 1
    end

    test "moves backward through entries" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")
        |> EditTimeline.record_edit("lib/foo.ex", "tc2", "edit_file", "v1", "v2")

      timeline = %{timeline | viewing: %{"lib/foo.ex" => 1}}
      {timeline, :moved} = EditTimeline.navigate_prev(timeline, "lib/foo.ex")
      assert EditTimeline.viewing_index(timeline, "lib/foo.ex") == 0
    end

    test "returns at_baseline when at first entry" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")

      timeline = %{timeline | viewing: %{"lib/foo.ex" => 0}}
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
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")

      timeline = %{timeline | viewing: %{"lib/foo.ex" => 0}}
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
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")

      assert EditTimeline.has_entries?(timeline, "lib/foo.ex")
    end
  end

  describe "cleanup/1" do
    test "cleans up memory-backed snapshots without error" do
      timeline =
        EditTimeline.new()
        |> EditTimeline.record_edit("lib/foo.ex", "tc1", "edit_file", "v0", "v1")
        |> EditTimeline.record_edit("lib/foo.ex", "tc2", "edit_file", "v1", "v2")

      assert :ok = EditTimeline.cleanup(timeline)
    end
  end
end
