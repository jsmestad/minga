defmodule MingaAgent.Tools.ApplyDiffTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.Tools
  alias MingaAgent.Tools.ApplyDiff

  @moduletag :tmp_dir

  describe "apply/2" do
    test "applies a unified diff hunk to content" do
      diff = """
      --- a/example.txt
      +++ b/example.txt
      @@ -1,3 +1,3 @@
       one
      -two
      +TWO
       three
      """

      assert {:ok, %{content: content, hunks: 1}} =
               ApplyDiff.apply_to_content("one\ntwo\nthree\n", diff)

      assert content == "one\nTWO\nthree\n"
    end

    test "applies multiple hunks sequentially" do
      diff = """
      @@ -1,2 +1,2 @@
      -one
      +ONE
       two
      @@ -4,2 +4,2 @@
       four
      -five
      +FIVE
      """

      assert {:ok, %{content: content, hunks: 2}} =
               ApplyDiff.apply_to_content("one\ntwo\nthree\nfour\nfive\n", diff)

      assert content == "ONE\ntwo\nthree\nfour\nFIVE\n"
    end

    test "applies one-line hunks whose header omits explicit counts" do
      diff = """
      @@ -1 +1 @@
      -old
      +new
      """

      assert {:ok, %{content: content, hunks: 1}} = ApplyDiff.apply_to_content("old\n", diff)
      assert content == "new\n"
    end

    test "returns a clear error for unsupported no-newline markers" do
      diff = """
      @@ -1,1 +1,1 @@
      -old
      \\ No newline at end of file
      +new
      \\ No newline at end of file
      """

      assert {:error, message} = ApplyDiff.apply_to_content("old", diff)
      assert message =~ "unsupported diff"
      assert message =~ "no-newline-at-EOF"
    end

    test "applies insertion-only hunks with zero-count headers" do
      diff = """
      @@ -1,0 +2,1 @@
      +inserted
      """

      assert {:ok, %{content: content, hunks: 1}} =
               ApplyDiff.apply_to_content("one\ntwo\nthree\n", diff)

      assert content == "one\ninserted\ntwo\nthree\n"
    end

    test "applies deletion-only hunks with zero-count headers" do
      diff = """
      @@ -2,1 +2,0 @@
      -two
      """

      assert {:ok, %{content: content, hunks: 1}} =
               ApplyDiff.apply_to_content("one\ntwo\nthree\n", diff)

      assert content == "one\nthree\n"
    end

    test "returns a clear error for malformed hunk counts" do
      diff = """
      @@ -1,2 +1,2 @@
       one
      -two
      """

      assert {:error, message} = ApplyDiff.apply_to_content("one\ntwo\n", diff)
      assert message =~ "malformed diff"
      assert message =~ "new line count"
    end

    test "rejects stale context without modifying content" do
      diff = """
      @@ -1,2 +1,2 @@
       missing
      -two
      +TWO
      """

      assert {:error, message} = ApplyDiff.apply_to_content("one\ntwo\n", diff)
      assert message =~ "stale diff"
      assert message =~ "context did not match"
    end

    test "rejects stale hunks that are too far outside the fuzz window" do
      diff = """
      @@ -10,2 +10,2 @@
       one
      -two
      +TWO
      """

      assert {:error, message} = ApplyDiff.apply_to_content("one\ntwo\nthree\n", diff)
      assert message =~ "stale diff"
      assert message =~ "context did not match"
    end

    test "rejects far-out insertion hunks against newline-terminated files" do
      diff = """
      @@ -3,0 +3,1 @@
      +late
      """

      assert {:error, message} = ApplyDiff.apply_to_content("one\ntwo\n", diff)
      assert message =~ "stale diff"
      assert message =~ "context did not match"
    end

    test "supports fuzz matching when hunk line numbers drift" do
      diff = """
      @@ -1,2 +1,2 @@
       one
      -two
      +TWO
      """

      assert {:ok, %{content: content}} =
               ApplyDiff.apply_to_content("zero\none\ntwo\nthree\n", diff)

      assert content == "zero\none\nTWO\nthree\n"
    end

    test "returns a clear error when no hunks are present" do
      assert {:error, message} = ApplyDiff.apply_to_content("content\n", "not a diff")
      assert message =~ "malformed diff"
    end
  end

  describe "execute/2" do
    test "writes the patched content to disk", %{tmp_dir: dir} do
      path = Path.join(dir, "example.txt")
      File.write!(path, "one\ntwo\nthree\n")

      diff = """
      @@ -1,3 +1,3 @@
       one
      -two
      +TWO
       three
      """

      assert {:ok, message} = ApplyDiff.execute(path, diff)
      assert message =~ "applied 1 diff hunk"
      assert File.read!(path) == "one\nTWO\nthree\n"
    end

    test "routes through an open buffer instead of writing disk directly", %{tmp_dir: dir} do
      path = Path.join(dir, "buffered.txt")
      File.write!(path, "one\ntwo\n")
      buffer = start_supervised!({BufferProcess, file_path: path})

      diff = """
      @@ -1,2 +1,2 @@
       one
      -two
      +TWO
      """

      assert {:ok, _message} = ApplyDiff.execute(path, diff)
      assert BufferProcess.content(buffer) == "one\nTWO\n"
      assert BufferProcess.dirty?(buffer)
      assert File.read!(path) == "one\ntwo\n"
    end
  end

  describe "Tools integration" do
    test "registers an apply_diff tool callback", %{tmp_dir: dir} do
      path = Path.join(dir, "tool.txt")
      File.write!(path, "old\n")
      tools = Tools.all(project_root: dir)
      tool = Enum.find(tools, &(&1.name == "apply_diff"))

      diff = """
      @@ -1,1 +1,1 @@
      -old
      +new
      """

      assert tool != nil
      assert {:ok, message} = tool.callback.(%{"path" => "tool.txt", "diff" => diff})
      assert message =~ "applied 1 diff hunk"
      assert File.read!(path) == "new\n"
    end
  end
end
