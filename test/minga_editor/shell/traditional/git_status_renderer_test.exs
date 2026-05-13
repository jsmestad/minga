defmodule MingaEditor.Shell.Traditional.GitStatusRendererTest do
  @moduledoc "Tests for TUI git status panel rendering."
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.GitStatusRenderer
  alias MingaEditor.Input.GitStatus.TuiState
  alias Minga.Git.StatusEntry

  defp base_state(panel, opts \\ []) do
    theme = MingaEditor.UI.Theme.get!(:doom_one)
    viewport_rows = Keyword.get(opts, :rows, 24)
    viewport_cols = Keyword.get(opts, :cols, 80)

    %{
      workspace: %{
        file_tree: %{tree: %Minga.Project.FileTree{root: "/tmp", width: 30}},
        viewport: %{rows: viewport_rows, cols: viewport_cols},
        keymap_scope: :git_status
      },
      shell_state: %{git_status_panel: panel},
      theme: theme
    }
  end

  defp make_panel(entries, tui_overrides \\ %{}) do
    tui = build_tui_state(entries, tui_overrides)

    %{
      repo_state: :normal,
      branch: "main",
      ahead: 0,
      behind: 0,
      entries: entries,
      tui_state: tui
    }
  end

  defp build_tui_state(entries, overrides) do
    base = %TuiState{
      cursor_index: Map.get(overrides, :cursor_index, 0),
      collapsed: Map.get(overrides, :collapsed, %{}),
      flat_entries: [],
      entries: entries
    }

    sections = [
      {:conflicts, fn e -> e.status == :conflict end},
      {:staged, fn e -> e.staged and e.status != :conflict and e.status != :untracked end},
      {:changes, fn e -> not e.staged and e.status != :conflict and e.status != :untracked end},
      {:untracked, fn e -> e.status == :untracked end}
    ]

    flat =
      Enum.flat_map(sections, fn {section_name, filter_fn} ->
        is_collapsed = Map.has_key?(base.collapsed, section_name)
        build_section(entries, section_name, filter_fn, is_collapsed)
      end)

    %{base | flat_entries: flat}
  end

  defp build_section(entries, section_name, filter_fn, is_collapsed) do
    section_entries = Enum.filter(entries, filter_fn)

    case {section_entries, is_collapsed} do
      {[], _} ->
        []

      {_, true} ->
        [{:section_header, section_name, length(section_entries)}]

      _ ->
        header = [{:section_header, section_name, length(section_entries)}]
        file_entries = Enum.map(section_entries, &{:file, section_name, &1})
        header ++ file_entries
    end
  end

  describe "render/1" do
    test "returns empty list when no panel is active" do
      state = base_state(nil)
      assert GitStatusRenderer.render(state) == []
    end

    test "renders header with branch name" do
      entries = [
        %StatusEntry{path: "file.ex", status: :modified, staged: false}
      ]

      panel = make_panel(entries)
      state = base_state(panel)
      draws = GitStatusRenderer.render(state)

      header_draw = hd(draws)
      assert String.contains?(elem(header_draw, 2), "main")
    end

    test "renders section headers with counts" do
      entries = [
        %StatusEntry{path: "staged.ex", status: :modified, staged: true},
        %StatusEntry{path: "unstaged.ex", status: :modified, staged: false},
        %StatusEntry{path: "new.ex", status: :untracked, staged: false}
      ]

      panel = make_panel(entries)
      state = base_state(panel)
      draws = GitStatusRenderer.render(state)

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "Staged"))
      assert Enum.any?(texts, &String.contains?(&1, "Changes"))
      assert Enum.any?(texts, &String.contains?(&1, "Untracked"))
    end

    test "renders file rows with status characters" do
      entries = [
        %StatusEntry{path: "added.ex", status: :added, staged: true},
        %StatusEntry{path: "modified.ex", status: :modified, staged: false},
        %StatusEntry{path: "deleted.ex", status: :deleted, staged: false}
      ]

      panel = make_panel(entries)
      state = base_state(panel)
      draws = GitStatusRenderer.render(state)

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "A "))
      assert Enum.any?(texts, &String.contains?(&1, "M "))
      assert Enum.any?(texts, &String.contains?(&1, "D "))
    end

    test "renders collapsed sections as header only" do
      entries = [
        %StatusEntry{path: "file1.ex", status: :modified, staged: false},
        %StatusEntry{path: "file2.ex", status: :modified, staged: false}
      ]

      panel = make_panel(entries, %{collapsed: %{changes: true}})
      state = base_state(panel)
      draws = GitStatusRenderer.render(state)

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "Changes"))
      refute Enum.any?(texts, &String.contains?(&1, "file1"))
    end

    test "renders separator column" do
      entries = [%StatusEntry{path: "file.ex", status: :modified, staged: false}]
      panel = make_panel(entries)
      state = base_state(panel)
      draws = GitStatusRenderer.render(state)

      sep_draws = Enum.filter(draws, fn d -> elem(d, 2) == "│" end)
      assert sep_draws != []
    end

    test "renders ahead/behind in header" do
      entries = [%StatusEntry{path: "f.ex", status: :modified, staged: false}]

      panel = %{
        make_panel(entries)
        | ahead: 3,
          behind: 1
      }

      state = base_state(panel)
      draws = GitStatusRenderer.render(state)

      header_text = elem(hd(draws), 2)
      assert String.contains?(header_text, "↑3")
      assert String.contains?(header_text, "↓1")
    end
  end
end
