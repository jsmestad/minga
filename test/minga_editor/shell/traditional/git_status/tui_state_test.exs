defmodule MingaEditor.Shell.Traditional.GitStatus.TuiStateTest do
  use ExUnit.Case, async: true

  alias Minga.Git.StatusEntry
  alias MingaEditor.Shell.Traditional.GitStatus.TuiState

  # ── Test data helpers ──────────────────────────────────────────────────

  @spec entry(String.t(), atom(), boolean()) :: StatusEntry.t()
  defp entry(path, status, staged) do
    %StatusEntry{path: path, status: status, staged: staged}
  end

  @spec sample_entries() :: [StatusEntry.t()]
  defp sample_entries do
    [
      entry("staged.ex", :modified, true),
      entry("changed.ex", :modified, false),
      entry("also_changed.ex", :modified, false),
      entry("new_file.ex", :untracked, false)
    ]
  end

  # ── next/2 ─────────────────────────────────────────────────────────────

  describe "next/2" do
    test "advances cursor by 1" do
      tui = TuiState.new()
      entries = sample_entries()

      updated = TuiState.next(tui, entries)
      assert updated.cursor_index == 1
    end

    test "clamps at last entry (does not wrap)" do
      entries = sample_entries()
      max_idx = length(TuiState.flat_entries(TuiState.new(), entries)) - 1
      tui = %{TuiState.new() | cursor_index: max_idx}

      updated = TuiState.next(tui, entries)
      assert updated.cursor_index == max_idx
    end

    test "works with empty entries (stays at 0)" do
      tui = TuiState.new()

      updated = TuiState.next(tui, [])
      assert updated.cursor_index == 0
    end
  end

  # ── prev/2 ─────────────────────────────────────────────────────────────

  describe "prev/2" do
    test "decrements cursor by 1" do
      tui = %{TuiState.new() | cursor_index: 3}
      entries = sample_entries()

      updated = TuiState.prev(tui, entries)
      assert updated.cursor_index == 2
    end

    test "clamps at 0 (does not go negative)" do
      tui = TuiState.new()
      entries = sample_entries()

      updated = TuiState.prev(tui, entries)
      assert updated.cursor_index == 0
    end
  end

  # ── next_section/2 ─────────────────────────────────────────────────────

  describe "next_section/2" do
    test "jumps to next section header" do
      tui = TuiState.new()
      entries = sample_entries()

      # Cursor starts at 0 (first section header: :staged).
      # Next section header should be :changes.
      updated = TuiState.next_section(tui, entries)
      flat = TuiState.flat_entries(tui, entries)
      assert {:section_header, :changes, _} = Enum.at(flat, updated.cursor_index)
    end

    test "stays put when already at last section" do
      entries = sample_entries()
      flat = TuiState.flat_entries(TuiState.new(), entries)

      # Find the last section header index
      last_section_idx =
        flat
        |> Enum.with_index()
        |> Enum.filter(fn {{type, _, _}, _} -> type == :section_header end)
        |> List.last()
        |> elem(1)

      tui = %{TuiState.new() | cursor_index: last_section_idx}

      updated = TuiState.next_section(tui, entries)
      assert updated.cursor_index == last_section_idx
    end
  end

  # ── prev_section/2 ─────────────────────────────────────────────────────

  describe "prev_section/2" do
    test "jumps to previous section header" do
      entries = sample_entries()
      flat = TuiState.flat_entries(TuiState.new(), entries)

      # Find the second section header
      section_indices =
        flat
        |> Enum.with_index()
        |> Enum.filter(fn {{type, _, _}, _} -> type == :section_header end)
        |> Enum.map(&elem(&1, 1))

      # Start at the second section header
      tui = %{TuiState.new() | cursor_index: Enum.at(section_indices, 1)}

      updated = TuiState.prev_section(tui, entries)
      assert updated.cursor_index == Enum.at(section_indices, 0)
    end

    test "returns 0 when at or before first header" do
      tui = TuiState.new()
      entries = sample_entries()

      updated = TuiState.prev_section(tui, entries)
      assert updated.cursor_index == 0
    end
  end

  # ── toggle_current_section/2 ───────────────────────────────────────────

  describe "toggle_current_section/2" do
    test "collapses when on a section header" do
      tui = TuiState.new()
      entries = sample_entries()

      # Cursor at 0 should be a section header
      assert {:section_header, section, _} =
               TuiState.current_entry(tui, entries)

      updated = TuiState.toggle_current_section(tui, entries)
      assert Map.has_key?(updated.collapsed, section)
    end

    test "no-op when on a file row" do
      entries = sample_entries()
      # Cursor at 1 should be a file row (first file under :staged)
      tui = %{TuiState.new() | cursor_index: 1}

      assert {:file, _, _} = TuiState.current_entry(tui, entries)

      updated = TuiState.toggle_current_section(tui, entries)
      assert updated == tui
    end
  end

  # ── selected_file/2 ────────────────────────────────────────────────────

  describe "selected_file/2" do
    test "returns StatusEntry when cursor is on a file row" do
      entries = sample_entries()
      tui = %{TuiState.new() | cursor_index: 1}

      result = TuiState.selected_file(tui, entries)
      assert %StatusEntry{} = result
    end

    test "returns nil when on a section header" do
      tui = TuiState.new()
      entries = sample_entries()

      assert TuiState.selected_file(tui, entries) == nil
    end
  end

  # ── refresh/2 ──────────────────────────────────────────────────────────

  describe "refresh/2" do
    test "clamps cursor when entries shrink" do
      # Start with cursor beyond what a smaller list can hold
      tui = %{TuiState.new() | cursor_index: 100}
      entries = [entry("only.ex", :modified, false)]

      updated = TuiState.refresh(tui, entries)
      flat_len = length(TuiState.flat_entries(updated, entries))
      assert updated.cursor_index < flat_len
    end

    test "clears discard_confirmation" do
      discard_entry = entry("foo.ex", :modified, false)

      tui =
        TuiState.new()
        |> TuiState.request_discard(discard_entry, "/tmp/repo")

      assert match?({%StatusEntry{}, _}, tui.discard_confirmation)

      entries = [discard_entry]
      updated = TuiState.refresh(tui, entries)
      assert updated.discard_confirmation == nil
    end
  end

  # ── flat_entries/2 ─────────────────────────────────────────────────────

  describe "flat_entries/2" do
    test "respects collapsed sections" do
      entries = sample_entries()
      tui = TuiState.new()

      all_flat = TuiState.flat_entries(tui, entries)

      # Collapse the :changes section
      collapsed_tui = %{tui | collapsed: %{changes: true}}
      collapsed_flat = TuiState.flat_entries(collapsed_tui, entries)

      # Collapsed list should be shorter (missing the 2 files under :changes)
      assert length(collapsed_flat) < length(all_flat)

      # The :changes section header should still appear
      assert Enum.any?(collapsed_flat, fn
        {:section_header, :changes, _} -> true
        _ -> false
      end)

      # But no file entries under :changes
      refute Enum.any?(collapsed_flat, fn
        {:file, :changes, _} -> true
        _ -> false
      end)
    end

    test "produces correct section headers with counts" do
      entries = sample_entries()
      tui = TuiState.new()

      flat = TuiState.flat_entries(tui, entries)

      # :staged has 1 entry
      assert {:section_header, :staged, 1} =
               Enum.find(flat, fn
                 {:section_header, :staged, _} -> true
                 _ -> false
               end)

      # :changes has 2 entries
      assert {:section_header, :changes, 2} =
               Enum.find(flat, fn
                 {:section_header, :changes, _} -> true
                 _ -> false
               end)

      # :untracked has 1 entry
      assert {:section_header, :untracked, 1} =
               Enum.find(flat, fn
                 {:section_header, :untracked, _} -> true
                 _ -> false
               end)
    end
  end
end
