defmodule MingaEditor.Agent.TaskFilesTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Author
  alias MingaEditor.Agent.TaskFiles

  @task Author.minga("task-1")

  test "the file edited last is current, and editing a file again moves it to the end" do
    files =
      TaskFiles.new(@task)
      |> TaskFiles.record(@task, "lib/a.ex")
      |> TaskFiles.record(@task, "lib/b.ex")
      |> TaskFiles.record(@task, "lib/a.ex")

    assert TaskFiles.current(files) == "lib/a.ex"
    assert TaskFiles.paths(files) == ["lib/b.ex", "lib/a.ex"]
    assert TaskFiles.current(TaskFiles.new(@task)) == nil
  end

  test "another task's edit starts its own record" do
    other = Author.minga("task-2")

    files =
      TaskFiles.new(@task)
      |> TaskFiles.record(@task, "lib/a.ex")
      |> TaskFiles.record(other, "lib/c.ex")

    assert files.author == other
    assert TaskFiles.paths(files) == ["lib/c.ex"]
  end

  test "a record that does not know its task yet adopts the first author that edits" do
    files = TaskFiles.new() |> TaskFiles.record(@task, "lib/a.ex")
    assert {files.author, TaskFiles.paths(files)} == {@task, ["lib/a.ex"]}
  end

  test "keeps only the most recent files" do
    files =
      Enum.reduce(1..(TaskFiles.max_paths() + 5), TaskFiles.new(@task), fn n, acc ->
        TaskFiles.record(acc, @task, "lib/f#{n}.ex")
      end)

    assert length(TaskFiles.paths(files)) == TaskFiles.max_paths()
    assert TaskFiles.current(files) == "lib/f#{TaskFiles.max_paths() + 5}.ex"
    refute "lib/f1.ex" in TaskFiles.paths(files)
  end
end
