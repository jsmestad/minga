defmodule MingaEditor.Shell.Traditional.TreeRendererTest do
  @moduledoc "Tests TreeRenderer with focused RenderInput, keeping production-state extraction smoke coverage thin."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Unicode
  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.Diagnostics, as: RowDiagnostics
  alias MingaEditor.FileTree.Row
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Shell.Traditional.TreeRenderer
  alias MingaEditor.Shell.Traditional.TreeRenderer.RenderInput
  alias MingaEditor.UI.Theme

  import MingaEditor.RenderPipeline.TestHelpers, only: [gui_state: 1]

  @moduletag :tmp_dir

  describe "RenderInput rendering" do
    test "renders header, entry draw tuples, and separator", %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "minga")
      draws = render_input(root, width: 20, height: 10, focused: false)

      assert [_ | _] = draws
      assert Enum.all?(draws, &(tuple_size(&1) == 4))

      {0, 0, header, header_style} = draw_at(draws, 0, 0)
      assert header =~ "\u{F0256}"
      assert header =~ "minga"
      assert header_style.bold == true

      assert Enum.any?(draws, fn {_row, col, text, _style} -> col == 20 and text == "│" end)
    end

    test "renders filter and help overlay text", %{tmp_dir: tmp_dir} do
      filter_text =
        tmp_dir
        |> render_input(width: 24, height: 6, filtering?: true, filter_text: "main")
        |> draw_texts()

      help_text =
        tmp_dir
        |> render_input(width: 72, height: 30, help_visible?: true)
        |> draw_texts()

      assert filter_text =~ " / main▏"

      for expected <- [
            "Keyboard Shortcuts",
            "Navigation",
            "File Operations",
            "Copy path",
            "Mark copy / move",
            "Paste",
            "Parent root / selected root / project root",
            "Filter tree",
            "Toggle help"
          ] do
        assert help_text =~ expected
      end
    end

    test "clips zero-height and height-one panels to the rect", %{tmp_dir: tmp_dir} do
      assert render_input(tmp_dir, width: 20, height: 0) == []

      draws = render_input(tmp_dir, width: 20, height: 1)

      assert Enum.any?(draws, fn {row, col, text, _style} ->
               row == 0 and col == 0 and String.contains?(text, "\u{F0256}")
             end)

      assert [{0, 20, "│", _style}] =
               Enum.filter(draws, fn {_row, col, text, _style} -> col == 20 and text == "│" end)

      refute Enum.any?(draws, fn {row, col, _text, _style} -> row > 0 and col < 20 end)
    end

    test "renders empty, loading, and error status rows without layout drift", %{tmp_dir: tmp_dir} do
      cases = [
        {:ready, "No files yet"},
        {:loading, "Loading files"},
        {{:error, "permission denied"}, "File tree error"}
      ]

      for {status, expected} <- cases do
        draws = render_input(tmp_dir, width: 24, height: 5, rows: [], status: status)
        text = draw_texts(draws)

        assert text =~ expected
        if match?({:error, _}, status), do: assert(text =~ "permission denied")
        assert Enum.any?(draws, fn {_row, col, text, _style} -> col == 24 and text == "│" end)
        refute Enum.any?(draws, fn {row, col, _text, _style} -> row < 0 or col < 0 end)
      end
    end

    test "renders disclosure, guide, icon, and stable name columns", %{tmp_dir: tmp_dir} do
      draws = render_input(tmp_dir, width: 30, height: 10, focused: false)
      all_text = draw_texts(draws)

      assert all_text =~ "▾ "
      assert all_text =~ "▸ "
      assert all_text =~ "│ "
      refute all_text =~ "├─"
      refute all_text =~ "└─"
      assert all_text =~ "lib/"
      assert all_text =~ "test/"
      assert all_text =~ "\u{E62D}"

      assert {1, 0, "▾ ", _style} = draw_matching(draws, "▾ ")
      assert {1, 2, "\u{F0256} ", _style} = draw_matching(draws, "\u{F0256} ")
      assert {1, 4, name, _style} = draw_containing(draws, "lib/")
      assert String.starts_with?(name, "lib/")
      assert length(row_draws(draws, 1)) >= 3
    end

    @tag timeout: 180_000
    test "renders large trees around the selected row", %{tmp_dir: tmp_dir} do
      tree = large_tree(tmp_dir, 600, width: 32) |> FileTree.select(599)
      draws = render_input(tmp_dir, tree: tree, width: 32, height: 8, focused: true)
      text = draw_texts(draws)

      for name <-
            Enum.map(594..600, &"file_#{String.pad_leading(Integer.to_string(&1), 3, "0")}.ex") do
        assert text =~ name
      end

      refute text =~ "file_593.ex"
      refute text =~ "file_001.ex"
    end
  end

  describe "production state extraction" do
    test "renders active and dirty row state from editor state", %{tmp_dir: tmp_dir} do
      theme = Theme.get!(:doom_one)
      active_path = Path.join(tmp_dir, "active.ex")
      dirty_path = Path.join(tmp_dir, "dirty.ex")
      File.write!(active_path, "active")
      File.write!(dirty_path, "dirty")

      {:ok, active_buf} = BufferProcess.start_link(file_path: active_path)
      {:ok, dirty_buf} = BufferProcess.start_link(file_path: dirty_path)
      :ok = BufferProcess.insert_text(dirty_buf, "!")

      state =
        gui_state(rows: 10, cols: 80)
        |> EditorState.set_file_tree(
          FileTreeState.open(%FileTreeState{}, FileTree.new(tmp_dir, width: 32), nil)
        )
        |> put_in([Access.key(:workspace), Access.key(:buffers)], %Buffers{
          active: active_buf,
          list: [active_buf, dirty_buf],
          active_index: 0
        })

      draws = TreeRenderer.render(state)
      text = draw_texts(draws)

      assert text =~ "active.ex"
      assert text =~ "dirty.ex"
      assert text =~ "●"

      {_row, _col, _text, active_style} = draw_containing(draws, "active.ex")
      {_row, _col, _text, dirty_style} = draw_matching(draws, "●")
      assert active_style.fg == theme.tree.active_fg
      assert active_style.bold == true
      assert dirty_style.fg == theme.tree.modified_fg
    end

    test "renders loading and error status from file tree state", %{tmp_dir: tmp_dir} do
      tree = FileTree.new(tmp_dir, width: 24)
      file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)

      for {file_tree, expected} <- [
            {FileTreeState.loading(file_tree), "Loading files"},
            {FileTreeState.error(file_tree, :eacces), "permission denied"}
          ] do
        draws = TreeRenderer.render(production_state(file_tree, rows: 5, cols: 80))
        assert draw_texts(draws) =~ expected
        assert Enum.any?(draws, fn {_row, col, text, _style} -> col == 24 and text == "│" end)
      end
    end
  end

  describe "semantic row rendering" do
    test "renders supplied semantic rows and independent status marker styles", %{
      tmp_dir: tmp_dir
    } do
      theme = Theme.get!(:doom_one)

      row =
        semantic_file_row(tmp_dir,
          selected?: true,
          focused?: true,
          active?: true,
          dirty?: true,
          git_status: :conflict,
          diagnostics: RowDiagnostics.new({2, 0, 0, 0})
        )

      draws = render_semantic_rows(tmp_dir, [row], theme)
      text = draw_texts(draws)

      assert text =~ "main.ex"
      assert text =~ "✖2"
      assert text =~ "●"
      assert text =~ " !"

      {_row, _col, _text, name_style} = draw_containing(draws, "main.ex")
      {_row, _col, _text, diagnostic_style} = draw_matching(draws, "✖2")
      {_row, _col, _text, dirty_style} = draw_matching(draws, "●")
      {_row, _col, _text, git_style} = draw_matching(draws, " !")

      assert name_style.fg == theme.tree.active_fg
      assert name_style.bg == theme.tree.cursor_bg
      assert name_style.bold == true
      assert diagnostic_style.fg == theme.gutter.error_fg
      assert diagnostic_style.bg == theme.tree.cursor_bg
      assert dirty_style.fg == theme.tree.modified_fg
      assert dirty_style.bg == theme.tree.cursor_bg
      assert git_style.fg == theme.tree.git_conflict_fg
      assert git_style.bg == theme.tree.cursor_bg
    end

    test "right-edge status columns fit by truncating the name first", %{tmp_dir: tmp_dir} do
      row =
        semantic_file_row(tmp_dir,
          dirty?: true,
          git_status: :modified,
          diagnostics: RowDiagnostics.new({0, 1, 0, 0})
        )

      draws = render_semantic_rows(tmp_dir, [row], Theme.get!(:doom_one), width: 12)
      row_text = rendered_row_text(draws, 1, 12)
      diagnostic_draw = draw_matching(draws, "⚠")
      dirty_draw = draw_matching(draws, "●")
      git_draw = draw_matching(draws, " ●")

      assert Unicode.display_width(row_text) <= 12
      assert diagnostic_draw != nil
      assert dirty_draw != nil
      assert git_draw != nil
      assert draw_col(diagnostic_draw) < draw_col(dirty_draw)
      assert draw_col(dirty_draw) < draw_col(git_draw)
    end

    test "unicode basename tails and statuses fit in narrow rows", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "lib/minga_editor/shell/traditional/非常に長い_component_view.ex")

      row =
        semantic_file_row(tmp_dir,
          path: path,
          name: "非常に長い_component_view.ex",
          depth: 8,
          guides: [true, true, false, true, false, true, true, false],
          dirty?: true,
          git_status: :modified,
          diagnostics: RowDiagnostics.new({0, 1, 0, 0})
        )

      draws =
        render_semantic_rows(tmp_dir, [row], Theme.get!(:doom_one), width: 18, focused: true)

      row_text = rendered_row_text(draws, 1, 18)

      assert Unicode.display_width(row_text) <= 18
      assert row_text =~ "…"
      assert row_text =~ ".ex"
      assert draw_matching(draws, "⚠") != nil
      assert draw_matching(draws, "●") != nil
      assert draw_matching(draws, " ●") != nil
    end

    test "actual nested unicode file tree rows fit within narrow tree width", %{tmp_dir: tmp_dir} do
      target_path =
        Path.join(tmp_dir, "lib/minga_editor/shell/traditional/非常に長い_component_view.ex")

      draws =
        render_input(tmp_dir,
          tree: nested_fixture_tree(tmp_dir, width: 18),
          width: 18,
          height: 12,
          git_status: %{target_path => :modified},
          dirty_paths: MapSet.new([target_path])
        )

      row_draws =
        Enum.filter(draws, fn {_row, _col, text, _style} -> String.contains?(text, ".ex") end)

      assert row_draws != []

      for {row, _col, _text, _style} <- row_draws do
        assert Unicode.display_width(rendered_row_text(draws, row, 18)) <= 18
      end
    end

    test "large diagnostic counts are capped before narrow-row fitting", %{tmp_dir: tmp_dir} do
      row =
        semantic_file_row(tmp_dir,
          dirty?: true,
          git_status: :conflict,
          diagnostics: RowDiagnostics.new({120, 0, 0, 0})
        )

      draws = render_semantic_rows(tmp_dir, [row], Theme.get!(:doom_one), width: 10)
      row_text = rendered_row_text(draws, 1, 10)

      assert Unicode.display_width(row_text) <= 10
      assert row_text =~ "✖9+"
    end

    test "unfocused selected rows use subdued selection background", %{tmp_dir: tmp_dir} do
      theme = Theme.get!(:doom_one)
      row = semantic_file_row(tmp_dir, selected?: true, focused?: false)
      draws = render_semantic_rows(tmp_dir, [row], theme)
      {_row, _col, _text, style} = draw_containing(draws, "main.ex")

      assert style.bg == theme.tree.separator_fg
      refute style.bg == theme.tree.cursor_bg
    end
  end

  describe "editing entry rendering" do
    test "editing row renders inverse bold text, cursor, folder icon, and depth guides", %{
      tmp_dir: tmp_dir
    } do
      theme = Theme.get!(:doom_one)

      file_draws =
        render_input(tmp_dir,
          width: 30,
          height: 10,
          focused: true,
          editing: %{index: 0, text: "new_file.ex", type: :new_file, original_name: nil}
        )

      folder_draws =
        render_input(tmp_dir,
          width: 30,
          height: 10,
          focused: true,
          editing: %{index: 0, text: "new_dir", type: :new_folder, original_name: nil}
        )

      nested_draws =
        render_input(tmp_dir,
          width: 30,
          height: 10,
          focused: true,
          editing: %{index: 1, text: "renamed.ex", type: :rename, original_name: "main.ex"}
        )

      {_row, _col, _text, file_style} = draw_containing(row_draws(file_draws, 1), "new_file.ex▏")
      folder_text = row_text(folder_draws, 1)
      nested_text = row_text(nested_draws, 2)

      assert file_style.fg == theme.tree.bg
      assert file_style.bg == theme.tree.dir_fg
      assert file_style.bold == true
      assert folder_text =~ "\u{F0256}"
      assert folder_text =~ "new_dir▏"
      assert nested_text =~ "renamed.ex▏"
      assert nested_text =~ "│ " or nested_text =~ "  "
      refute nested_text =~ "└─"
      refute nested_text =~ "├─"
    end

    test "empty editing text still renders a cursor and non-edited rows keep normal styling", %{
      tmp_dir: tmp_dir
    } do
      theme = Theme.get!(:doom_one)

      draws =
        render_input(tmp_dir,
          width: 30,
          height: 10,
          focused: true,
          editing: %{index: 0, text: "", type: :new_file, original_name: nil}
        )

      assert row_text(draws, 1) =~ "▏"

      assert Enum.any?(row_draws(draws, 2), fn {_row, _col, _text, style} ->
               style.bg == theme.tree.bg
             end)
    end
  end

  defp sample_tree(tmp_dir, opts) do
    width = Keyword.get(opts, :width, 20)
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/main.ex"), "defmodule Main do\nend\n")
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.write!(Path.join(tmp_dir, "test/main_test.exs"), "defmodule MainTest do\nend\n")

    tmp_dir
    |> FileTree.new(width: width)
    |> FileTree.expand_path(Path.join(tmp_dir, "lib"))
  end

  defp large_tree(tmp_dir, count, opts) do
    width = Keyword.fetch!(opts, :width)

    for index <- 1..count do
      File.write!(
        Path.join(tmp_dir, "file_#{String.pad_leading(Integer.to_string(index), 3, "0")}.ex"),
        ""
      )
    end

    FileTree.new(tmp_dir, width: width)
  end

  defp nested_fixture_tree(tmp_dir, opts) do
    width = Keyword.fetch!(opts, :width)
    deep_dir = Path.join(tmp_dir, "lib/minga_editor/shell/traditional")
    sibling_dir = Path.join(tmp_dir, "lib/minga_editor/shell/board")

    File.mkdir_p!(deep_dir)
    File.mkdir_p!(sibling_dir)

    File.write!(
      Path.join(deep_dir, "非常に長い_component_view.ex"),
      "defmodule ComponentView do\nend\n"
    )

    File.write!(Path.join(sibling_dir, "card.ex"), "defmodule Card do\nend\n")

    tmp_dir
    |> FileTree.new(width: width)
    |> FileTree.expand_path(Path.join(tmp_dir, "lib"))
    |> FileTree.expand_path(Path.join(tmp_dir, "lib/minga_editor"))
    |> FileTree.expand_path(Path.join(tmp_dir, "lib/minga_editor/shell"))
    |> FileTree.expand_path(deep_dir)
  end

  defp render_input(tmp_dir, opts) do
    width = Keyword.get(opts, :width, 30)
    height = Keyword.get(opts, :height, 10)
    tree = Keyword.get_lazy(opts, :tree, fn -> sample_tree(tmp_dir, width: width) end)

    TreeRenderer.render(%RenderInput{
      tree: tree,
      rect: {0, 0, width, height},
      focused: Keyword.get(opts, :focused, false),
      theme: Keyword.get_lazy(opts, :theme, fn -> Theme.get!(:doom_one) end),
      active_path: Keyword.get(opts, :active_path),
      editing: Keyword.get(opts, :editing),
      git_status: Keyword.get(opts, :git_status, %{}),
      dirty_paths: Keyword.get(opts, :dirty_paths, MapSet.new()),
      rows: Keyword.get(opts, :rows),
      status: Keyword.get(opts, :status, :ready),
      filter_text: Keyword.get(opts, :filter_text),
      filtering?: Keyword.get(opts, :filtering?, false),
      help_visible?: Keyword.get(opts, :help_visible?, false)
    })
  end

  defp production_state(file_tree, opts) do
    rows = Keyword.fetch!(opts, :rows)
    cols = Keyword.fetch!(opts, :cols)

    %{
      workspace:
        %SessionState{
          viewport: %{rows: rows, cols: cols},
          buffers: %{active: nil, list: [], active_index: 0}
        }
        |> SessionState.set_file_tree(file_tree),
      theme: Theme.get!(:doom_one)
    }
  end

  defp render_semantic_rows(tmp_dir, rows, theme, opts \\ []) do
    width = Keyword.get(opts, :width, 30)

    TreeRenderer.render(%RenderInput{
      tree: FileTree.new(tmp_dir, width: width),
      rect: {0, 0, width, 5},
      focused: Keyword.get(opts, :focused, false),
      theme: theme,
      active_path: nil,
      rows: rows
    })
  end

  defp semantic_file_row(tmp_dir, attrs) do
    file_path = Keyword.get(attrs, :path, Path.join(tmp_dir, "main.ex"))

    Row.new(
      Keyword.merge(
        [
          id: file_path,
          path: file_path,
          relative_path: Path.relative_to(file_path, tmp_dir),
          name: Path.basename(file_path),
          directory?: false,
          expanded?: false,
          selected?: false,
          focused?: false,
          active?: false,
          dirty?: false,
          git_status: nil,
          depth: 0,
          guides: [],
          last_child?: true
        ],
        attrs
      )
    )
  end

  defp draw_texts(draws), do: Enum.map_join(draws, fn {_row, _col, text, _style} -> text end)

  defp draw_at(draws, row, col),
    do:
      Enum.find(draws, fn {draw_row, draw_col, _text, _style} ->
        draw_row == row and draw_col == col
      end)

  defp draw_containing(draws, text),
    do:
      Enum.find(draws, fn {_row, _col, draw_text, _style} -> String.contains?(draw_text, text) end)

  defp draw_matching(draws, text),
    do: Enum.find(draws, fn {_row, _col, draw_text, _style} -> draw_text == text end)

  defp draw_col({_row, col, _text, _style}), do: col

  defp row_draws(draws, row),
    do: Enum.filter(draws, fn {draw_row, _col, _text, _style} -> draw_row == row end)

  defp row_text(draws, row),
    do: draws |> row_draws(row) |> Enum.map_join(fn {_row, _col, text, _style} -> text end)

  defp rendered_row_text(draws, row, width) do
    draws
    |> Enum.filter(fn {draw_row, col, _text, _style} -> draw_row == row and col < width end)
    |> Enum.sort_by(fn {_row, col, _text, _style} -> col end)
    |> Enum.map_join(fn {_row, _col, text, _style} -> text end)
  end
end
