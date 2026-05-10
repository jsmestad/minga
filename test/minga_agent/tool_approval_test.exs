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

      preview = ToolApproval.build_preview("write_file", %{"path" => path, "content" => "new\n"})

      assert preview.kind == :diff
      assert preview.summary == path
      assert "-old" in preview.lines
      assert "+new" in preview.lines

      File.rm(path)
    end
  end
end
