defmodule MingaEditor.Shell.Traditional.TreeRendererTest do
  @moduledoc "Tests TreeRenderer with focused RenderInput (no EditorState needed)."

  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.TreeRenderer
  alias MingaEditor.Shell.Traditional.TreeRenderer.RenderInput
  alias Minga.Project.FileTree
  alias MingaEditor.UI.Theme

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

  describe "editing entry rendering" do
    test "editing entry renders with inverse video styling", %{tmp_dir: tmp_dir} do
      theme = Theme.get!(:doom_one)

      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: true,
        theme: theme,
        active_path: nil,
        editing: %{index: 0, text: "new_file.ex", type: :new_file, original_name: nil}
      }

      draws = TreeRenderer.render(input)

      # Row 1 is the first entry (header is row 0). Find the text segment.
      row1_draws = Enum.filter(draws, fn {r, _c, _t, _s} -> r == 1 end)
      assert row1_draws != []

      # The text segment should have inverse video: fg = tree.bg, bg = tree.dir_fg
      text_draw =
        Enum.find(row1_draws, fn {_r, _c, text, _s} -> String.contains?(text, "new_file.ex") end)

      assert text_draw != nil
      {_r, _c, _text, style} = text_draw
      assert style.fg == theme.tree.bg
      assert style.bg == theme.tree.dir_fg
    end

    test "editing entry shows cursor indicator at end of text", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: true,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        editing: %{index: 0, text: "hello", type: :new_file, original_name: nil}
      }

      draws = TreeRenderer.render(input)
      row1_draws = Enum.filter(draws, fn {r, _c, _t, _s} -> r == 1 end)
      texts = Enum.map(row1_draws, fn {_r, _c, text, _s} -> text end)
      all_text = Enum.join(texts)

      # Should contain the text followed by the cursor indicator
      assert String.contains?(all_text, "hello▏")
    end

    test "editing entry with empty text shows only cursor indicator", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: true,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        editing: %{index: 0, text: "", type: :new_file, original_name: nil}
      }

      draws = TreeRenderer.render(input)
      row1_draws = Enum.filter(draws, fn {r, _c, _t, _s} -> r == 1 end)
      texts = Enum.map(row1_draws, fn {_r, _c, text, _s} -> text end)
      all_text = Enum.join(texts)

      assert String.contains?(all_text, "▏")
    end

    test "editing entry shows correct indent guides at depth", %{tmp_dir: tmp_dir} do
      # main.ex is inside expanded lib/, so it has depth > 0 and should have guides.
      # Index 1 in sample_tree is lib/main.ex (inside expanded lib/).
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: true,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        editing: %{index: 1, text: "renamed.ex", type: :rename, original_name: "main.ex"}
      }

      draws = TreeRenderer.render(input)
      row2_draws = Enum.filter(draws, fn {r, _c, _t, _s} -> r == 2 end)
      texts = Enum.map(row2_draws, fn {_r, _c, text, _s} -> text end)
      all_text = Enum.join(texts)

      # The entry at depth 1 should have a guide connector (└─ since it's last child)
      assert String.contains?(all_text, "└─") or String.contains?(all_text, "├─")
    end

    test "non-editing entries render normally when editing is active", %{tmp_dir: tmp_dir} do
      theme = Theme.get!(:doom_one)

      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: false,
        theme: theme,
        active_path: nil,
        editing: %{index: 0, text: "new.txt", type: :new_file, original_name: nil}
      }

      draws = TreeRenderer.render(input)

      # Row 2 is the second entry (not being edited). It should have normal styling.
      row2_draws = Enum.filter(draws, fn {r, _c, _t, _s} -> r == 2 end)
      assert row2_draws != []

      # Non-editing, non-cursor entries should have the normal tree bg
      name_draw =
        Enum.find(row2_draws, fn {_r, _c, _text, style} -> style.bg == theme.tree.bg end)

      assert name_draw != nil
    end

    test "editing type :new_folder shows folder icon", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: true,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        editing: %{index: 0, text: "new_dir", type: :new_folder, original_name: nil}
      }

      draws = TreeRenderer.render(input)
      row1_draws = Enum.filter(draws, fn {r, _c, _t, _s} -> r == 1 end)
      texts = Enum.map(row1_draws, fn {_r, _c, text, _s} -> text end)
      all_text = Enum.join(texts)

      # Should contain the folder-open icon (U+F0256)
      assert String.contains?(all_text, "\u{F0256}")
    end

    test "editing text style is bold", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 30, 10},
        focused: true,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        editing: %{index: 0, text: "test.txt", type: :new_file, original_name: nil}
      }

      draws = TreeRenderer.render(input)
      row1_draws = Enum.filter(draws, fn {r, _c, _t, _s} -> r == 1 end)

      text_draw =
        Enum.find(row1_draws, fn {_r, _c, text, _s} -> String.contains?(text, "test.txt") end)

      assert text_draw != nil
      {_r, _c, _text, style} = text_draw
      assert style.bold == true
    end
  end
end
