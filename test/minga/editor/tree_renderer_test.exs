defmodule Minga.Editor.TreeRendererTest do
  @moduledoc "Tests TreeRenderer with focused RenderInput (no EditorState needed)."

  use ExUnit.Case, async: true

  alias Minga.Editor.TreeRenderer
  alias Minga.Editor.TreeRenderer.RenderInput
  alias Minga.FileTree
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

    test "includes a header row", %{tmp_dir: tmp_dir} do
      input = %RenderInput{
        tree: sample_tree(tmp_dir),
        rect: {0, 0, 20, 10},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil
      }

      draws = TreeRenderer.render(input)
      texts = Enum.map(draws, fn {_r, _c, text, _s} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "File Tree"))
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
