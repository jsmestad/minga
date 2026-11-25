defmodule MingaAgent.ProcessDirectoryGuardTest do
  @moduledoc """
  Nothing under `lib/minga_agent` may read the process working directory.

  An application started from a desktop launcher has `/` there. A session works in the folder its caller decided (`MingaAgent.WorkingFolder`), and every tool takes that folder from its context.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @reads ~r/File\.cwd!?\(|Path\.relative_to_cwd\(|:file\.get_cwd\(/

  test "no source file under lib/minga_agent reads the process working directory" do
    offenders =
      for path <- Path.wildcard(Path.join(@root, "lib/minga_agent/**/*.ex")),
          {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@reads, line),
          do: "#{Path.relative_to(path, @root)}:#{number}: #{String.trim(line)}"

    assert offenders == [],
           "These lines read the process working directory. Take the session's folder from the tool context " <>
             "or the caller instead:\n" <> Enum.join(offenders, "\n")
  end
end
