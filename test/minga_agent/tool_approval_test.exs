defmodule MingaAgent.ToolApprovalTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ToolApproval

  describe "build_preview/2" do
    test "builds command preview for shell tools" do
      preview = ToolApproval.build_preview("shell", %{"command" => "rm -rf tmp/build"})

      assert preview.kind == :command
      assert preview.summary == "rm -rf tmp/build"
      assert "$ rm -rf tmp/build" in preview.lines
    end

    test "builds diff preview for write_file tools" do
      path =
        Path.join(
          System.tmp_dir!(),
          "minga-approval-preview-#{System.unique_integer([:positive])}.txt"
        )

      File.write!(path, "old\n")
      on_exit(fn -> File.rm(path) end)

      preview = ToolApproval.build_preview("write_file", %{"path" => path, "content" => "new\n"})

      assert preview.kind == :diff
      assert preview.summary == path
      assert "-old" in preview.lines
      assert "+new" in preview.lines
    end

    test "keeps blank-line-only write_file diffs visible" do
      path =
        Path.join(
          System.tmp_dir!(),
          "minga-approval-preview-#{System.unique_integer([:positive])}.txt"
        )

      File.write!(path, "old")
      on_exit(fn -> File.rm(path) end)

      preview = ToolApproval.build_preview("write_file", %{"path" => path, "content" => "old\n"})

      assert "+" in preview.lines
      refute "No textual changes detected" in preview.lines
    end

    test "truncates oversized preview lines" do
      preview = ToolApproval.build_preview("shell", %{"command" => String.duplicate("x", 1_000)})

      assert Enum.all?(preview.lines, &(String.length(&1) <= 300))
    end

    test "builds target preview for edit_file tools" do
      preview =
        ToolApproval.build_preview("edit_file", %{
          "path" => "lib/a.ex",
          "old_text" => "old",
          "new_text" => "new"
        })

      assert preview.kind == :target
      assert preview.summary == "lib/a.ex"
      assert "file: lib/a.ex" in preview.lines
      assert ~s(replace "old" with "new") in preview.lines
    end

    test "builds edit-count preview for multi_edit_file tools" do
      preview =
        ToolApproval.build_preview("multi_edit_file", %{
          "path" => "lib/a.ex",
          "edits" => [%{}, %{}]
        })

      assert preview.kind == :target
      assert preview.summary == "lib/a.ex"
      assert "2 edit(s)" in preview.lines
    end

    test "builds hunk-count preview for apply_diff tools" do
      preview =
        ToolApproval.build_preview("apply_diff", %{
          "path" => "lib/a.ex",
          "diff" => "@@ -1,1 +1,1 @@\n-old\n+new\n"
        })

      assert preview.kind == :target
      assert preview.summary == "lib/a.ex"
      assert "1 diff hunk(s)" in preview.lines
    end

    test "builds target preview for git_stage tools" do
      preview = ToolApproval.build_preview("git_stage", %{"paths" => ["lib/a.ex", "mix.exs"]})

      assert preview.kind == :target
      assert preview.summary == "lib/a.ex, mix.exs"
      assert "paths: lib/a.ex, mix.exs" in preview.lines
    end

    test "builds commit-message preview for git_commit tools" do
      preview = ToolApproval.build_preview("git_commit", %{"message" => "fix approval flow"})

      assert preview.kind == :target
      assert preview.summary == "fix approval flow"
      assert "commit message: fix approval flow" in preview.lines
    end
  end
end
