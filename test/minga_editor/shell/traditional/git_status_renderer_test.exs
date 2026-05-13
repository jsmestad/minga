defmodule MingaEditor.Shell.Traditional.GitStatusRendererTest do
  @moduledoc "Tests for TUI git status panel rendering."
  use ExUnit.Case, async: true

  alias Minga.Git.StatusEntry
  alias MingaEditor.Shell.Traditional.GitStatus.TuiState
  alias MingaEditor.Shell.Traditional.GitStatusRenderer

  @rect {1, 0, 30, 21}

  defp base_state(panel, opts \\ []) do
    theme = MingaEditor.UI.Theme.get!(:doom_one)
    viewport_rows = Keyword.get(opts, :rows, 24)
    viewport_cols = Keyword.get(opts, :cols, 80)
    tui_state = Keyword.get(opts, :tui_state)

    %{
      workspace: %{
        file_tree: %{tree: %Minga.Project.FileTree{root: "/tmp", width: 30}},
        viewport: %{rows: viewport_rows, cols: viewport_cols},
        keymap_scope: :git_status
      },
      shell_state: %{git_status_panel: panel, git_status_tui_state: tui_state},
      theme: theme
    }
  end

  defp make_panel(entries) do
    %{
      repo_state: :normal,
      branch: "main",
      ahead: 0,
      behind: 0,
      entries: entries
    }
  end

  defp make_tui_state(overrides) do
    TuiState.new()
    |> Map.merge(overrides)
  end

  describe "render/2" do
    test "returns empty list when no panel is active" do
      state = base_state(nil)
      assert GitStatusRenderer.render(state, @rect) == []
    end

    test "returns empty list when layout did not reserve a sidebar" do
      entries = [%StatusEntry{path: "file.ex", status: :modified, staged: false}]
      state = base_state(make_panel(entries))
      assert GitStatusRenderer.render(state, nil) == []
    end

    test "renders header with branch name" do
      entries = [
        %StatusEntry{path: "file.ex", status: :modified, staged: false}
      ]

      panel = make_panel(entries)
      state = base_state(panel)
      draws = GitStatusRenderer.render(state, @rect)

      header_draw = hd(draws)
      assert String.contains?(elem(header_draw, 2), "main")
    end

    test "renders entries without persisted tui state" do
      entries = [
        %StatusEntry{path: "unstaged.ex", status: :modified, staged: false}
      ]

      state = base_state(make_panel(entries))
      draws = GitStatusRenderer.render(state, @rect)

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "Changes"))
      assert Enum.any?(texts, &String.contains?(&1, "unstaged"))
    end

    test "renders section headers with counts" do
      entries = [
        %StatusEntry{path: "staged.ex", status: :modified, staged: true},
        %StatusEntry{path: "unstaged.ex", status: :modified, staged: false},
        %StatusEntry{path: "new.ex", status: :untracked, staged: false}
      ]

      panel = make_panel(entries)
      state = base_state(panel)
      draws = GitStatusRenderer.render(state, @rect)

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
      draws = GitStatusRenderer.render(state, @rect)

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

      panel = make_panel(entries)
      state = base_state(panel, tui_state: make_tui_state(%{collapsed: %{changes: true}}))
      draws = GitStatusRenderer.render(state, @rect)

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "Changes"))
      refute Enum.any?(texts, &String.contains?(&1, "file1"))
    end

    test "renders separator column" do
      entries = [%StatusEntry{path: "file.ex", status: :modified, staged: false}]
      panel = make_panel(entries)
      state = base_state(panel)
      draws = GitStatusRenderer.render(state, @rect)

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
      draws = GitStatusRenderer.render(state, @rect)

      header_text = elem(hd(draws), 2)
      assert String.contains?(header_text, "↑3")
      assert String.contains?(header_text, "↓1")
    end
  end
end
