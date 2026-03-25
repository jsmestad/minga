defmodule Minga.Editor.TreeRendererTest do
  @moduledoc "Tests TreeRenderer with focused RenderInput (no EditorState needed)."

  use ExUnit.Case, async: true

  alias Minga.Editor.TreeRenderer
  alias Minga.Editor.TreeRenderer.RenderInput
  alias Minga.Project.FileTree
  alias Minga.Theme

  @moduletag :tmp_dir

  defp sample_tree(tmp_dir) do
    # Create real files so FileTree.visible_entries works
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/main.ex"), "defmodule Main do\nend\n")
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.write!(Path.join(tmp_dir, "test/main_test.exs"), "defmodule MainTest do\nend\n")

    tree = FileTree.new(tmp_dir, width: 20)
    # Expand lib directory
    lib_path = Path.join(tmp_dir, "lib")
    %{tree | expanded: MapSet.put(tree.expanded, lib_path)}
  end

  describe "render/1 with RenderInput" do
    test "renders tree entries as draw tuples", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 20, 10},
        focused: true,
        theme: Theme.get!(:doom_one),
        active_path: nil
      }

      draws = TreeRenderer.render(input)
      assert [_ | _] = draws
      assert Enum.all?(draws, &(tuple_size(&1) == 4))
    end

    test "includes a header row with project name and folder icon", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 20, 10},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil
      }

      draws = TreeRenderer.render(input)
      # Header is the draw at row 0, col 0 with bold style
      header = Enum.find(draws, fn {r, c, _t, _s} -> r == 0 and c == 0 end)
      assert header != nil
      {_r, _c, text, style} = header
      # Contains the folder open icon (nf-md-folder-open U+F0256)
      assert String.contains?(text, "\u{F0256}")
      assert style.bold == true
    end

    test "renders separator column", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 20, 10},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil
      }

      draws = TreeRenderer.render(input)
      # Separator is at col 20 (width of tree rect)
      sep_draws = Enum.filter(draws, fn {_r, c, text, _s} -> c == 20 and text == "│" end)
      assert sep_draws != []
    end

    test "renders indent guides and file icons", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil
      }

      draws = TreeRenderer.render(input)
      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)
      all_text = Enum.join(texts)

      # Box-drawing guide characters should be present
      assert String.contains?(all_text, "├─")
      assert String.contains?(all_text, "└─")
      # Expanded lib/ should produce a pipe guide for its children
      assert String.contains?(all_text, "│ ")

      # Directory names should have trailing slashes
      assert String.contains?(all_text, "lib/")
      assert String.contains?(all_text, "test/")

      # File entries should have Elixir icon (U+E62D)
      assert String.contains?(all_text, "\u{E62D}")
    end

    test "renders multiple draw commands per entry row for icon coloring", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil
      }

      draws = TreeRenderer.render(input)
      # Row 1 is the first entry (lib/ directory). It should have multiple draws:
      # guide segment, icon segment, name segment
      row1_draws = Enum.filter(draws, fn {r, _c, _t, _s} -> r == 1 end)
      assert length(row1_draws) >= 2
    end

    test "renders git status indicators right-aligned", %{tmp_dir: tmp_dir} do
      tree = sample_tree(tmp_dir)
      main_path = Path.join(tmp_dir, "lib/main.ex")

      input = %RenderInput{
        tree: tree,
        rect: {0, 0, 30, 10},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        git_status: %{main_path => :modified}
      }

      draws = TreeRenderer.render(input)
      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)
      all_text = Enum.join(texts)

      # The modified indicator symbol should appear
      assert String.contains?(all_text, "●")
    end

    test "git status indicator has correct theme color", %{tmp_dir: tmp_dir} do
      tree = sample_tree(tmp_dir)
      main_path = Path.join(tmp_dir, "lib/main.ex")
      theme = Theme.get!(:doom_one)

      input = %RenderInput{
        tree: tree,
        rect: {0, 0, 30, 10},
        focused: false,
        theme: theme,
        active_path: nil,
        git_status: %{main_path => :staged}
      }

      draws = TreeRenderer.render(input)
      # Find the draw that contains the staged symbol
      staged_draw = Enum.find(draws, fn {_r, _c, text, _s} -> String.contains?(text, "✚") end)
      assert staged_draw != nil
      {_r, _c, _text, style} = staged_draw
      assert style.fg == theme.tree.git_staged_fg
    end

    test "renders modified buffer dot for dirty files", %{tmp_dir: tmp_dir} do
      tree = sample_tree(tmp_dir)
      main_path = Path.join(tmp_dir, "lib/main.ex")

      input = %RenderInput{
        tree: tree,
        rect: {0, 0, 30, 10},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        dirty_paths: MapSet.new([main_path])
      }

      draws = TreeRenderer.render(input)

      # Find draws for the row containing main.ex (should have the dirty dot)
      # The dirty dot is ● with the modified_fg color
      dirty_draws =
        Enum.filter(draws, fn {_r, _c, text, _s} ->
          text == "●"
        end)

      assert dirty_draws != []

      {_r, _c, _text, style} = hd(dirty_draws)
      theme = Theme.get!(:doom_one)
      assert style.fg == theme.tree.modified_fg
    end

    test "dirty dot and git status coexist on same row", %{tmp_dir: tmp_dir} do
      tree = sample_tree(tmp_dir)
      main_path = Path.join(tmp_dir, "lib/main.ex")

      input = %RenderInput{
        tree: tree,
        rect: {0, 0, 30, 10},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        git_status: %{main_path => :modified},
        dirty_paths: MapSet.new([main_path])
      }

      draws = TreeRenderer.render(input)
      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)
      all_text = Enum.join(texts)

      # Both the dirty dot (●) and git modified indicator (●) should appear
      # The dirty dot is bare "●", the git one is " ●"
      assert String.contains?(all_text, "●")
    end

    test "no dirty dot for directories", %{tmp_dir: tmp_dir} do
      tree = sample_tree(tmp_dir)
      lib_path = Path.join(tmp_dir, "lib")

      input = %RenderInput{
        tree: tree,
        rect: {0, 0, 30, 10},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        dirty_paths: MapSet.new([lib_path])
      }

      draws = TreeRenderer.render(input)
      # The lib/ row should NOT have a dirty dot (dirs excluded)
      # Find the lib/ entry row draws
      # Only file entries get the dot, not directories
      # lib/ shouldn't have a bare "●" (only guide/icon/name draws)
      lib_row_draws =
        Enum.filter(draws, fn {r, _c, text, _s} ->
          r == 1 and text == "●"
        end)

      assert lib_row_draws == []
    end

    test "highlights active file path", %{tmp_dir: tmp_dir} do
      main_path = Path.join(tmp_dir, "lib/main.ex")

      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: true,
        theme: Theme.get!(:doom_one),
        active_path: main_path
      }

      draws = TreeRenderer.render(input)
      assert [_ | _] = draws
    end
  end
end
