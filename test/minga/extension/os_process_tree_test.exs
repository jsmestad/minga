defmodule Minga.Extension.OSProcessTreeTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.OSProcessTree

  describe "descendants/3" do
    test "follows parent links through every generation" do
      rows = [{10, 1, 10}, {11, 10, 11}, {12, 11, 12}, {13, 12, 12}, {20, 1, 20}]

      assert Enum.sort(OSProcessTree.descendants(rows, 10)) == [11, 12, 13]
    end

    test "includes orphans that stay in a process group led by a reachable process" do
      # 13 was started by a shell that exited; it was reparented to init but kept group 12.
      rows = [{10, 1, 10}, {12, 10, 12}, {13, 1, 12}, {14, 13, 14}]

      assert Enum.sort(OSProcessTree.descendants(rows, 10)) == [12, 13, 14]
    end

    test "never reaches into init, the caller, or the group of a process outside the tree" do
      # The root shares the caller's group (no new session); the caller and its group stay out.
      rows = [{5, 1, 5}, {6, 5, 5}, {10, 5, 5}, {11, 10, 11}, {1, 0, 1}]

      assert OSProcessTree.descendants(rows, 10, [5]) == [11]
      assert OSProcessTree.descendants(rows, 1) == []
    end

    test "returns nothing for a root that is absent from the snapshot" do
      assert OSProcessTree.descendants([{20, 1, 20}], 10) == []
    end
  end

  describe "parse_ps/1" do
    test "reads pid, ppid, and pgid columns and skips malformed lines" do
      output =
        "    1     0     1\n  412     1   412\nheader line\n  413   412\n  414   412   412\n"

      assert OSProcessTree.parse_ps(output) == [{1, 0, 1}, {412, 1, 412}, {414, 412, 412}]
    end
  end
end
