defmodule MingaEditor.Shell.Traditional.TreeRendererTest do
  @moduledoc "Tests TreeRenderer with focused RenderInput (no EditorState needed)."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Unicode
  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.Diagnostics, as: RowDiagnostics
  alias MingaEditor.FileTree.Row
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.Shell.Traditional.TreeRenderer
  alias MingaEditor.Shell.Traditional.TreeRenderer.RenderInput
  alias MingaEditor.UI.Theme

  import MingaEditor.RenderPipeline.TestHelpers, only: [gui_state: 1]

  @moduletag :tmp_dir

  defp sample_tree(tmp_dir) do
    # Create real files so FileTree.visible_entries works
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/main.ex"), "defmodule Main do\nend\n")
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.write!(Path.join(tmp_dir, "test/main_test.exs"), "defmodule MainTest do\nend\n")

    tree = FileTree.new(tmp_dir, width: 20)
    FileTree.expand_path(tree, Path.join(tmp_dir, "lib"))
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
      root = Path.join(tmp_dir, "minga")

      input = %RenderInput{
        tree: sample_tree(root),
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
      # Contains the folder open icon (nf-md-folder-open U+F0256) and project/root context.
      assert String.contains?(text, "\u{F0256}")
      assert String.contains?(text, "minga")
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

    test "renders no off-rect rows for zero-height panels", %{tmp_dir: tmp_dir} do
      draws =
        TreeRenderer.render(%RenderInput{
          tree: sample_tree(tmp_dir),
          rect: {0, 0, 20, 0},
          focused: false,
          theme: Theme.get!(:doom_one),
          active_path: nil
        })

      assert draws == []
    end

    test "height-one panels render only the header and one separator cell", %{tmp_dir: tmp_dir} do
      draws =
        TreeRenderer.render(%RenderInput{
          tree: sample_tree(tmp_dir),
          rect: {0, 0, 20, 1},
          focused: false,
          theme: Theme.get!(:doom_one),
          active_path: nil
        })

      assert Enum.any?(draws, fn {row, col, text, _style} ->
               row == 0 and col == 0 and String.contains?(text, "\u{F0256}")
             end)

      sep_draws =
        Enum.filter(draws, fn {_row, col, text, _style} -> col == 20 and text == "│" end)

      assert [{0, 20, "│", _style}] = sep_draws
      refute Enum.any?(draws, fn {row, col, _text, _style} -> row > 0 and col < 20 end)
    end

    test "production state render shows active and dirty row states", %{tmp_dir: tmp_dir} do
      active_path = Path.join(tmp_dir, "active.ex")
      dirty_path = Path.join(tmp_dir, "dirty.ex")
      File.write!(active_path, "active")
      File.write!(dirty_path, "dirty")

      {:ok, active_buf} = BufferProcess.start_link(file_path: active_path)
      {:ok, dirty_buf} = BufferProcess.start_link(file_path: dirty_path)
      :ok = BufferProcess.insert_text(dirty_buf, "!")

      tree = FileTree.new(tmp_dir, width: 32)
      file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)

      state = gui_state(rows: 10, cols: 80)
      state = put_in(state.workspace.file_tree, file_tree)

      state =
        put_in(state.workspace.buffers, %Buffers{
          active: active_buf,
          list: [active_buf, dirty_buf],
          active_index: 0
        })

      draws = TreeRenderer.render(state)
      all_text = draw_texts(draws)

      assert String.contains?(all_text, "active.ex")
      assert String.contains?(all_text, "dirty.ex")
      assert String.contains?(all_text, "●")

      {_row, _col, _text, active_style} = draw_containing(draws, "active.ex")
      assert active_style.fg == Theme.get!(:doom_one).tree.active_fg
      assert active_style.bold == true

      {_row, _col, _text, dirty_style} = draw_matching(draws, "●")
      assert dirty_style.fg == Theme.get!(:doom_one).tree.modified_fg
    end

    test "production state render shows loading and error messages", %{tmp_dir: tmp_dir} do
      tree = FileTree.new(tmp_dir, width: 24)
      file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)
      theme = Theme.get!(:doom_one)

      loading_draws =
        TreeRenderer.render(%{
          workspace: %{
            file_tree: FileTreeState.loading(file_tree),
            viewport: %{rows: 5, cols: 80},
            buffers: %{active: nil, list: [], active_index: 0}
          },
          theme: theme
        })

      error_draws =
        TreeRenderer.render(%{
          workspace: %{
            file_tree: FileTreeState.error(file_tree, :eacces),
            viewport: %{rows: 5, cols: 80},
            buffers: %{active: nil, list: [], active_index: 0}
          },
          theme: theme
        })

      assert draw_texts(loading_draws) =~ "Loading files"
      assert draw_texts(error_draws) =~ "File tree error"
      assert draw_texts(error_draws) =~ "permission denied"

      for draws <- [loading_draws, error_draws] do
        assert Enum.any?(draws, fn {_row, col, text, _style} -> col == 24 and text == "│" end)
      end
    end

    test "renders empty loading and error rows without layout drift", %{tmp_dir: tmp_dir} do
      tree = FileTree.new(tmp_dir, width: 24)
      theme = Theme.get!(:doom_one)

      empty_draws =
        TreeRenderer.render(%RenderInput{
          tree: tree,
          rect: {0, 0, 24, 5},
          focused: false,
          theme: theme,
          active_path: nil,
          rows: []
        })

      loading_draws =
        TreeRenderer.render(%RenderInput{
          tree: tree,
          rect: {0, 0, 24, 5},
          focused: false,
          theme: theme,
          active_path: nil,
          rows: [],
          status: :loading
        })

      error_draws =
        TreeRenderer.render(%RenderInput{
          tree: tree,
          rect: {0, 0, 24, 5},
          focused: false,
          theme: theme,
          active_path: nil,
          rows: [],
          status: {:error, "permission denied"}
        })

      assert draw_texts(empty_draws) =~ "No files yet"
      assert draw_texts(loading_draws) =~ "Loading files"
      assert draw_texts(error_draws) =~ "File tree error"
      assert draw_texts(error_draws) =~ "permission denied"

      for draws <- [empty_draws, loading_draws, error_draws] do
        assert Enum.any?(draws, fn {_row, col, text, _style} -> col == 24 and text == "│" end)
        refute Enum.any?(draws, fn {row, col, _text, _style} -> row < 0 or col < 0 end)
      end
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

      # Disclosure symbols replace heavy connector branch art.
      assert String.contains?(all_text, "▾ ")
      assert String.contains?(all_text, "▸ ")
      refute String.contains?(all_text, "├─")
      refute String.contains?(all_text, "└─")
      # Expanded lib/ should still produce a quiet ancestor guide for its children.
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
      # structure segment, icon segment, name segment
      row1_draws = Enum.filter(draws, fn {r, _c, _t, _s} -> r == 1 end)
      assert length(row1_draws) >= 3
    end

    test "uses stable disclosure icon and name columns", %{tmp_dir: tmp_dir} do
      draws =
        TreeRenderer.render(%RenderInput{
          tree: sample_tree(tmp_dir),
          rect: {0, 0, 30, 10},
          focused: false,
          theme: Theme.get!(:doom_one),
          active_path: nil
        })

      assert {1, 0, "▾ ", _style} = draw_matching(draws, "▾ ")
      assert {1, 2, "\u{F0256} ", _style} = draw_matching(draws, "\u{F0256} ")
      assert {1, 4, name, _style} = draw_containing(draws, "lib/")
      assert String.starts_with?(name, "lib/")
    end

    @tag timeout: 180_000
    test "renders production state for large trees around the selected row", %{tmp_dir: tmp_dir} do
      for index <- 1..600 do
        File.write!(
          Path.join(tmp_dir, "file_#{String.pad_leading(Integer.to_string(index), 3, "0")}.ex"),
          ""
        )
      end

      tree = FileTree.new(tmp_dir, width: 32) |> FileTree.select(599)
      file_tree = FileTreeState.open(%FileTreeState{}, tree, nil)

      draws =
        TreeRenderer.render(%{
          workspace: %{
            file_tree: %{file_tree | focused: true},
            viewport: %{rows: 10, cols: 80},
            buffers: %{active: nil, list: [], active_index: 0}
          },
          theme: Theme.get!(:doom_one)
        })

      all_text = draw_texts(draws)

      for name <- [
            "file_594.ex",
            "file_595.ex",
            "file_596.ex",
            "file_597.ex",
            "file_598.ex",
            "file_599.ex",
            "file_600.ex"
          ] do
        assert String.contains?(all_text, name)
      end

      refute String.contains?(all_text, "file_593.ex")
      refute String.contains?(all_text, "file_001.ex")
      assert String.contains?(all_text, "file_600.ex")
    end

    @tag timeout: 180_000
    test "renders large RenderInput trees around the selected row", %{tmp_dir: tmp_dir} do
      for index <- 1..600 do
        File.write!(
          Path.join(tmp_dir, "file_#{String.pad_leading(Integer.to_string(index), 3, "0")}.ex"),
          ""
        )
      end

      tree = FileTree.new(tmp_dir, width: 32) |> FileTree.select(599)

      draws =
        TreeRenderer.render(%RenderInput{
          tree: tree,
          rect: {0, 0, 32, 8},
          focused: true,
          theme: Theme.get!(:doom_one),
          active_path: nil
        })

      all_text = draw_texts(draws)

      for name <- [
            "file_594.ex",
            "file_595.ex",
            "file_596.ex",
            "file_597.ex",
            "file_598.ex",
            "file_599.ex",
            "file_600.ex"
          ] do
        assert String.contains?(all_text, name)
      end

      refute String.contains?(all_text, "file_593.ex")
      refute String.contains?(all_text, "file_001.ex")
    end

    test "renders supplied semantic rows", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "main.ex")
      File.write!(file_path, "defmodule Main do\nend\n")
      tree = FileTree.new(tmp_dir, width: 30)

      rows = [
        Row.new(
          id: file_path,
          path: file_path,
          relative_path: "main.ex",
          name: "main.ex",
          directory?: false,
          expanded?: false,
          selected?: true,
          focused?: true,
          active?: true,
          dirty?: true,
          git_status: :modified,
          depth: 0,
          guides: [],
          last_child?: true
        )
      ]

      input = %RenderInput{
        tree: tree,
        rect: {0, 0, 30, 5},
        focused: false,
        theme: Theme.get!(:doom_one),
        active_path: nil,
        rows: rows
      }

      draws = TreeRenderer.render(input)
      all_text = Enum.map_join(draws, fn {_r, _c, text, _s} -> text end)

      assert String.contains?(all_text, "main.ex")
      assert String.contains?(all_text, "●")
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

    test "active plus selected keeps selection background and active name accent", %{
      tmp_dir: tmp_dir
    } do
      theme = Theme.get!(:doom_one)
      row = semantic_file_row(tmp_dir, selected?: true, focused?: true, active?: true)

      draws = render_semantic_rows(tmp_dir, [row], theme)
      {_r, _c, _text, style} = draw_containing(draws, "main.ex")

      assert style.fg == theme.tree.active_fg
      assert style.bg == theme.tree.cursor_bg
      assert style.bold == true
    end

    test "active plus git modified preserves independent git marker", %{tmp_dir: tmp_dir} do
      theme = Theme.get!(:doom_one)
      row = semantic_file_row(tmp_dir, active?: true, git_status: :modified)

      draws = render_semantic_rows(tmp_dir, [row], theme)
      {_r, _c, _text, name_style} = draw_containing(draws, "main.ex")
      {_r, _c, _text, git_style} = draw_matching(draws, " ●")

      assert name_style.fg == theme.tree.active_fg
      assert git_style.fg == theme.tree.git_modified_fg
      assert git_style.bg == theme.tree.bg
    end

    test "selected plus dirty keeps dirty marker visible on selection background", %{
      tmp_dir: tmp_dir
    } do
      theme = Theme.get!(:doom_one)
      row = semantic_file_row(tmp_dir, selected?: true, focused?: true, dirty?: true)

      draws = render_semantic_rows(tmp_dir, [row], theme)
      {_r, _c, _text, dirty_style} = draw_matching(draws, "●")

      assert dirty_style.fg == theme.tree.modified_fg
      assert dirty_style.bg == theme.tree.cursor_bg
      assert dirty_style.bold == true
    end

    test "diagnostic dirty and git markers remain separate on selected rows", %{tmp_dir: tmp_dir} do
      theme = Theme.get!(:doom_one)

      row =
        semantic_file_row(tmp_dir,
          selected?: true,
          focused?: true,
          dirty?: true,
          git_status: :conflict,
          diagnostics: RowDiagnostics.new({2, 0, 0, 0})
        )

      draws = render_semantic_rows(tmp_dir, [row], theme)
      {_r, _c, _text, diagnostic_style} = draw_matching(draws, "✖2")
      {_r, _c, _text, dirty_style} = draw_matching(draws, "●")
      {_r, _c, _text, git_style} = draw_matching(draws, " !")

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

      draws =
        TreeRenderer.render(%RenderInput{
          tree: FileTree.new(tmp_dir, width: 12),
          rect: {0, 0, 12, 5},
          focused: false,
          theme: Theme.get!(:doom_one),
          active_path: nil,
          rows: [row]
        })

      row_text =
        draws
        |> Enum.filter(fn {r, c, _t, _s} -> r == 1 and c < 12 end)
        |> Enum.sort_by(fn {_r, c, _t, _s} -> c end)
        |> Enum.map_join(fn {_r, _c, text, _s} -> text end)

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

    test "deep nested unicode rows preserve basename tail and status within display width", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "lib/minga_editor/shell/traditional/非常に長い_component_view.ex")

      row =
        Row.new(
          id: path,
          path: path,
          relative_path: "lib/minga_editor/shell/traditional/非常に長い_component_view.ex",
          name: "非常に長い_component_view.ex",
          directory?: false,
          expanded?: false,
          selected?: true,
          focused?: true,
          active?: false,
          dirty?: true,
          git_status: :modified,
          diagnostics: RowDiagnostics.new({0, 1, 0, 0}),
          depth: 8,
          guides: [true, true, false, true, false, true, true, false],
          last_child?: true
        )

      draws =
        TreeRenderer.render(%RenderInput{
          tree: FileTree.new(tmp_dir, width: 18),
          rect: {0, 0, 18, 5},
          focused: true,
          theme: Theme.get!(:doom_one),
          active_path: nil,
          rows: [row]
        })

      row_text = rendered_row_text(draws, 1, 18)

      assert Unicode.display_width(row_text) <= 18
      assert String.contains?(row_text, "…")
      assert String.contains?(row_text, ".ex")
      assert draw_matching(draws, "⚠") != nil
      assert draw_matching(draws, "●") != nil
      assert draw_matching(draws, " ●") != nil
    end

    test "deep nested fixture renders long unicode children within narrow tree width", %{
      tmp_dir: tmp_dir
    } do
      tree = nested_fixture_tree(tmp_dir, width: 18)

      target_path =
        Path.join(tmp_dir, "lib/minga_editor/shell/traditional/非常に長い_component_view.ex")

      draws =
        TreeRenderer.render(%RenderInput{
          tree: tree,
          rect: {0, 0, 18, 12},
          focused: false,
          theme: Theme.get!(:doom_one),
          active_path: nil,
          git_status: %{target_path => :modified},
          dirty_paths: MapSet.new([target_path])
        })

      row_draws = Enum.filter(draws, fn {_r, _c, text, _s} -> String.contains?(text, ".ex") end)

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

      draws =
        TreeRenderer.render(%RenderInput{
          tree: FileTree.new(tmp_dir, width: 10),
          rect: {0, 0, 10, 5},
          focused: false,
          theme: Theme.get!(:doom_one),
          active_path: nil,
          rows: [row]
        })

      row_text =
        draws
        |> Enum.filter(fn {r, c, _t, _s} -> r == 1 and c < 10 end)
        |> Enum.sort_by(fn {_r, c, _t, _s} -> c end)
        |> Enum.map_join(fn {_r, _c, text, _s} -> text end)

      assert Unicode.display_width(row_text) <= 10
      assert String.contains?(row_text, "✖9+")
    end

    test "unfocused selected row uses subdued selection background", %{tmp_dir: tmp_dir} do
      theme = Theme.get!(:doom_one)
      row = semantic_file_row(tmp_dir, selected?: true, focused?: false)

      draws = render_semantic_rows(tmp_dir, [row], theme)
      {_r, _c, _text, style} = draw_containing(draws, "main.ex")

      assert style.bg == theme.tree.separator_fg
      refute style.bg == theme.tree.cursor_bg
    end
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

    FileTree.new(tmp_dir, width: width)
    |> FileTree.expand_path(Path.join(tmp_dir, "lib"))
    |> FileTree.expand_path(Path.join(tmp_dir, "lib/minga_editor"))
    |> FileTree.expand_path(Path.join(tmp_dir, "lib/minga_editor/shell"))
    |> FileTree.expand_path(deep_dir)
  end

  defp rendered_row_text(draws, row, width) do
    draws
    |> Enum.filter(fn {draw_row, col, _t, _s} -> draw_row == row and col < width end)
    |> Enum.sort_by(fn {_r, col, _t, _s} -> col end)
    |> Enum.map_join(fn {_r, _c, text, _s} -> text end)
  end

  defp semantic_file_row(tmp_dir, attrs) do
    file_path = Path.join(tmp_dir, "main.ex")

    Row.new(
      Keyword.merge(
        [
          id: file_path,
          path: file_path,
          relative_path: "main.ex",
          name: "main.ex",
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

  defp render_semantic_rows(tmp_dir, rows, theme) do
    TreeRenderer.render(%RenderInput{
      tree: FileTree.new(tmp_dir, width: 30),
      rect: {0, 0, 30, 5},
      focused: false,
      theme: theme,
      active_path: nil,
      rows: rows
    })
  end

  defp draw_texts(draws) do
    Enum.map_join(draws, fn {_r, _c, text, _style} -> text end)
  end

  defp draw_containing(draws, text) do
    Enum.find(draws, fn {_r, _c, draw_text, _style} -> String.contains?(draw_text, text) end)
  end

  defp draw_matching(draws, text) do
    Enum.find(draws, fn {_r, _c, draw_text, _style} -> draw_text == text end)
  end

  defp draw_col({_r, col, _text, _style}), do: col

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

      # The entry at depth 1 should keep a quiet structure column without heavy branch art.
      assert String.contains?(all_text, "│ ") or String.contains?(all_text, "  ")
      refute String.contains?(all_text, "└─")
      refute String.contains?(all_text, "├─")
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
