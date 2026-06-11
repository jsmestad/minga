defmodule Minga.Git.SystemStatusTest do
  @moduledoc """
  Regression tests for parsing `git status --porcelain=v2 -z` output.
  """

  use ExUnit.Case, async: true

  alias Minga.Git.StatusEntry
  alias Minga.Git.System

  describe "parse_status_output/1" do
    test "parses rename, copy, non-ASCII, and plain modify records" do
      hash = String.duplicate("0", 40)

      output =
        [
          "2 R. N... 100644 100644 100644 #{hash} #{hash} R100 lib/new name.ex",
          "lib/old name.ex",
          "2 C. N... 100644 100644 100644 #{hash} #{hash} C100 lib/copy.ex",
          "lib/source.ex",
          "1 .M N... 100644 100644 100644 #{hash} #{hash} lib/plain.ex",
          "1 .M N... 100644 100644 100644 #{hash} #{hash} ä.txt"
        ]
        |> Enum.join(<<0>>)
        |> Kernel.<>(<<0>>)

      assert System.parse_status_output(output) == [
               %StatusEntry{path: "lib/new name.ex", status: :renamed, staged: true},
               %StatusEntry{path: "lib/copy.ex", status: :copied, staged: true},
               %StatusEntry{path: "lib/plain.ex", status: :modified, staged: false},
               %StatusEntry{path: "ä.txt", status: :modified, staged: false}
             ]
    end
  end
end
