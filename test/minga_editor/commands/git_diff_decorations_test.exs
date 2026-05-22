defmodule MingaEditor.Commands.GitDiffDecorationsTest do
  @moduledoc "Tests for diff view decoration application and sign generation."
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Core.DiffView
  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub
  alias MingaEditor.Commands.Git, as: GitCommands
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport

  describe "diff sign generation" do
    test "produces :added signs for added lines" do
      metadata = [
        %{type: :context, original_line: 0, fold_count: nil, word_changes: nil},
        %{type: :added, original_line: 1, fold_count: nil, word_changes: nil},
        %{type: :added, original_line: 2, fold_count: nil, word_changes: nil},
        %{type: :context, original_line: 3, fold_count: nil, word_changes: nil}
      ]

      signs = diff_signs_from_metadata(metadata)

      assert signs[1] == :added
      assert signs[2] == :added
      refute Map.has_key?(signs, 0)
      refute Map.has_key?(signs, 3)
    end

    test "produces :removed signs for removed lines" do
      metadata = [
        %{type: :context, original_line: 0, fold_count: nil, word_changes: nil},
        %{type: :removed, original_line: nil, fold_count: nil, word_changes: nil},
        %{type: :context, original_line: 1, fold_count: nil, word_changes: nil}
      ]

      signs = diff_signs_from_metadata(metadata)

      assert signs[1] == :removed
      refute Map.has_key?(signs, 0)
      refute Map.has_key?(signs, 2)
    end

    test "handles mixed added and removed lines" do
      metadata = [
        %{type: :removed, original_line: nil, fold_count: nil, word_changes: nil},
        %{type: :added, original_line: 0, fold_count: nil, word_changes: nil},
        %{type: :fold, original_line: nil, fold_count: 5, word_changes: nil}
      ]

      signs = diff_signs_from_metadata(metadata)

      assert signs[0] == :removed
      assert signs[1] == :added
      refute Map.has_key?(signs, 2)
    end

    test "returns empty map for all context lines" do
      metadata = [
        %{type: :context, original_line: 0, fold_count: nil, word_changes: nil},
        %{type: :context, original_line: 1, fold_count: nil, word_changes: nil}
      ]

      signs = diff_signs_from_metadata(metadata)
      assert signs == %{}
    end
  end

  describe "diff view integration" do
    test "DiffView.build produces metadata suitable for decoration" do
      result = DiffView.build("old line\n", "new line\n")

      assert is_list(result.line_metadata)
      assert result.line_metadata != []

      types = Enum.map(result.line_metadata, & &1.type)
      assert :removed in types or :added in types
    end

    test "decoration application creates highlights for added/removed lines" do
      metadata = [
        %{type: :context, original_line: 0, fold_count: nil, word_changes: nil},
        %{type: :removed, original_line: nil, fold_count: nil, word_changes: nil},
        %{type: :added, original_line: 1, fold_count: nil, word_changes: nil},
        %{type: :fold, original_line: nil, fold_count: 3, word_changes: nil}
      ]

      decs =
        metadata
        |> Enum.with_index()
        |> Enum.reduce(Decorations.new(), fn {meta, idx}, decs ->
          case meta.type do
            :added ->
              {_id, decs} =
                Decorations.add_highlight(decs, {idx, 0}, {idx, 9999},
                  style: Minga.Core.Face.new(bg: 0x224422),
                  group: :diff
                )

              decs

            :removed ->
              {_id, decs} =
                Decorations.add_highlight(decs, {idx, 0}, {idx, 9999},
                  style: Minga.Core.Face.new(bg: 0x442222),
                  group: :diff
                )

              decs

            _ ->
              decs
          end
        end)

      highlights = Decorations.highlights_for_lines(decs, 0, 3)
      assert length(highlights) == 2
    end

    test "refresh_diff_views_for_buffer updates every diff for the saved source" do
      git_root = unique_git_root()
      rel_path = "file.txt"
      GitStub.set_head(git_root, rel_path, "old\n")
      on_exit(fn -> GitStub.clear(git_root) end)

      {:ok, source_buf} = Buffer.start_link(content: "new\n")
      {:ok, diff_one} = Buffer.start_link(content: "stale one")
      {:ok, diff_two} = Buffer.start_link(content: "stale two")

      info = %{
        source_buf: source_buf,
        git_root: git_root,
        rel_path: rel_path,
        staged: false,
        line_metadata: [],
        hunk_lines: []
      }

      state = %{
        build_state()
        | diff_views: %{
            diff_one => info,
            diff_two => info
          }
      }

      state = GitCommands.refresh_diff_views_for_buffer(state, source_buf)

      assert buffer_content(diff_one) =~ "new"
      assert buffer_content(diff_two) =~ "new"
      assert state.diff_views[diff_one].line_metadata != []
      assert state.diff_views[diff_two].line_metadata != []
    end

    test "diff_hunk_position reports the hunk containing the cursor" do
      {:ok, diff_buf} = Buffer.start_link(content: "placeholder")

      state =
        build_state()
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: nil,
          git_root: "/tmp/repo",
          rel_path: "file.txt",
          staged: false,
          line_metadata: [],
          hunk_lines: [1, 5]
        })

      assert GitCommands.diff_hunk_position(state, diff_buf, 0) == {1, 2}
      assert GitCommands.diff_hunk_position(state, diff_buf, 3) == {2, 2}
      assert GitCommands.diff_hunk_position(state, diff_buf, 7) == {2, 2}
    end

    test "revert hunk from diff view ignores context lines" do
      git_root = unique_git_root()
      rel_path = "file.txt"
      base = "old\nsame\ntrailing\n"
      current = "new\nsame\ntrailing\n"

      GitStub.set_head(git_root, rel_path, base)
      on_exit(fn -> GitStub.clear(git_root) end)

      diff_result = DiffView.build(base, current)

      context_line =
        Enum.find_index(diff_result.line_metadata, fn meta ->
          meta.type == :context and meta.original_line == 2
        end)

      {:ok, source_buf} = Buffer.start_link(content: current)
      {:ok, diff_buf} = Buffer.start_link(content: diff_result.text)
      Buffer.move_to(diff_buf, {context_line, 0})

      state =
        build_state()
        |> EditorState.add_buffer(source_buf)
        |> EditorState.add_buffer(diff_buf)
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: source_buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: false,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines
        })

      _state = GitCommands.execute(state, :git_revert_hunk)

      assert buffer_content(source_buf) == current
    end

    test "non-GUI diff layout toggle leaves unified diff unchanged" do
      git_root = unique_git_root()
      rel_path = "file.txt"
      base = "old\n"
      current = "new\n"

      GitStub.set_head(git_root, rel_path, base)
      on_exit(fn -> GitStub.clear(git_root) end)

      diff_result = DiffView.build(base, current)
      {:ok, source_buf} = Buffer.start_link(content: current)
      {:ok, diff_buf} = Buffer.start_link(content: diff_result.text)

      state =
        build_state()
        |> EditorState.add_buffer(source_buf)
        |> EditorState.add_buffer(diff_buf)
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: source_buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: false,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines,
          view_mode: :unified,
          pane_width: 20
        })

      state = GitCommands.execute(state, :git_diff_toggle_layout)

      assert EditorState.status_msg(state) == "Side-by-side diff is only available in GUI"
      assert state.diff_views[diff_buf].view_mode == :unified
      refute buffer_content(diff_buf) =~ " │ "
    end

    test "stage hunk from side-by-side diff preserves the side-by-side layout" do
      git_root = unique_git_root()
      rel_path = "file.txt"
      base = "old\n"
      current = "new\n"

      GitStub.set_head(git_root, rel_path, base)
      on_exit(fn -> GitStub.clear(git_root) end)

      diff_result = DiffView.build_side_by_side(base, current, 20)

      changed_line =
        Enum.find_index(diff_result.line_metadata, fn meta ->
          meta.left_type == :removed and meta.right_type == :added
        end)

      {:ok, source_buf} = Buffer.start_link(content: current)
      {:ok, diff_buf} = Buffer.start_link(content: diff_result.text)
      Buffer.move_to(diff_buf, {changed_line, 0})

      state =
        build_state()
        |> EditorState.set_viewport(Viewport.new(24, 40))
        |> Map.put(:capabilities, %Capabilities{frontend_type: :native_gui})
        |> EditorState.add_buffer(source_buf)
        |> EditorState.add_buffer(diff_buf)
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: source_buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: false,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines,
          view_mode: :side_by_side,
          pane_width: 20
        })

      state = GitCommands.execute(state, :git_stage_hunk)

      assert EditorState.status_msg(state) == "Hunk 1/1 staged"
      assert state.diff_views[diff_buf].view_mode == :side_by_side
    end

    test "revert hunk from side-by-side diff preserves the side-by-side layout" do
      git_root = unique_git_root()
      rel_path = "file.txt"
      base = "old\n"
      current = "new\n"

      GitStub.set_head(git_root, rel_path, base)
      on_exit(fn -> GitStub.clear(git_root) end)

      diff_result = DiffView.build_side_by_side(base, current, 20)

      changed_line =
        Enum.find_index(diff_result.line_metadata, fn meta ->
          meta.left_type == :removed and meta.right_type == :added
        end)

      {:ok, source_buf} = Buffer.start_link(content: current)
      {:ok, diff_buf} = Buffer.start_link(content: diff_result.text)
      Buffer.move_to(diff_buf, {changed_line, 0})

      state =
        build_state()
        |> EditorState.set_viewport(Viewport.new(24, 40))
        |> Map.put(:capabilities, %Capabilities{frontend_type: :native_gui})
        |> EditorState.add_buffer(source_buf)
        |> EditorState.add_buffer(diff_buf)
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: source_buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: false,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines,
          view_mode: :side_by_side,
          pane_width: 20
        })

      state = GitCommands.execute(state, :git_revert_hunk)

      assert EditorState.status_msg(state) == "Hunk 1/1 reverted"
      assert state.diff_views[diff_buf].view_mode == :side_by_side
      assert buffer_content(source_buf) == base
    end

    test "side-by-side diff decorations include word highlights on both panes" do
      git_root = unique_git_root()
      rel_path = "file.txt"
      base = "alpha old\n"
      current = "alpha new\n"

      GitStub.set_head(git_root, rel_path, base)
      on_exit(fn -> GitStub.clear(git_root) end)

      diff_result = DiffView.build(base, current)
      {:ok, source_buf} = Buffer.start_link(content: current)
      {:ok, diff_buf} = Buffer.start_link(content: diff_result.text)

      state =
        build_state()
        |> EditorState.set_viewport(Viewport.new(24, 40))
        |> Map.put(:capabilities, %Capabilities{frontend_type: :native_gui})
        |> EditorState.add_buffer(source_buf)
        |> EditorState.add_buffer(diff_buf)
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: source_buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: false,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines,
          view_mode: :unified,
          pane_width: 20
        })

      state = GitCommands.execute(state, :git_diff_toggle_layout)

      highlights =
        Buffer.decorations(diff_buf)
        |> Decorations.highlights_for_line(0)
        |> Enum.filter(&(&1.group == :diff_word))
        |> Enum.sort_by(& &1.start)

      assert Enum.map(highlights, &{&1.start, &1.end_}) == [
               {{0, 6}, {0, 9}},
               {{0, 29}, {0, 32}}
             ]

      assert state.diff_views[diff_buf].view_mode == :side_by_side
    end

    test "stage hunk from diff view refreshes stale views instead of staging by index" do
      git_root = unique_git_root()
      rel_path = "file.txt"
      base = "one\ntwo\nthree\n"
      current = "one\nTWO\nthree\n"
      changed_current = "one\nTWO\nthree\nfour\n"

      GitStub.set_head(git_root, rel_path, base)
      on_exit(fn -> GitStub.clear(git_root) end)

      diff_result = DiffView.build(base, current)

      added_line =
        Enum.find_index(diff_result.line_metadata, fn meta ->
          meta.type == :added
        end)

      {:ok, source_buf} = Buffer.start_link(content: current)
      {:ok, diff_buf} = Buffer.start_link(content: diff_result.text)
      Buffer.move_to(diff_buf, {added_line, 0})
      Buffer.replace_content(source_buf, changed_current)

      state =
        build_state()
        |> EditorState.add_buffer(source_buf)
        |> EditorState.add_buffer(diff_buf)
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: source_buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: false,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines
        })

      state = GitCommands.execute(state, :git_stage_hunk)

      assert buffer_content(diff_buf) =~ "four"
      assert EditorState.status_msg(state) == "Diff view changed; retry hunk action"
    end

    test "revert hunk from staged diff view does not mutate working buffer" do
      git_root = unique_git_root()
      rel_path = "file.txt"
      base = "old\n"
      staged = "staged\n"
      working = "working\n"

      GitStub.set_head(git_root, rel_path, base)
      on_exit(fn -> GitStub.clear(git_root) end)

      diff_result = DiffView.build(base, staged)

      added_line =
        Enum.find_index(diff_result.line_metadata, fn meta ->
          meta.type == :added
        end)

      {:ok, source_buf} = Buffer.start_link(content: working)
      {:ok, diff_buf} = Buffer.start_link(content: diff_result.text)
      Buffer.move_to(diff_buf, {added_line, 0})

      state =
        build_state()
        |> EditorState.add_buffer(source_buf)
        |> EditorState.add_buffer(diff_buf)
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: source_buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: true,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines
        })

      state = GitCommands.execute(state, :git_revert_hunk)

      assert buffer_content(source_buf) == working
      assert EditorState.status_msg(state) == "Cannot revert from a staged diff view"
    end

    test "GUI diff layout toggle rebuilds active diff as side-by-side" do
      git_root = unique_git_root()
      rel_path = "file.txt"
      base = "old\n"
      current = "new\n"

      GitStub.set_head(git_root, rel_path, base)
      on_exit(fn -> GitStub.clear(git_root) end)

      diff_result = DiffView.build(base, current)
      {:ok, source_buf} = Buffer.start_link(content: current)
      {:ok, diff_buf} = Buffer.start_link(content: diff_result.text)

      state =
        build_state()
        |> Map.put(:capabilities, %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui})
        |> EditorState.add_buffer(source_buf)
        |> EditorState.add_buffer(diff_buf)
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: source_buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: false,
          line_metadata: diff_result.line_metadata,
          hunk_lines: diff_result.hunk_lines,
          view_mode: :unified,
          pane_width: 20
        })

      state = GitCommands.execute(state, :git_diff_toggle_layout)

      assert buffer_content(diff_buf) =~ " │ "
      assert state.diff_views[diff_buf].view_mode == :side_by_side
      assert EditorState.status_msg(state) == "Diff layout: side-by-side"
    end

    test "staged diff toggle treats staged deletions as empty index content" do
      git_root = unique_git_root()
      rel_path = "deleted.txt"
      abs_path = Path.join(git_root, rel_path)

      GitStub.set_head(git_root, rel_path, "old contents\n")

      GitStub.set_status(git_root, [
        %Git.StatusEntry{path: rel_path, status: :deleted, staged: true}
      ])

      on_exit(fn -> GitStub.clear(git_root) end)

      {:ok, source_buf} = Buffer.start_link(content: "old contents\n")
      {:ok, diff_buf} = Buffer.start_link(content: "placeholder")

      {:ok, git_buf} =
        Minga.Git.Buffer.start_link(
          git_root: git_root,
          file_path: abs_path,
          initial_content: "old contents\n"
        )

      put_tracking(source_buf, git_buf)

      state =
        build_state()
        |> EditorState.add_buffer(diff_buf)
        |> EditorState.register_diff_view(diff_buf, %{
          source_buf: source_buf,
          git_root: git_root,
          rel_path: rel_path,
          staged: false,
          line_metadata: [],
          hunk_lines: []
        })

      state = GitCommands.execute(state, :git_diff_toggle_staged)
      active_buf = state.workspace.buffers.active

      assert active_buf != diff_buf
      assert buffer_content(active_buf) =~ "old contents"
      refute buffer_content(active_buf) =~ "No changes"
      assert state.diff_views[active_buf].staged == true
    end
  end

  defp build_state do
    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{viewport: Viewport.new(24, 80)}
    }
  end

  defp buffer_content(buf) do
    {content, _cursor} = Buffer.content_and_cursor(buf)
    content
  end

  defp unique_git_root do
    Path.join(System.tmp_dir!(), "minga-diff-test-#{System.unique_integer([:positive])}")
  end

  defp put_tracking(source_buf, git_buf) do
    table = Minga.Git.Tracker.Registry

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ets.insert(table, {source_buf, git_buf})
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table, source_buf) end)
  end

  # Mirrors the private function in ContentHelpers for testability
  defp diff_signs_from_metadata(line_metadata) do
    line_metadata
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {%{type: :added}, idx}, acc -> Map.put(acc, idx, :added)
      {%{type: :removed}, idx}, acc -> Map.put(acc, idx, :removed)
      _, acc -> acc
    end)
  end
end
