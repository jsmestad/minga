defmodule MingaEditor.Agent.TaskFilesTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Author
  alias MingaEditor.Agent.TaskFiles

  @task Author.minga("task-1")

  defp record(files, author, path), do: TaskFiles.record(files, author, path, "/root/" <> path)

  test "the file edited last is current, and editing a file again moves it to the end" do
    files =
      TaskFiles.new(@task)
      |> record(@task, "lib/a.ex")
      |> record(@task, "lib/b.ex")
      |> record(@task, "lib/a.ex")

    assert TaskFiles.current(files, @task) == {"/root/lib/a.ex", "lib/a.ex"}
    assert TaskFiles.paths(files) == ["lib/b.ex", "lib/a.ex"]
    assert TaskFiles.current(TaskFiles.new(@task), @task) == nil
  end

  test "two spellings of one file are one file, named as the tool named it last" do
    files =
      TaskFiles.new(@task)
      |> TaskFiles.record(@task, "/link/lib/a.ex", "/real/lib/a.ex")
      |> TaskFiles.record(@task, "/real/lib/a.ex", "/real/lib/a.ex")

    assert TaskFiles.paths(files) == ["/real/lib/a.ex"]
  end

  test "another task's edit starts its own record" do
    other = Author.minga("task-2")

    files =
      TaskFiles.new(@task)
      |> record(@task, "lib/a.ex")
      |> record(other, "lib/c.ex")

    assert files.author == other
    assert TaskFiles.paths(files) == ["lib/c.ex"]
  end

  test "a task that has not edited yet sees no file, even while the last task's record remains" do
    files = TaskFiles.new(@task) |> record(@task, "lib/a.ex")
    assert TaskFiles.current(files, Author.minga("task-2")) == nil
    assert TaskFiles.current(files, nil) == nil
  end

  test "a record that does not know its task yet adopts the first author that edits" do
    files = TaskFiles.new() |> record(@task, "lib/a.ex")
    assert {files.author, TaskFiles.paths(files)} == {@task, ["lib/a.ex"]}
  end

  test "keeps only the most recent files" do
    files =
      Enum.reduce(1..(TaskFiles.max_paths() + 5), TaskFiles.new(@task), fn n, acc ->
        record(acc, @task, "lib/f#{n}.ex")
      end)

    last = "lib/f#{TaskFiles.max_paths() + 5}.ex"
    assert length(TaskFiles.paths(files)) == TaskFiles.max_paths()
    assert TaskFiles.current(files, @task) == {"/root/" <> last, last}
    refute "lib/f1.ex" in TaskFiles.paths(files)
  end
end
